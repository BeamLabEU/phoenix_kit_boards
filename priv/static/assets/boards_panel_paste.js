(function () {
  // Paste-to-make-a-board for the boards widget.
  //
  // Active only while the widget has focus — the person has clicked into it or
  // tabbed to it — and never while they are typing in a field inside it. A
  // paste anywhere else on the page is not seen at all.
  //
  // What was pasted decides what is asked for: any images are uploaded through
  // the widget's own upload (the server makes ONE board of them, with whatever
  // text came along), and text alone is sent as a note.
  var MAX_FILES = 8;

  function editable(node) {
    if (!node || !node.closest) return false;
    if (node.isContentEditable) return true;
    return !!node.closest("input, textarea, select, [contenteditable=''], [contenteditable='true']");
  }

  return {
    mounted() {
      var el = this.el;
      var self = this;
      this.imageQueue = [];
      this.pasteContext = el.dataset.pasteContext;

      // A click anywhere in the widget makes it the active one. Browsers
      // differ on whether a clicked button takes focus (Safari's does not), so
      // after the click settles, the widget takes it if nothing in it did.
      this.onPointerDown = function (e) {
        if (el.dataset.paste !== "on" || editable(e.target)) return;
        setTimeout(function () {
          if (el.dataset.paste === "on" && !el.contains(document.activeElement)) {
            el.focus({ preventScroll: true });
          }
        }, 0);
      };

      this.onPaste = function (e) {
        if (el.dataset.paste !== "on" || editable(e.target)) return;
        var data = e.clipboardData;
        if (!data) return;

        var files =
          el.dataset.pasteImages === "on"
            ? Array.prototype.filter
                .call(data.files || [], function (f) {
                  return /^image\//.test(f.type);
                })
                .slice(0, MAX_FILES)
            : [];
        var text = el.dataset.pasteText === "on" ? data.getData("text/plain") || "" : "";

        if (files.length) {
          e.preventDefault();
          self.imageQueue.push({ files: files, text: text });
          self.drainPastes();
        } else if (text.trim() !== "") {
          e.preventDefault();
          self.pushEventTo(el, "paste_text", { text: text });
        }
      };

      el.addEventListener("pointerdown", this.onPointerDown);
      el.addEventListener("paste", this.onPaste);
    },

    // The upload has one server-side collection and one accompanying note.
    // Wait for it to clear before starting another paste, so rapid pastes do
    // not combine their images or overwrite each other's note.
    uploading() {
      var input = this.el.querySelector("input[type='file'][name='quick_image']");
      return !!(input && input.dataset.phxActiveRefs);
    },

    drainPastes() {
      if (this.activePaste || this.uploading() || !this.imageQueue.length) return;
      var paste = this.imageQueue.shift();
      this.activePaste = true;
      this.sawUpload = false;
      this.pushEventTo(this.el, "paste_context", { text: paste.text });
      this.uploadTo(this.el, "quick_image", paste.files);
    },

    updated() {
      if (this.pasteContext !== this.el.dataset.pasteContext ||
          this.el.dataset.paste !== "on" || this.el.dataset.pasteImages !== "on") {
        this.imageQueue = [];
        this.activePaste = false;
        this.sawUpload = false;
        this.pasteContext = this.el.dataset.pasteContext;
      }
      if (this.activePaste && this.uploading()) this.sawUpload = true;
      if (this.activePaste && this.sawUpload && !this.uploading()) this.activePaste = false;
      this.drainPastes();
    },

    destroyed() {
      this.imageQueue = [];
      this.el.removeEventListener("pointerdown", this.onPointerDown);
      this.el.removeEventListener("paste", this.onPaste);
    }
  };
})()
