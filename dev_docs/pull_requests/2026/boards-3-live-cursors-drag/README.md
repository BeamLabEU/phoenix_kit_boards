# PR #3: Make boards feel live: smooth cursors, visible drags, and a much smaller wire

**Author**: @alexdont (Sasha Don)
**Reviewer**: Pincer (`phase1.md`), Claude (`CLAUDE_REVIEW.md`)
**Status**: Merged
**Commit**: `4bad16a` (merge of `cd5e6b8`)
**Date**: 2026-08-08

> Written after the merge, from the diff and the CHANGELOG — the branch shipped
> without one and the convention asks for it.

## Goal

Remote cursors lagged about a second and the socket dropped on boards carrying
images. The cause was one thing: `Fresco.canvas` writes the whole annotation
list into `data-extensions`, the template rendered the live `@canvas` assign,
and every edit changed it — so each edit re-encoded and diffed the entire board
and pushed the result down the socket, from either end. On the demo board that
was 5.36 MB per edit, 5.34 MB of it four screenshots embedded as base64. All of
it discarded on arrival, since `#board-root` is `phx-update="ignore"`; the
encode blocking the LiveView while cursor messages queued behind it was not.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `web/board_live.ex` | `@initial_canvas` split off `@canvas`; embedded-image hoisting at open and on edit; media relay; user prefs; runtime-filtered upload accept list; broadcast moved ahead of save |
| `web/board_socket.ex` | **new** — optional `Phoenix.Socket` for ephemeral traffic, joined with a signed token |
| `web/board_channel.ex` | **new** — relays `cursor` / `moving` / `moved`, nothing else |
| `priv/static/assets/phoenix_kit_boards.js` | `BoardLink`; shape patching in place; per-rAF cursor interpolation; per-tool cursor glyphs |
| `mix.exs` / `mix.lock` | fresco 0.10 → 0.11, etcher 0.10 → 0.11 |
| `test/` | `board_socket_test.exs`, `embedded_image_test.exs`, three node-runnable JS suites with ExUnit runners |

### The four fixes

1. **Canvas rendered once.** `@initial_canvas` is assigned at mount and never
   again; `@canvas` stays current for persistence but never reaches the
   template. Zero bytes per edit for the canvas subtree.
2. **Embedded images hoisted to storage**, at open as well as on edit, with the
   sender told about the rewrite so its own copy stops carrying the bytes.
   5.36 MB → 22.9 KB per edit on the demo board.
3. **Shapes patched in place** rather than deleted and re-added — no element
   rebuild, no media reload, no z-order sweep over unrelated shapes.
4. **Cursors interpolated per animation frame** over the measured inter-packet
   interval, replacing a CSS transition that restarted on every packet.

### Added

- **Live drags** — `onShapesMoving` / `applyShapesMoving` (etcher 0.11) put
  in-flight geometry on the ephemeral channel. Nothing stored; an abandoned
  drag snaps back.
- **Tool cursors** — a peer is drawn as the cursor they are holding, using
  etcher's own glyph in their colour. Unknown tool → arrow.
- **The ephemeral channel** — `BoardSocket` + `BoardChannel`, opt-in with one
  endpoint line, falling back to the LiveView relay when absent.
- **User prefs** — etcher layout preferences on `user.custom_fields`, merged
  inside the UPDATE so two tabs don't overwrite each other.
- **Audio/video** — uploads and shared playback, relayed over the existing
  PubSub topic, with newcomers asking the room to announce where it is.

## Implementation Details

- Echo suppression stays server-side (`when from == self()`); the channel uses
  `broadcast_from` for the same reason.
- The join token names the board and the peer; `BoardChannel.join/3` checks
  `peer.board == board_uuid`, which is the whole of the access control.
- `upload_accept/0` filters `@image_accept` against `MIME.has_type?` at
  runtime — `allow_upload` raises on a filter the host's `mime` config cannot
  resolve, which took the board page down at mount on a default install.
- `broadcast` runs before `save_annotations`: nothing in the message depends on
  the result, and peers no longer wait out a database round trip. The trade is
  on record in `CLAUDE_REVIEW.md`.

## Testing

- [x] Unit tests added (`board_socket_test.exs`, `embedded_image_test.exs`)
- [x] JS behaviour pinned by three node-runnable suites that read the built
      bundle, shelled out from ExUnit and skipped cleanly without `node`
- [x] Backward compatibility verified — `handle_info` reads the older 5-tuple
      and bare-boolean cursor shapes, so a rolling deploy doesn't crash boards
- [x] Documentation updated (post-merge; see `CLAUDE_REVIEW.md`)
- [ ] No migration — this PR adds no schema change

## Related

- Post-merge review and fixes: [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md)
- Pre-merge review: [`phase1.md`](phase1.md)
- Previous PR: [#2](../2-board-images-links-zorder/)
