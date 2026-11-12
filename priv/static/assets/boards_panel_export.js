(function () {
  // "Export as PDF" from a board's tile.
  //
  // A tile only shows a preview, so the board is drawn for the export: the
  // server mounts it off screen with the same Fresco canvas and Etcher layer
  // the board page uses, this hook waits for both to be ready, runs Fresco's
  // export (Etcher adds the shapes to it), and tells the server to take the
  // copy down again. What lands in the PDF is what the board page would show.
  var GIVE_UP_MS = 30000;

  return {
    mounted() {
      var el = this.el;
      var self = this;
      var frescoId = el.dataset.frescoId;
      var filename = el.dataset.filename || "board";
      var done = false;

      function finish(ok, reason) {
        if (done) return;
        done = true;
        clearTimeout(self.giveUp);
        self.pushEventTo(el, "export_done", { ok: ok, reason: reason || null });
      }

      this.giveUp = setTimeout(function () { finish(false, "timeout"); }, GIVE_UP_MS);

      if (!window.Fresco || typeof window.Fresco.onReady !== "function") {
        finish(false, "viewer not loaded");
        return;
      }

      window.Fresco.onReady(frescoId, function (handle) {
        if (typeof handle.exportPdf !== "function") {
          finish(false, "this viewer cannot export");
          return;
        }
        (function wait() {
          if (done) return;
          var layer = window.Etcher && typeof window.Etcher.layerFor === "function"
            ? window.Etcher.layerFor(frescoId) : null;
          if (!layer || (typeof layer.isReady === "function" && !layer.isReady())) {
            setTimeout(wait, 100);
            return;
          }
          // Two frames: the shapes' first layout is done before they are read.
          requestAnimationFrame(function () {
            requestAnimationFrame(function () {
              handle.exportPdf({ filename: filename }).then(
                function () { finish(true); },
                function (err) { finish(false, String((err && err.message) || err)); }
              );
            });
          });
        })();
      });
    },

    destroyed() {
      clearTimeout(this.giveUp);
    }
  };
})()
