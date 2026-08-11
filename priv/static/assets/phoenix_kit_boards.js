// Prebuilt LiveView hooks for phoenix_kit_boards. Declared via `js_sources/0`;
// core's `:phoenix_kit_js_sources` compiler concatenates this (IIFE-wrapped)
// into the host's `phoenix_kit_modules.js` and folds
// `window.PhoenixKitBoardsHooks` into `window.PhoenixKitHooks` (spread into the
// host LiveSocket). The fresco/etcher engines are already loaded by the host.
window.PhoenixKitBoardsHooks = window.PhoenixKitBoardsHooks || {};

(function () {
  // How often a moving cursor is sent WHEN THERE IS NO CHANNEL.
  //
  // On the fallback path every position is a LiveView event costing a render
  // and a diff, so it has to be rationed. Over the channel it isn't rationed
  // at all — see `scheduleSend`, which paces by the display instead.
  const CURSOR_SEND_MS = 25;

  // What a peer's cursor glides over until enough packets have arrived to
  // measure the real interval, and the ceiling on that measurement. A glide
  // longer than the ceiling is a peer who paused rather than a slow
  // connection, and drifting slowly across the board for a quarter second
  // after they stopped looks worse than arriving.
  //
  // The opening guess sits between a frame and the fallback rate — close
  // enough that the first moves of a session already look right, whichever
  // pipe they came down, with room for the jitter the measurement settles
  // onto.
  const CURSOR_GLIDE_MS = 24;
  const CURSOR_MAX_GLIDE_MS = 250;

  // The floor. A glide shorter than a frame cannot be seen as motion — it is
  // a jump — so there is nothing to gain below this, and it stops a burst of
  // packets collapsing the glide to nothing.
  const CURSOR_MIN_GLIDE_MS = 16;

  // A gap longer than this is a peer who stopped moving and started again,
  // not a slow packet — it says nothing about the connection, so it must not
  // drag the interval estimate up with it.
  const CURSOR_STALE_GAP_MS = 500;

  // Monotonic where available: the interpolation asks how far through a glide
  // it is, and a wall clock that steps (NTP, sleep/wake) would make a cursor
  // jump or freeze.
  const now_ =
    typeof performance === "object" && typeof performance.now === "function"
      ? () => performance.now()
      : () => Date.now();

  // Do two objects carry the same set of keys? Null and an empty object are
  // the same thing here — a shape with no style and a shape whose style is
  // empty are not a difference worth rebuilding an element over.
  function sameKeys(a, b) {
    const ka = Object.keys(a || {});
    const kb = Object.keys(b || {});
    return ka.length === kb.length && ka.every((k) => Object.prototype.hasOwnProperty.call(b || {}, k));
  }

  // ── BoardLink — the ephemeral channel ─────────────────────────────────────
  //
  // Cursors and in-flight drags go over a channel of their own rather than
  // through the LiveView. Both are high-rate and worthless a moment later,
  // and through a LiveView every position pays for a render and a diff,
  // queued behind that process's real work — saving edits, uploads, link
  // previews.
  //
  // Optional by design. The socket is declared on the host's endpoint, so a
  // host that hasn't added it simply never connects, and everything falls
  // back to the LiveView relay that was there before. Nothing here may assume
  // it succeeded.
  //
  // One connection per board, shared: both hooks on the page ask for it and
  // whichever gets there first opens it.
  const BoardLink = {
    links: {},

    // The Socket class, without requiring the host to export it. LiveView
    // already built one, and its constructor is the same class.
    socketClass() {
      if (window.Phoenix && window.Phoenix.Socket) return window.Phoenix.Socket;
      const live = window.liveSocket;
      if (live && live.socket && live.socket.constructor) return live.socket.constructor;
      return null;
    },

    // Idempotent: called by every hook that hears the offer.
    ensure(id, info) {
      if (!id || !info || !info.token || !info.topic) return null;

      const existing = this.links[id];
      if (existing) {
        // A remount hands out a fresh token for the same board; the live
        // connection is still good.
        if (existing.topic === info.topic) return existing;
        this.close(id);
      }

      const Socket = this.socketClass();
      if (!Socket) return null;

      let link;
      try {
        const socket = new Socket(info.path || "/phoenix_kit/board", {
          params: { token: info.token }
        });
        socket.connect();

        const channel = socket.channel(info.topic, {});
        link = { socket, channel, topic: info.topic, joined: false, handlers: {} };

        channel.onMessage = (event, payload, ref) => {
          const fn = link.handlers[event];
          if (fn) {
            try { fn(payload); } catch (_) {}
          }
          return payload;
        };

        channel
          .join()
          .receive("ok", () => { link.joined = true; })
          // A refusal is not worth shouting about — the LiveView path still
          // works, and the board is fully usable on it.
          .receive("error", () => { link.joined = false; })
          .receive("timeout", () => { link.joined = false; });

        this.links[id] = link;
      } catch (_) {
        return null;
      }

      return link;
    },

    get(id) {
      const link = this.links[id];
      return link && link.joined ? link : null;
    },

    on(id, event, fn) {
      const link = this.links[id];
      if (link) link.handlers[event] = fn;
    },

    push(id, event, payload) {
      const link = this.get(id);
      if (!link) return false;
      try {
        link.channel.push(event, payload);
        return true;
      } catch (_) {
        return false;
      }
    },

    close(id) {
      const link = this.links[id];
      if (!link) return;
      delete this.links[id];
      try { link.channel.leave(); } catch (_) {}
      try { link.socket.disconnect(); } catch (_) {}
    }
  };

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

      // The ephemeral channel — cursors and in-flight drags.
      this.handleEvent("board:channel", (info) => this.openLink(info));

      this.handleEvent("board:image-uploaded", ({ url }) => this.settleUpload(null, url));
      this.handleEvent("board:image-upload-failed", ({ reason }) =>
        this.settleUpload(reason || "upload failed"),
      );
      // Nothing is drawn from this — the image looks finished the moment it
      // is pasted — but it is proof the transfer is alive, which is what
      // keeps the watchdog from giving up on a big slow upload.
      this.handleEvent("board:image-progress", ({ progress }) => {
        // The first entry still waiting on an answer — a tombstone left by
        // an earlier timeout is not it, and rearming it would do nothing.
        const pending = (this.pendingUploads || []).find((p) => !p.settled);
        if (!pending) return;
        this.armUploadWatchdog(pending);
        // Feed Etcher's placeholder bar. The server reports 0-100; Etcher
        // works in fractions.
        if (typeof pending.onProgress === "function" && typeof progress === "number") {
          pending.onProgress(progress / 100);
        }
      });

      this.armEditing();

      // Tell the server this hook can hear it — and only now.
      //
      // Anything the LiveView pushes from its connected mount rides the join
      // reply and is dispatched immediately. Under this module's runtime-hook
      // delivery that is hundreds of milliseconds before THIS function runs:
      // the shim's `mounted` starts a ~40 KB fetch, and the handlers
      // registered above do not exist until it lands. Every mount-time push
      // went to nobody — the channel token and the stored preferences among
      // them, which is a board that renders and saves but never shows a
      // cursor.
      //
      // So the server waits to be asked. Both hooks ask, because either may
      // mount last and the reply has to arrive when both are listening.
      this.pushEvent("board:ready", {});
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
      // The link outlives the DOM otherwise — see `BoardCursors.destroyed`.
      BoardLink.close(this.frescoId);
    },

    // Open the ephemeral channel and start streaming drags over it.
    //
    // Everything here is best-effort: no channel means no live drags, and a
    // board that behaves exactly as it did before — peers see a shape when
    // the person lets go of it rather than while they move it.
    openLink(info) {
      const link = BoardLink.ensure(this.frescoId, info);
      if (!link) return;

      // A peer's shapes, mid-drag. Nothing is stored — the edit itself
      // arrives through the LiveView when they release, which is what settles
      // the position and what a reload would show.
      BoardLink.on(this.frescoId, "moving", ({ shapes }) => {
        const layer = this.layer();
        if (layer && typeof layer.applyShapesMoving === "function") {
          layer.applyShapesMoving(shapes);
        }
      });

      this.whenLayer((layer) => this.streamMoves(layer));
    },

    // Report our own drags so peers can watch them happen.
    //
    // Etcher batches these to one report per frame and only while a pointer
    // is down, so this is a frame's worth of geometry rather than a flood.
    // Geometry only: it is all a drag changes and all a peer needs.
    streamMoves(layer) {
      if (typeof layer.onShapesMoving !== "function") return;
      if (this._streaming) return;
      this._streaming = true;

      layer.onShapesMoving(
        (shapes) => BoardLink.push(this.frescoId, "moving", { shapes }),
        () => BoardLink.push(this.frescoId, "moved", {})
      );
    },

    settleUpload(error, url) {
      const pending = (this.pendingUploads || []).shift();
      if (!pending) return;
      clearTimeout(pending.timer);
      // A timed-out upload stays in the queue as a tombstone so this reply
      // still lands on the request that produced it. Dropping it instead
      // would shift the queue under a reply already in flight, and the next
      // paste would resolve with the *previous* image's URL — a picture
      // silently replaced by another one, which is worse than the fallback.
      if (pending.settled) return;
      if (error) pending.reject(error);
      else pending.resolve(url);
    },

    // Give up on an upload that has gone quiet, so Etcher can fall back to
    // embedding. Rearmed by every progress report, so this fires on silence
    // rather than on slowness — a big file mid-transfer keeps resetting it.
    // Silence means the pipeline is broken (nothing wired up server-side, a
    // rejected entry, a dropped socket), and the alternative to noticing is
    // an image on the canvas whose bytes are never stored.
    //
    // The entry is marked rather than removed — see `settleUpload`. Its slot
    // is reclaimed by the reply that eventually arrives, or by `destroyed`;
    // a dropped socket, the case where no reply ever comes, tears the hook
    // down anyway.
    armUploadWatchdog(pending) {
      clearTimeout(pending.timer);
      pending.timer = setTimeout(() => {
        pending.settled = true;
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

      const deleted = delta.deleted || [];
      const updated = delta.updated || [];
      const created = delta.created || [];

      deleted.forEach((uuid) => layer.deleteShape(uuid));

      // A changed shape is patched where it stands.
      //
      // Deleting and re-adding it rebuilds the element: media reloads, images
      // re-decode, and the shape flashes. It also appends, which is why the
      // layering had to be re-imposed afterwards — and that re-imposition
      // touched every shape on the board, so watching a peer drag one thing
      // flashed all of it.
      // A shape patching cannot express is rebuilt instead — and a rebuild
      // appends, so it moves. Remembered rather than inferred from the delta:
      // the server has no way to know which of its updates this particular
      // viewer was able to patch, and that is exactly what decides it.
      let rebuilt = false;

      updated.forEach((shape) => {
        if (!this.patchInPlace(layer, shape)) {
          layer.deleteShape(shape.uuid);
          layer.addShape(shape);
          rebuilt = true;
        }
      });

      created.forEach((shape) => layer.addShape(shape));

      // Re-impose the sender's layering, but only when it can have moved.
      //
      // Position in the list is z-order. Patching leaves a shape where it
      // already sits, so an ordinary edit no longer disturbs it — only adding,
      // removing, rebuilding one, or a real reorder can.
      // `setShapeOrder` deliberately doesn't emit, so applying a peer's delta
      // can't echo back as a change of our own.
      const structural = created.length > 0 || deleted.length > 0 || rebuilt || delta.reordered;
      if (structural && delta.order && typeof layer.setShapeOrder === "function") {
        layer.setShapeOrder(delta.order);
      }
    },

    // True if the shape was updated in place.
    //
    // Declines rather than guesses. `patchShape` MERGES style and metadata, so
    // a peer that REMOVED one of those keys would leave a stale copy here —
    // comparing the key sets first catches that and falls back to the honest
    // rebuild. A move, which is the case that matters, changes only geometry
    // and so always takes the fast path.
    patchInPlace(layer, shape) {
      if (!shape || !shape.uuid) return false;
      if (typeof layer.patchShape !== "function" || typeof layer.getShape !== "function") {
        return false;
      }

      const existing = layer.getShape(shape.uuid);
      if (!existing) return false;
      if (existing.kind !== shape.kind) return false;
      if (!sameKeys(existing.style, shape.style)) return false;
      if (!sameKeys(existing.metadata, shape.metadata)) return false;

      layer.patchShape(shape.uuid, {
        geometry: shape.geometry,
        style: shape.style,
        metadata: shape.metadata
      });
      return true;
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

      // Cursors prefer the ephemeral channel; the LiveView handler above
      // stays wired because it is the fallback when the host hasn't mounted
      // the socket, and because leaves still arrive that way.
      this.handleEvent("board:channel", (info) => {
        if (BoardLink.ensure(this.frescoId, info)) {
          BoardLink.on(this.frescoId, "cursor", (p) => this.update(p));
        }
      });
      this.sweeper = setInterval(() => this.sweep(), 4000);

      // Same reason as BoardSync — see the note there. The cursor channel's
      // token arrives on `board:channel`, and this hook's handler for it is
      // registered just above.
      this.pushEvent("board:ready", {});
    },

    destroyed() {
      if (this.sweeper) clearInterval(this.sweeper);
      if (this.moveTimer) clearTimeout(this.moveTimer);
      if (this.sendFrame) cancelAnimationFrame(this.sendFrame);
      if (this.raf) cancelAnimationFrame(this.raf);
      this.sendFrame = null;
      this.raf = null;
      if (this.onMove) this.root().removeEventListener("pointermove", this.onMove);

      // Close the channel, and refuse anything that arrives before it does.
      //
      // Nothing else does: the socket is opened here but lives on `BoardLink`,
      // which outlives the page. Navigating back to the board list left it
      // connected and still joined, and the "cursor" handler still holds THIS
      // hook — so every packet from a peer appended a cursor to an element no
      // longer in the document and restarted `startDrawing`, an rAF loop with
      // nothing left to cancel it. One per board opened, for the life of the
      // tab.
      //
      // `draw` and `update` both bail on a missing handle, so dropping it is
      // what makes a packet racing the close harmless.
      this.handle = null;
      BoardLink.close(this.frescoId);
    },

    // The interactive board container (board-cursors is pointer-events:none).
    root() {
      return this.el.parentElement || this.el;
    },

    attach() {
      this.onMove = (e) => {
        this.pending = { x: e.clientX, y: e.clientY };
        this.flushMove();
      };
      this.root().addEventListener("pointermove", this.onMove);
    },

    // Decide when the pending position goes out. The rate follows the pipe.
    //
    // Over the channel: once per animation frame. A position nobody can see
    // is a position not worth rationing — the display is the only rate that
    // means anything, pointer events can outrun it, and a cursor is two
    // floats and a flag relayed by a process that does nothing else. Pacing
    // by the display is both the smoothest possible and the cheapest that
    // still is.
    //
    // Without one: a timer, because each position is then a LiveView event
    // costing a render and a diff, and 60 a second of those is exactly the
    // load the channel exists to avoid.
    //
    // Either way the LAST position always goes. A bare throttle drops
    // whatever falls inside its window, and the final move of a gesture is
    // exactly that — so a peer's cursor stopped short of where the person
    // left it and stayed there until they moved again.
    flushMove() {
      if (!this.handle || !this.pending) return;

      if (BoardLink.get(this.frescoId)) {
        if (this.sendFrame) return;
        this.sendFrame = requestAnimationFrame(() => {
          this.sendFrame = null;
          this.sendMove();
        });
        return;
      }

      const wait = CURSOR_SEND_MS - (Date.now() - this.lastSent);
      if (wait > 0) {
        if (!this.moveTimer) {
          this.moveTimer = setTimeout(() => {
            this.moveTimer = null;
            this.flushMove();
          }, wait);
        }
        return;
      }

      this.sendMove();
    },

    sendMove() {
      if (!this.handle || !this.pending) return;

      const at = this.pending;
      this.pending = null;
      this.lastSent = Date.now();

      try {
        const pt = this.handle.screenToImage(at);
        if (pt && typeof pt.x === "number") {
          // The red pointer rides the cursor message rather than one of its
          // own: it IS this person's cursor, just drawn differently. Sending
          // it separately would mean two streams racing to say where the same
          // person is, and a moment showing both.
          // What they are holding rides along with where they are, for the
          // same reason the red pointer does: it is a fact about this
          // person's cursor, and a stream of its own would race with this
          // one and show the wrong tool for a moment on every change.
          const move = { x: pt.x, y: pt.y, pointer: this.pointing(), tool: this.tool() };

          // Straight down the channel when there is one — that is the whole
          // point of having it. Otherwise back through the LiveView, which
          // relays it exactly as it always did.
          if (!BoardLink.push(this.frescoId, "cursor", move)) {
            this.pushEvent("cursor:move", move);
          }
        }
      } catch (_) {}
    },

    // Which tool this user is holding, or null for the plain pointer.
    tool() {
      const layer = this.layer();
      if (!layer || typeof layer.getTool !== "function") return null;
      try { return layer.getTool() || null; } catch (_) { return null; }
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

      let c = this.cursors[p.id];
      if (!c) {
        c = {
          el: this.buildCursor(p.name, p.color, p.tool),
          tool: p.tool || null,
          lastSeen: 0,
          // Canvas coordinates throughout — converted to screen once per
          // frame, so a peer's cursor stays on the spot it is pointing at
          // while THIS viewer pans or zooms, rather than sticking to the
          // glass until the next packet arrives.
          at: { x: p.x, y: p.y },
          from: { x: p.x, y: p.y },
          to: { x: p.x, y: p.y },
          startedAt: 0,
          span: CURSOR_GLIDE_MS,
          interval: CURSOR_GLIDE_MS,
          lastPacket: 0
        };
        this.el.appendChild(c.el);
        this.cursors[p.id] = c;
      }

      this.setCursorTool(c, p.name, p.color, p.tool);

      const now = now_();

      // Glide over however long the packets are ACTUALLY taking, measured
      // rather than assumed. Sending is throttled to a fixed interval, but
      // arrivals are not: the network, the server and the browser's timers
      // all add jitter. Interpolating over a fixed guess means the cursor
      // finishes early and waits, or is still moving when it is overtaken —
      // either way the speed keeps changing, which is what reads as choppy.
      //
      // Smoothed, so one late packet nudges the estimate instead of
      // redefining it, and floored at the send interval so a burst can't
      // collapse the glide to nothing.
      if (c.lastPacket) {
        const gap = now - c.lastPacket;
        if (gap > 0 && gap < CURSOR_STALE_GAP_MS) {
          c.interval = c.interval * 0.7 + gap * 0.3;
        }
      }
      c.lastPacket = now;

      c.from = { x: c.at.x, y: c.at.y };
      c.to = { x: p.x, y: p.y };
      c.startedAt = now;
      c.span = Math.max(CURSOR_MIN_GLIDE_MS, Math.min(c.interval, CURSOR_MAX_GLIDE_MS));
      c.lastSeen = Date.now();

      this.startDrawing();
    },

    // One rAF loop for every cursor on the board.
    //
    // The alternative — a CSS transition per packet — cannot be smooth: the
    // browser restarts the transition each time the transform is set, so an
    // early or late packet visibly changes the cursor's speed. Interpolating
    // per frame decouples what is drawn from when packets happen to land.
    startDrawing() {
      if (this.raf) return;
      const step = () => {
        this.raf = null;
        if (this.draw()) this.startDrawing();
      };
      this.raf = requestAnimationFrame(step);
    },

    // Returns whether the loop should keep running.
    //
    // It runs for as long as anyone else is on the board, rather than only
    // while a glide is in flight: a peer standing still is still somewhere on
    // the canvas, and THIS viewer panning or zooming moves where that is on
    // screen. Settling the loop instead would leave their cursor stuck to the
    // glass until they happened to move again.
    //
    // The cost of that is a few transform writes per frame, and the write is
    // skipped when the value hasn't changed — so a still board with a still
    // peer does no DOM work at all.
    draw() {
      const ids = Object.keys(this.cursors);
      if (!ids.length || !this.handle) return false;

      const rect = this.el.getBoundingClientRect();
      const now = now_();

      ids.forEach((id) => {
        const c = this.cursors[id];
        const t = c.span > 0 ? Math.min(1, (now - c.startedAt) / c.span) : 1;

        c.at = {
          x: c.from.x + (c.to.x - c.from.x) * t,
          y: c.from.y + (c.to.y - c.from.y) * t
        };

        let screen;
        try {
          screen = this.handle.imageToScreen(c.at);
        } catch (_) {
          return;
        }

        // translate3d rather than translate: it keeps the cursor on its own
        // compositor layer, so moving it doesn't repaint what is under it.
        const transform =
          `translate3d(${screen.x - rect.left}px, ${screen.y - rect.top}px, 0)`;
        if (c.drawn !== transform) {
          c.el.style.transform = transform;
          c.drawn = transform;
        }
      });

      return true;
    },

    // The glyph for a peer's tool, drawn in their colour beside their arrow,
    // so the board shows what everyone is holding rather than five identical
    // arrows. Etcher owns the glyphs — they are the same ones it puts on the
    // local cursor — so nothing here has to know the set of tools, and one it
    // has no glyph for simply reads as an arrow.
    // A peer drawn as the cursor they are actually holding.
    //
    // Etcher composes this exact shape for the local cursor — a crosshair
    // with the tool's glyph tucked below-right of it — so someone holding the
    // marker sees a marker cursor. A peer holding the marker should look like
    // that too, in their own colour, rather than as a generic arrow with the
    // tool named in a label: the point of showing the tool is that it is
    // recognisable at a glance, and a shape is, where a word beside an arrow
    // is something you have to stop and read.
    //
    // Etcher owns the glyphs, so nothing here knows the set of tools. A tool
    // it has no glyph for — and the plain pointer — fall back to the arrow,
    // which is what the local cursor does in that case too.
    cursorMarkup(name, color, tool) {
      const fill = escapeAttr(color);
      // Clear of whichever mark is drawn. The tool cursor reaches further
      // down and right than the arrow does — its glyph sits below-right of
      // the crosshair — and a tag placed for the arrow lands straight on top
      // of it.
      const tagAt = (left, top) =>
        `<span data-pk-tag style="position:absolute;left:${left}px;top:${top}px;` +
        `background:${fill};color:#fff;font:600 11px/1.4 system-ui,sans-serif;` +
        `padding:1px 6px;border-radius:6px;white-space:nowrap;` +
        `box-shadow:0 1px 2px rgba(0,0,0,.25)">${escapeHtml(name)}</span>`;

      const badge = this.toolGlyph(tool);
      if (!badge) {
        return (
          `<svg width="18" height="18" viewBox="0 0 24 24" fill="${fill}" ` +
          `style="filter:drop-shadow(0 1px 1px rgba(0,0,0,.3))">` +
          `<path d="M4 2 L20 12 L13 13 L11 20 Z"/></svg>` + tagAt(14, 12)
        );
      }

      const tag = tagAt(22, 20);

      // Mirrors etcher's own composition: a white underlay under everything
      // so it stays legible over a dark photo or a busy drawing, then the
      // mark itself. Offset so the crosshair's centre — the actual pointer
      // position — lands on the point we were told about, rather than the
      // corner of the box.
      const cross = '<path d="M6 1.5v9M1.5 6h9"/>';
      return (
        `<svg width="30" height="30" viewBox="0 0 30 30" ` +
        `style="position:absolute;left:-6px;top:-6px;overflow:visible;` +
        `filter:drop-shadow(0 1px 1px rgba(0,0,0,.25))">` +
        `<g fill="none" stroke="#fff" stroke-width="3.5" stroke-linecap="round">${cross}</g>` +
        `<g fill="none" stroke="${fill}" stroke-width="1.5" stroke-linecap="round">${cross}</g>` +
        `<g transform="translate(14 14) scale(0.65)">` +
        `<g fill="none" stroke="#fff" stroke-width="4.5" stroke-linecap="round" ` +
        `stroke-linejoin="round">${badge}</g>` +
        `<g fill="none" stroke="${fill}" stroke-width="2" stroke-linecap="round" ` +
        `stroke-linejoin="round">${badge}</g></g></svg>` + tag
      );
    },

    // The raw glyph for a tool, or "" when there isn't one.
    toolGlyph(tool) {
      if (!tool) return "";
      const layer = this.layer();
      if (!layer || typeof layer.toolBadge !== "function") return "";
      try { return layer.toolBadge(tool) || ""; } catch (_) { return ""; }
    },

    buildCursor(name, color, tool) {
      const wrap = document.createElement("div");
      wrap.style.cssText =
        // Deliberately no CSS transition. The position is interpolated per
        // frame instead — a transition restarts every time the transform is
        // set, so an early or late packet visibly changes the cursor's speed,
        // and the two mechanisms would fight for the same property.
        "position:absolute;top:0;left:0;pointer-events:none;will-change:transform;z-index:40;";
      wrap.innerHTML = this.cursorMarkup(name, color, tool);
      return wrap;
    },

    // Redraw a peer when they pick up something else. Guarded on the tool
    // actually changing: this runs on every packet, and rebuilding the cursor
    // sixty times a second would be pure churn.
    setCursorTool(c, name, color, tool) {
      const next = tool || null;
      if (c.tool === next) return;
      c.tool = next;
      c.el.innerHTML = this.cursorMarkup(name, color, next);
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
