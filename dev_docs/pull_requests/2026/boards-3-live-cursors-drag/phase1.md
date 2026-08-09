# Phase 1 Review — boards PR #3

**Title:** Make boards feel live: smooth cursors, visible drags, and a much smaller wire  
**Author:** Sasha Don (alexdont)  
**Opened:** 2026-08-08  
**Reviewer:** Pincer  
**Date:** 2026-08-08

---

## Diff at a Glance

| Metric | Value |
|--------|-------|
| Files changed | 15 |
| Additions | +2,733 |
| Deletions | −71 |
| Migrations | None |
| Secrets / credentials | None found |
| Artifacts / swap / crash files | None |
| Unrelated changes | None |

**Files changed:**

- `CHANGELOG.md` — unreleased section added
- `lib/phoenix_kit_boards/web/board_channel.ex` — **new** — ephemeral Phoenix Channel
- `lib/phoenix_kit_boards/web/board_live.ex` — core changes: canvas optimization, embedded-image hoisting, media relay, prefs
- `lib/phoenix_kit_boards/web/board_socket.ex` — **new** — Phoenix Socket (optional host mount)
- `mix.exs` — bump etcher 0.10 → 0.11, fresco 0.10 → 0.11
- `mix.lock` — corresponding lock updates (etcher, fresco, tessera minor bumps)
- `priv/static/assets/phoenix_kit_boards.js` — JS rewrite: BoardLink, cursor interpolation, shape patching, tool cursors
- `test/board_socket_test.exs` — **new**
- `test/embedded_image_test.exs` — **new**
- `test/js/apply_delta_test.js` — **new** (node-runnable)
- `test/js/cursor_pointer_test.js` — **new** (node-runnable, 667 lines)
- `test/js/prefs_relay_test.js` — **new** (node-runnable)
- `test/js_apply_delta_test.exs` — ExUnit runner for JS test
- `test/js_cursor_pointer_test.exs` — ExUnit runner for JS test
- `test/js_prefs_relay_test.exs` — ExUnit runner for JS test

---

## What the PR Does

Four problems, four fixes, several additions.

**Root cause fixed:** `Fresco.canvas` encoded the entire board (including base64-embedded images) into `data-extensions` on every edit, even though `#board-root` is `phx-update="ignore"`. On the demo board that was 5.36 MB per edit — 5.34 MB of which was four embedded screenshots. This blocked the LiveView process, causing cursors to queue behind it (~1 s lag) and large frames to drop the socket entirely.

**Fixes:**
1. **Canvas rendered once at mount** — `@initial_canvas` assign is set at mount and never updated; `@canvas` stays live for persistence but never touches the template again. Zero bytes per edit for the canvas subtree.
2. **Embedded images hoisted to storage** — at board open and on every edit, base64 `data:` URLs are detected, uploaded to storage, and the shape rewritten to a URL. Sender is notified so their local copy cleans up too. Demo board: 5.36 MB → 22.9 KB per edit.
3. **Shape patching in place** — peers' deltas patch geometry/style in place rather than delete+re-add. No element rebuild, no media reload, no z-order sweep over unrelated shapes.
4. **Cursor interpolation per rAF** — positions feed an animation-frame loop interpolating over the measured inter-packet interval. Removes the CSS-transition restart stutter.

**Additions:**
- **Live shape drags** — `onShapesMoving` / `applyShapesMoving` (etcher 0.11) broadcasts in-flight geometry over the ephemeral channel. Nothing stored; abandoned drags snap back.
- **Tool cursors** — a peer is drawn as the cursor they are holding, using etcher's own per-tool glyph. Falls back to arrow for unknown tools.
- **Ephemeral channel (optional)** — `BoardSocket` + `BoardChannel` offload cursors and drag traffic off the LiveView. Host adds one endpoint line to enable; entirely optional, client falls back gracefully.
- **User prefs persistence** — etcher layout prefs stored to `user.custom_fields["etcher_prefs"]`; restored on next mount. Merged atomically to avoid two-tab overwrite.
- **Media playback sync** — video/audio commands relayed via PubSub; new peers asked to announce current state on join.
- **Audio/video upload** — `@image_accept` extended with audio/video formats; MIME list filtered at runtime against the host's `mime` library to avoid `ArgumentError` at mount; max size raised to 256 MB.

---

## Architecture / Design Quality

**Good:**

- The `@initial_canvas` / `@canvas` split is clean and solves the bloat at its actual source. The comment in the template (`@initial_canvas`, not `@canvas`) makes the intent impossible to miss.
- `BoardSocket` / `BoardChannel` are deliberately minimal. No persistence, no state beyond the topic, no auth duplication — the signed token carries identity and board binding cleanly. The channel verifies `peer.board == board_uuid` which is the critical cross-board check.
- Graceful degradation is first-class throughout: channel join fails → LiveView relay; etcher too old for `patchShape` → delete+re-add; no etcher at all → arrow instead of crash.
- `upload_accept/0` computing the accept list at runtime (filtering against `MIME.has_type?`) fixes a real deployment footgun (ArgumentError at mount on default installs).
- `hoist_embedded_images` is correct in shape: called both at open and on edit, notifies the sender so they clean up their local copy, and is a no-op when nothing is embedded (single pass, no write).
- `normalize_position/2` is defensive — arbitrary browser values become 0 rather than propagating `nil` or a string.
- `BoardLink.ensure/2` is idempotent, shared between both hooks, and handles token refresh on remount correctly.
- JS tests are unusually thorough: cursor interpolation math, pointer state machine, tool glyph rendering, fallback routing, XSS escaping — all covered with a node-runnable harness that reads from the actual built JS.

