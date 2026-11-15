# PR #11 — Export as PDF, the media viewer's look on the board page, and boards opening over the page

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; four follow-ups applied

Merged into `main` as 3251941 (commits a1fb64c, dab606c, a3bfe37, 6ead41b, then 7e21e7c for the fresco 0.16 /
etcher 0.25 floors). This review was done in the pre-release pass over everything since v0.7.0, which also
covered #12–#14 again (their own reviews are in `12-…`, `13-…` and `14-…`) and the core floor bump.

What it does:
- **Board page.** `pdf_export` (named after the board), `actual_size`, and the nav as one dark mirrored bar with
  fullscreen / rotate left / reset behind the ⋯. Etcher's View | Annotate switch (`nav_buttons: [:modes]`)
  replaces the pencil.
- **Widget export.** "Export as PDF" in each tile's menu mounts the board off screen (`left: -20000px`, not
  `visibility: hidden`, because the export reads computed styles). It uses the same `<Fresco.canvas>` +
  `<Etcher.layer>`. The `BoardsPanelExport` runtime hook waits for `Fresco.onReady` and
  `Etcher.layerFor(id).isReady()`, waits two frames, exports, and reports `export_done`.
- **Overlay.** `open: :overlay` is the new default. A tile or the big **+** opens `/dashboard/boards/:id?embed=1` in
  an `<iframe>` over the page. The embedded page has `layout: false` and no back arrow.

Checked and fine:
- **Access.** `open_board` and `export_pdf` go through `visible_board/2` (this place, visible to this user, listable).
  The framed page applies the user route's own `Access.can_open?/3` on mount, on every event and every 5 s. An id
  from another place or someone else's private board opens and exports nothing, and tests pin both.
- **The frame's permissions.** `fullscreen; clipboard-read; clipboard-write`, plus `bluetooth` only with the laser
  measure on (#14's follow-up).
- **Mount twice.** The embedded page still loads nothing on the disconnected pass.
- **Framing.** Phoenix's default `x-frame-options: SAMEORIGIN` admits a same-origin frame. A host CSP of
  `frame-ancestors 'none'` would not, so that is now documented in the README and the CHANGELOG with
  `open={:navigate}` as the way out.

## Findings

### BUG - MEDIUM — A board that closed under the overlay loaded the site's home page in the frame (fixed)

The embedded page shares `not_found/1` with the user route, which redirects to `back_to`. The overlay's `src`
carries no `return_to`, so `back_to` is `/`. When the open board was deleted, made private or refused by the host,
the frame loaded the host's home page inside the overlay, layout and all. The same happened on a revoked `boards`
key.

Fix: embedded, `not_found/1` redirects to `Paths.embedded_gone/1` (`…?embed=1&gone=1`, id URL-encoded). There the
page mounts with nothing loaded and says "Board not found.". It stays a full redirect on purpose: rendering the
message in place would keep the LiveView alive, and with it the board's channel, whose lifetime is tied to the
page's pid. `gone` means nothing without `embed`. Tests: a refused mount and a delete while open both land on
`embedded_gone`, and the gone frame renders no `#board-root`.

### BUG - MEDIUM — Flashes never showed in the overlay (fixed)

`layout: false` also drops the layout's flash group. That left "Could not save the board.", the one message
that says an edit was lost, invisible in the overlay, which is now the default way boards are opened. Fix: the
embedded page renders core's `<.flash_group>` itself (`id="board-flash"`). The page on its own still uses the
host's.

### BUG - LOW — "Export as PDF" could stay disabled for the life of the page (fixed)

`exporting` is cleared only by `export_done`. If the hook never ran (the runtime-hook script blocked, a JS error
before `mounted`), every tile's item stayed disabled until a reload. Fix: `export_pdf` arms a
`send_update_after(…, export_timeout: seq)` for 45 s, after the script's own 30 s. `export_done` now carries the
export's `seq` (from `data-seq`) and is ignored unless it matches, so an abandoned export's late answer cannot end
the one after it. Tests cover the watchdog, a stale watchdog, and a stale answer.

### BUG - LOW — A copy taken down before it was ready kept polling (fixed)

The hook's `wait` loop checked a closure-local `done` that `destroyed()` never set, so it polled every 100 ms
forever, and could call `exportPdf` on a detached element. `done` now lives on the hook, and `destroyed()` sets it.
There is a JS test for it.

### IMPROVEMENT - LOW — The overlay outlived a change of place (fixed)

A host that moves the widget to another `scope` while it stays mounted kept the old place's board in the overlay,
and any export still running. `reset_context/2` now clears `viewing` and `exporting` along with the rest of the
per-place state. There is a test for it, using a new `{:set_opts, _}` on the test host.

### NITPICK — Escape closes the overlay only while focus is outside the frame (not changed)

`phx-window-keydown` is the parent page's. Once someone clicks into the board, keys go to the frame. The ✕ is
always there, and Escape inside the board belongs to Etcher (deselect, cancel a tool), so forwarding it would
need care.
