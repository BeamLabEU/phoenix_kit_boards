(function () {
  // "Export as PDF" from a board's tile.
  //
  // A tile only shows a preview, so the board is drawn for the export: the
  // server mounts it off screen with the same Fresco canvas and Etcher layer
  // the board page uses, this hook waits for both to be ready, runs Fresco's
  // export (Etcher adds the shapes to it), and tells the server to take the
  // copy down again. What lands in the PDF is what the board page would show.
  var GIVE_UP_MS = 30000;

  // Fresco uses `opts.filename` as the download name and skips `exportName`,
  // which is what would have added ".pdf" and replaced characters a
  // filesystem refuses. Do that here. The server puts the same name in
  // `data-filename`; keep the two in step (BoardsPanel.pdf_filename/1).
  function pdfFilename(name) {
    var base = String(name == null ? "" : name);
    base = base.replace(/[\u0000-\u001F\u007F]/g, "");
    base = base.replace(/\.[A-Za-z0-9]{2,5}$/, "");
    base = base.replace(/[\\/:*?"<>|]+/g, "_");
    base = base.trim();
    base = base.replace(/^\.+/, "");
    base = base.trim();
    if (!base) base = "board";
    return base + ".pdf";
  }

  return {
    mounted() {
      var el = this.el;
      var self = this;
      var frescoId = el.dataset.frescoId;
      var filename = pdfFilename(el.dataset.filename || "board");
      var seq = el.dataset.seq || null;
      self.done = false;

      // `self.done` rather than a local: `destroyed` sets it too, so a copy
      // taken down before it was ready stops polling and never reports.
      function finish(ok, reason) {
        if (self.done) return;
        self.done = true;
        clearTimeout(self.giveUp);
        self.pushEventTo(el, "export_done", { ok: ok, seq: seq, reason: reason || null });
      }

      // Only until the export actually starts. A board of images can take
      // longer than this to rasterise; once `exportPdf` is running the
      // server's longer watch is the backstop, and this one must not report
      // a failure and take the copy down underneath it.
      this.giveUp = setTimeout(function () { finish(false, "timeout"); }, GIVE_UP_MS);

      if (!window.Fresco || typeof window.Fresco.onReady !== "function") {
        finish(false, "viewer not loaded");
        return;
      }

      window.Fresco.onReady(frescoId, function (handle) {
        if (self.done) return;
        if (typeof handle.exportPdf !== "function") {
          finish(false, "this viewer cannot export");
          return;
        }
        (function wait() {
          if (self.done) return;
          var layer = window.Etcher && typeof window.Etcher.layerFor === "function"
            ? window.Etcher.layerFor(frescoId) : null;
          if (!layer || (typeof layer.isReady === "function" && !layer.isReady())) {
            setTimeout(wait, 100);
            return;
          }
          // Two frames: the shapes' first layout is done before they are read.
          // Both check `done`: the copy can be taken down after the layer is
          // ready and before these frames run.
          requestAnimationFrame(function () {
            if (self.done) return;
            requestAnimationFrame(function () {
              if (self.done) return;
              clearTimeout(self.giveUp);
              self.pushEventTo(el, "export_started", { seq: seq });
              var pending;
              try {
                // Fresco must not download on its own: the host can be
                // removed while rasterisation is running (timeout, navigation
                // or a change of place). Only a still-mounted export saves it.
                pending = handle.exportPdf({ filename: filename, download: false });
              } catch (err) {
                finish(false, String((err && err.message) || err));
                return;
              }
              Promise.resolve(pending).then(
                function (blob) {
                  if (self.done) return;
                  var url;
                  var link;
                  try {
                    url = URL.createObjectURL(blob);
                    link = document.createElement("a");
                    link.href = url;
                    link.download = filename;
                    link.style.display = "none";
                    document.body.appendChild(link);
                    link.click();
                    finish(true);
                  } catch (err) {
                    finish(false, String((err && err.message) || err));
                  } finally {
                    if (link) link.remove();
                    if (url) setTimeout(function () { URL.revokeObjectURL(url); }, 30000);
                  }
                },
                function (err) { finish(false, String((err && err.message) || err)); }
              );
            });
          });
        })();
      });
    },

    destroyed() {
      this.done = true;
      clearTimeout(this.giveUp);
    }
  };
})()