**One design note:**

`broadcast` is now sent *before* `Boards.save_annotations`. The PR comment explains the rationale (saves are slow; the information is already decided). The trade-off is real: a failed save leaves peers holding an un-stored edit until the next successful save corrects it, with no peer-facing signal. This is explicitly acknowledged in the comment and is reasonable for a collaborative canvas, but worth calling out for awareness.

---

## Correctness Concerns

### Medium — `reordered` field may never be set by the server

The JS `apply` function was changed from:
```js
// old — always re-imposes order when delta.order is present
if (delta.order && typeof layer.setShapeOrder === "function") { ... }
```
to:
```js
// new — only re-imposes when creates, deletes, or reordered === true
const structural = created.length > 0 || deleted.length > 0 || delta.reordered;
if (structural && delta.order && typeof layer.setShapeOrder === "function") { ... }
```

The `reordered` field is tested in `apply_delta_test.js` but is never set on the server side in this diff. The `push_event("board:apply", ...)` call is not visibly updated to include `reordered`. If the server never sends `reordered: true`, a pure z-order change (bring-to-front / send-to-back) would not be relayed to peers — a regression from prior behaviour. **Needs confirmation** that either (a) `Boards.apply_delta` already sets `reordered` in its output, or (b) z-order-only changes are not possible in this etcher version, or (c) this is an accepted gap.

### Low — Orphaned storage file if hoisting succeeds but DB save fails

In the edit path: if `hoist_embedded_images` uploads an image to storage and rewrites the annotation, then `Boards.save_annotations` fails, the shape's DB record still has the old `data:` URL but the file now exists in storage. Not a data-loss bug (the board stays heavy and the next successful edit re-hoists or the already-stored file is returned by dedup), but a storage leak. Low risk.

### Low — No size cap on embedded images decoded at mount

`migrate_embedded_images` decodes all base64 `data:` URLs in a board's shapes at mount. There is no per-image or per-board cap. A crafted board could carry very large embedded blobs that are decoded into memory before being streamed to storage. Only admins/collaborators can craft such shapes, so blast radius is small. Worth noting for large deployments.

---

## Security

- Signed token binds to (board, peer) — cannot be reused for a different board. The join check `peer.board == board_uuid` enforces this server-side. ✅
- `tool_name/1` in `BoardChannel` and `cursor_tool/1` in `BoardLive` both validate tool keys: max 32 bytes, `[a-z][a-z0-9_]*` regex. The key goes into a DOM lookup on the client; an arbitrary string has no business there. ✅
- `movable?/1` allows only shapes with binary `uuid` and map `geometry`. ✅
- `decode_data_url/1` only processes `data:` URLs; `hoist_shape/2` only processes shapes with `"data:" <> _` in `href`. No path traversal possible. ✅
- HTML/attr escaping for cursor name and color are covered by the XSS test in `cursor_pointer_test.js`. ✅
- `BoardSocket.id/1` returns `nil` (no per-user disconnect target). Per-connection anonymous: two tabs = two presences. Intentional; comment explains it. ✅
- No suspicious new dependencies. `tessera 0.3.5` is a patch bump; `etcher 0.11.0` and `fresco 0.11.0` are minor bumps in the BeamLabEU ecosystem. ✅

---

## Performance

This PR is primarily a performance fix. The headline numbers:
- Canvas render bytes per edit: 5.36 MB → 0 (canvas no longer re-rendered)
- After embedded image migration: 5.36 MB → 22.9 KB (demo board)
- Cursor latency: ~1 s → sub-frame over the ephemeral channel

The `hoist_embedded_images` fast path (`Enum.any?` → early return) means boards with no embedded images pay only one list scan per edit. The rAF draw loop writes DOM only when the transform value changes (`c.drawn !== transform`). Both are correct and well-reasoned.

---

## Test Coverage

Unusually good for a LiveKit PR:

| Test | What it covers |
|------|---------------|
| `board_socket_test.exs` | Token round-trip, cross-board protection, tamper detection, expiry, bad input |
| `embedded_image_test.exs` | `decode_data_url/1` — happy paths, MIME types, ext normalization, error cases |
| `js/apply_delta_test.js` | Patch-in-place logic, order conditions, etcher compatibility |
| `js/cursor_pointer_test.js` | Interpolation math, pointer state machine, tool glyphs, routing, XSS |
| `js/prefs_relay_test.js` | Prefs round-trip, empty-set handling, lazy-layer retry, teardown |

JS tests are shelled out via ExUnit and skipped cleanly if `node` is not on PATH.

---

## Suspicious Files Check

Nothing suspicious:
- No secrets, credentials, or env files
- No build artifacts or minified blobs (the `.js` file is the intentional bundled asset)
- No swap, crash, or archive files
- `mix.exs` dependency changes are minor version bumps with documented rationale
- `mix.lock` matches the declared changes (etcher, fresco, tessera)

---

## Verdict

**Recommend merge.** No critical blockers.

The one medium concern (`reordered` field) should be clarified before merging — if the server never emits it, z-order relay is silently broken for pure reorder operations. Everything else is clean code with good tests and a large concrete performance win.

**Awaiting Dmitri's approval to merge.**
