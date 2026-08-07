// Prebuilt LiveView hooks for phoenix_kit_boards. Declared via `js_sources/0`;
// core's `:phoenix_kit_js_sources` compiler concatenates this (IIFE-wrapped)
// into the host's `phoenix_kit_modules.js` and folds
// `window.PhoenixKitBoardsHooks` into `window.PhoenixKitHooks` (spread into the
// host LiveSocket). The fresco/etcher engines are already loaded by the host.
window.PhoenixKitBoardsHooks = window.PhoenixKitBoardsHooks || {};

(function () {
  // ── BoardSync — apply remote annotation deltas to the local etcher layer ──
  //
  // The server pushes `board:apply` with { created, updated, deleted } when a
  // peer edits. We drive changes through `window.Etcher.layerFor(id)` so the
  // canvas never remounts. `addShape` re-emits `annotations-changed`, but the
  // server treats an unchanged list as a no-op, so applying doesn't echo back.
  const BoardSync = {
    mounted() {
      this.frescoId = this.el.dataset.frescoId;
      this.handleEvent("board:apply", (delta) => this.apply(delta));

      // How this user likes the board set up. Etcher emits a DOM event when
      // any of it changes and takes the whole set back through `setPrefs`;
      // everything between those two points is the host's business, which is
      // why nothing about user records appears on etcher's side of it.
      //
      // The event carries every preference rather than a diff, so there is
      // nothing to reconcile — the last one to arrive is the answer.
      this.onPrefs = (e) => this.pushEvent("etcher:prefs-changed", e.detail || {});
      this.el.addEventListener("etcher:prefs-changed", this.onPrefs);

      // What the server had stored, handed over once the layer exists. An
      // empty map means nothing stored, and etcher keeps its own defaults.
      this.handleEvent("board:prefs", ({ prefs }) => {
        if (!prefs || !Object.keys(prefs).length) return;
        this.whenLayer((layer) => {
          if (typeof layer.setPrefs === "function") layer.setPrefs(prefs);
        });
      });

      // Replies to `this.upload("board_image", …)`. Paired with their request
      // by arrival order — safe only because `uploadImage` runs one upload at
      // a time (see there).
      this.pendingUploads = [];
      // Shared playback: a peer drove the transport, so match them. Anyone
      // may control it, so this is applied unconditionally — etcher decides
      // whether it's far enough out to be worth a correction, and never
      // echoes one back.
      this.handleEvent("board:media", ({ uuid, action, position }) => {
        const layer = this.layer();
        if (!layer || typeof layer.applyMediaState !== "function") return;
        layer.applyMediaState(uuid, {
          playing: action === "play",
          position: typeof position === "number" ? position : 0
        });
      });

      // A peer joined and needs to know what is already playing.
      this.handleEvent("board:media-announce", () => {
        const layer = this.layer();
        if (!layer || typeof layer.mediaStates !== "function") return;
        const states = layer.mediaStates();
        if (states && states.length) this.pushEvent("etcher:media-announce", { states });
      });

      this.handleEvent("board:image-uploaded", ({ url }) => this.settleUpload(null, url));
      this.handleEvent("board:image-upload-failed", ({ reason }) =>
        this.settleUpload(reason || "upload failed"),
      );
      // Nothing is drawn from this — the image looks finished the moment it
      // is pasted — but it is proof the transfer is alive, which is what
      // keeps the watchdog from giving up on a big slow upload.
      this.handleEvent("board:image-progress", ({ progress }) => {
        const pending = (this.pendingUploads || [])[0];
        if (!pending) return;
        this.armUploadWatchdog(pending);
        // Feed Etcher's placeholder bar. The server reports 0-100; Etcher
        // works in fractions. Paired with the head of the queue for the same
        // reason the reply is — one upload runs at a time.
        if (typeof pending.onProgress === "function" && typeof progress === "number") {
          pending.onProgress(progress / 100);
        }
      });

      this.armEditing();
    },

    destroyed() {
      if (this.onPrefs) this.el.removeEventListener("etcher:prefs-changed", this.onPrefs);
      if (this._armTimer) {
        clearTimeout(this._armTimer);
        this._armTimer = null;
      }
      // Anything still in flight will never be answered now. Reject so Etcher
      // takes its fallback path instead of leaving the paste in limbo.
      (this.pendingUploads || []).forEach((p) => {
        clearTimeout(p.timer);
        p.reject("board closed before the upload finished");
      });
      this.pendingUploads = [];
    },

    settleUpload(error, url) {
      const pending = (this.pendingUploads || []).shift();
      if (!pending) return;
      clearTimeout(pending.timer);
      if (error) pending.reject(error);
      else pending.resolve(url);
    },

    // Give up on an upload that has gone quiet, so Etcher can fall back to
    // embedding. Rearmed by every progress report, so this fires on silence
    // rather than on slowness — a big file mid-transfer keeps resetting it.
    // Silence means the pipeline is broken (nothing wired up server-side, a
    // rejected entry, a dropped socket), and the alternative to noticing is
    // an image on the canvas whose bytes are never stored.
    armUploadWatchdog(pending) {
      clearTimeout(pending.timer);
      pending.timer = setTimeout(() => {
        const idx = this.pendingUploads.indexOf(pending);
        if (idx !== -1) this.pendingUploads.splice(idx, 1);
        pending.reject("no word from the server about this upload");
      }, 15000);
    },

    // Send one image to the server and resolve with its stored URL.
    //
    // Serialised: `allow_upload` permits a single entry at a time, and the
    // request/reply pairing is by order, which only holds while one upload is
    // in flight. Pasting twice quickly queues rather than races.
    uploadImage(file, ctx) {
      const start = () =>
        new Promise((resolve, reject) => {
          // `ctx.onProgress` rides along on the queue entry so the progress
          // events, which arrive on their own channel, can find the upload
          // they belong to.
          const pending = { resolve, reject, onProgress: ctx && ctx.onProgress };
          this.armUploadWatchdog(pending);
          this.pendingUploads.push(pending);
          this.upload("board_image", [file]);
        });

      // `start` on both branches so one failure doesn't wedge the queue.
      this._uploadChain = (this._uploadChain || Promise.resolve()).then(start, start);
      return this._uploadChain;
    },

    layer() {
      return window.Etcher && typeof window.Etcher.layerFor === "function"
        ? window.Etcher.layerFor(this.frescoId)
        : null;
    },

    // Stored preferences arrive with the mount reply, which can beat etcher's
    // own setup — it lazy-loads its script. Retried briefly rather than
    // dropped, or a fast server would leave the board on its defaults and the
    // user would watch their setup not apply.
    whenLayer(fn, tries) {
      const layer = this.layer();
      if (layer) { fn(layer); return; }
      const left = tries === undefined ? 40 : tries;
      if (left <= 0) return;
      setTimeout(() => this.whenLayer(fn, left - 1), 50);
    },

    // Open every board ready to edit.
    //
    // Etcher boots with annotation mode off, and the bottom toolbar is gated
    // on that mode (`toolbar.classList.toggle("is-active", on)`), so the
    // drawing and text tools were hidden until the user found the pencil
    // button. Someone opening a board almost always intends to work on it, so
    // the mode goes on for them.
    //
    // The tool is then set to the grabber rather than left on the cursor: the
    // grabber pans and is the only "active" tool etcher deliberately lets
    // pointer events fall through to Fresco for, so a drag navigates the
    // canvas instead of drawing or box-selecting. Arriving in a state where
    // the first drag draws something would be worse than a hidden toolbar.
    //
    // Etcher registers the layer handle inside its own hook's `mounted()`,
    // and hook mount order across sibling elements isn't guaranteed, so poll
    // briefly rather than assume the handle is there on our first tick.
    armEditing(attempt) {
      attempt = attempt || 0;
      const layer = this.layer();

      if (layer) {
        if (typeof layer.getMode === "function" && !layer.getMode()) {
          layer.setMode(true);
        }
        // Only if the host actually offers the grabber — `tools` is a
        // module-level list that a future change could narrow.
        const tools = typeof layer.tools === "function" ? layer.tools() : null;
        if (!tools || tools.indexOf("grabber") !== -1) {
          layer.selectTool("grabber");
        }

        // Route pasted / dropped / picked images through storage instead of
        // letting Etcher embed them as base64. Guarded on the method existing
        // so an older etcher just keeps embedding rather than breaking the
        // board. See the LiveView's upload section for why this matters.
        if (typeof layer.setImageUploader === "function") {
          layer.setImageUploader((file, ctx) => this.uploadImage(file, ctx));
        }

        // Pasted URLs become preview cards. Unlike uploads this is a plain
        // request/response, so `pushEvent`'s reply callback carries it — no
        // queue, no ordering to keep straight.
        if (typeof layer.setLinkUnfurler === "function") {
          layer.setLinkUnfurler(
            (url) =>
              new Promise((resolve, reject) => {
                // The reply carries the card as SVG — Etcher rasterises it.
                this.pushEvent("board:unfurl", { url }, (reply) => {
                  if (reply && reply.svg) resolve(reply);
                  else reject((reply && reply.error) || "unfurl failed");
                });
              }),
          );
        }
        return;
      }

      // ~3s. If etcher never shows up the board is still usable read-only;
      // retrying forever would just leak a timer.
      if (attempt >= 60) return;
      this._armTimer = setTimeout(() => this.armEditing(attempt + 1), 50);
    },

    apply(delta) {
      const layer = this.layer();
      if (!layer) return;
      (delta.deleted || []).forEach((uuid) => layer.deleteShape(uuid));
      (delta.updated || []).forEach((shape) => {
        layer.deleteShape(shape.uuid);
        layer.addShape(shape);
      });
      (delta.created || []).forEach((shape) => layer.addShape(shape));

      // Re-impose the sender's layering last.
      //
      // Position in the list is z-order, and the delete/re-add above appends,
      // so every applied edit would otherwise shuffle the receiver's stacking
      // — a peer editing a caption would silently bring it in front of the
      // image it was behind. `setShapeOrder` deliberately doesn't emit, so
      // applying a peer's delta can't echo back as a change of our own.
      if (delta.order && typeof layer.setShapeOrder === "function") {
        layer.setShapeOrder(delta.order);
      }
    },
  };

  // ── BoardCursors — live cursors of other viewers ──────────────────────────
  //
  // Cursor positions travel in CANVAS coordinates so each viewer maps them
  // through their own pan/zoom. We read the fresco handle's screen↔image
  // round-trip: on local pointer move we screenToImage and push; on a peer
  // update we imageToScreen and place a labeled cursor.
  const BoardCursors = {
    mounted() {
      this.frescoId = this.el.dataset.frescoId;
      this.cursors = {}; // id -> { el, lastSeen }
      this.handle = null;
      this.lastSent = 0;

      if (window.Fresco && typeof window.Fresco.onReady === "function") {
        window.Fresco.onReady(this.frescoId, (handle) => {
          this.handle = handle;
          this.attach();
        });
      }

      this.handleEvent("cursor:update", (p) => this.update(p));
      this.handleEvent("cursor:remove", (p) => {
        this.remove(p.id);
        this.dropPointer(p.id);
      });
      this.sweeper = setInterval(() => this.sweep(), 4000);
    },

    destroyed() {
      if (this.sweeper) clearInterval(this.sweeper);
      if (this.onMove) this.root().removeEventListener("pointermove", this.onMove);
    },

    // The interactive board container (board-cursors is pointer-events:none).
    root() {
      return this.el.parentElement || this.el;
    },

    attach() {
      this.onMove = (e) => {
        const now = Date.now();
        if (now - this.lastSent < 45 || !this.handle) return; // ~22fps throttle
        this.lastSent = now;
        try {
          const pt = this.handle.screenToImage({ x: e.clientX, y: e.clientY });
          if (pt && typeof pt.x === "number") {
            // The red pointer rides the cursor channel rather than a channel
            // of its own: it IS this person's cursor, just drawn differently.
            // Sending it separately would mean two streams racing to say
            // where the same person is, and a moment showing both.
            this.pushEvent("cursor:move", { x: pt.x, y: pt.y, pointer: this.pointing() });
          }
        } catch (_) {}
      };
      this.root().addEventListener("pointermove", this.onMove);
    },

    // Is the local user presenting with the red pointer right now?
    pointing() {
      const layer = this.layer();
      return !!(layer && typeof layer.isPointerMode === "function" && layer.isPointerMode());
    },

    layer() {
      if (!window.Etcher || typeof window.Etcher.layerFor !== "function") return null;
      try { return window.Etcher.layerFor(this.frescoId); } catch (_) { return null; }
    },

    update(p) {
      if (!this.handle) return;

      // Someone presenting is drawn by etcher, not here: it owns what a
      // pointer looks like, it already draws in canvas coordinates so the dot
      // lands on the same spot for everyone, and it keeps the trail. This
      // hook's job is only to say who is pointing and where.
      //
      // Their arrow goes away while they do — one person is one cursor, and
      // showing both would read as two people in the same place.
      if (p.pointer) {
        const layer = this.layer();
        if (layer && typeof layer.applyRemotePointer === "function") {
          this.remove(p.id);
          this.pointers = this.pointers || {};
          this.pointers[p.id] = true;
          layer.applyRemotePointer(p.id, { x: p.x, y: p.y, name: p.name });
          return;
        }
        // No etcher on this page: fall through and draw them as an ordinary
        // cursor rather than losing them entirely.
      } else if (this.pointers && this.pointers[p.id]) {
        this.dropPointer(p.id);
      }

      let screen;
      try {
        screen = this.handle.imageToScreen({ x: p.x, y: p.y });
      } catch (_) {
        return;
      }
      const rect = this.el.getBoundingClientRect();
      const x = screen.x - rect.left;
      const y = screen.y - rect.top;

      let c = this.cursors[p.id];
      if (!c) {
        c = { el: this.buildCursor(p.name, p.color), lastSeen: 0 };
        this.el.appendChild(c.el);
        this.cursors[p.id] = c;
      }
      c.lastSeen = Date.now();
      c.el.style.transform = `translate(${x}px, ${y}px)`;
    },

    buildCursor(name, color) {
      const wrap = document.createElement("div");
      wrap.style.cssText =
        "position:absolute;top:0;left:0;pointer-events:none;will-change:transform;transition:transform 60ms linear;z-index:40;";
      wrap.innerHTML =
        `<svg width="18" height="18" viewBox="0 0 24 24" fill="${escapeAttr(color)}" ` +
        `style="filter:drop-shadow(0 1px 1px rgba(0,0,0,.3))"><path d="M4 2 L20 12 L13 13 L11 20 Z"/></svg>` +
        `<span style="position:absolute;left:14px;top:12px;background:${escapeAttr(color)};color:#fff;` +
        `font:600 11px/1.4 system-ui,sans-serif;padding:1px 6px;border-radius:6px;white-space:nowrap;">` +
        `${escapeHtml(name)}</span>`;
      return wrap;
    },

    remove(id) {
      const c = this.cursors[id];
      if (c) {
        if (c.el.parentNode) c.el.parentNode.removeChild(c.el);
        delete this.cursors[id];
      }
    },

    dropPointer(id) {
      if (!this.pointers || !this.pointers[id]) return;
      delete this.pointers[id];
      const layer = this.layer();
      if (layer && typeof layer.removeRemotePointer === "function") {
        layer.removeRemotePointer(id);
      }
    },

    // Drop cursors that stopped updating (disconnect without a clean leave).
    sweep() {
      const now = Date.now();
      Object.keys(this.cursors).forEach((id) => {
        if (now - this.cursors[id].lastSeen > 8000) this.remove(id);
      });
      // Pointers time themselves out inside etcher, so a peer that vanishes
      // mid-present cleans up there. This only drops our record of who was
      // pointing, so their arrow comes back if they return.
      if (this.pointers) {
        Object.keys(this.pointers).forEach((id) => {
          if (!this.cursors[id]) return;
          if (now - this.cursors[id].lastSeen > 8000) this.dropPointer(id);
        });
      }
    },
  };

  function escapeHtml(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function escapeAttr(s) {
    return escapeHtml(s).replace(/"/g, "&quot;");
  }

  window.PhoenixKitBoardsHooks = Object.assign(window.PhoenixKitBoardsHooks, {
    BoardSync,
    BoardCursors,
  });
})();
