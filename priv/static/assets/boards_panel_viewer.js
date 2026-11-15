(function () {
  // Keyboard events in a frame never bubble to the parent page. Listen in
  // the frame as well, after Etcher has had the chance to cancel a draft,
  // deselect a shape or close its own menu with Escape.
  return {
    mounted() {
      var self = this;
      this.onFrameKey = function (event) {
        if (event.key !== "Escape" || event.defaultPrevented) return;
        var target = event.target;
        if (target && (target.isContentEditable ||
            /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))) return;
        self.pushEventTo(self.el, "close_board", {});
      };
      this.onFrameLoad = function () {
        self.detachFrame();
        try {
          // A host can redirect to another origin (e.g. its sign-in page).
          // Reading document checks same-origin access before subscribing.
          var frameWindow = self.el.contentWindow;
          if (!frameWindow || !frameWindow.document) return;
          frameWindow.addEventListener("keydown", self.onFrameKey);
          self.frameWindow = frameWindow;
        } catch (_) { /* The close button in the parent is still available. */ }
      };
      this.el.addEventListener("load", this.onFrameLoad);
      this.onFrameLoad();
    },

    detachFrame() {
      if (this.frameWindow) {
        try { this.frameWindow.removeEventListener("keydown", this.onFrameKey); } catch (_) {}
        this.frameWindow = null;
      }
    },

    destroyed() {
      this.el.removeEventListener("load", this.onFrameLoad);
      this.detachFrame();
    }
  };
})()
