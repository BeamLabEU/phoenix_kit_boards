# PR #2: Board images to storage, link previews, and z-order sync fixes

**Author**: @alexdont (Alexander Don)
**Reviewer**: Claude
**Status**: Merged
**Commit**: `4bdebb7..e66c9e5`, merged as `a636904`
**Date**: 2026-08-04

## Goal

Stop a board getting heavier every time somebody pastes a picture into it, and
fix two independent bugs the work uncovered — a dropped z-order change and a
migration coordinator that guessed at an unstamped table.

The through-line is Etcher's emit model: **the whole annotation list is
re-emitted on every edit**. Anything living inside a shape is therefore re-sent
in full whenever anything on the board changes. An embedded screenshot is a few
MB, so two or three of them push routine edits — moving a shape, typing a
label — past the LiveView socket's 8 MB frame limit, where the socket closes
with 1009 and the edit is lost with nothing to show the user.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_boards/web/board_live.ex` | Image-upload path (`allow_upload` + progress callback → `PhoenixKit.Modules.Storage`), `board:unfurl` handler, z-order in the annotation diff |
| `lib/phoenix_kit_boards/link_preview.ex` | **New.** Fetch a pasted URL → OpenGraph → `OpenFresco.Scene` → SVG card, behind an SSRF guard |
| `lib/phoenix_kit_boards/migrations.ex` | Version detection for an unstamped table: infer from the table's shape instead of assuming V1 |
| `priv/static/assets/phoenix_kit_boards.js` | `setImageUploader` / `setLinkUnfurler` wiring, upload queue + watchdog, `setShapeOrder` on applied deltas, open boards ready to edit |
| `mix.exs` | `fresco`/`etcher` to `~> 0.10`; added `req`, `floki`, `open_fresco` |
| `README.md` | `max_frame_size` requirement for the host endpoint |
| `test/board_delta_test.exs` | **New.** Pins the z-order rules |
| `test/migrations_test.exs` | **New.** Pins version-comment parsing |

### The four threads

1. **Images to storage.** `BoardSync` registers `layer.setImageUploader`, which
   feeds the file to a hidden `live_file_input` through `this.upload/2`. The
   LiveView stores it via `Storage.store_file_in_buckets/6` and pushes the URL
   back; the shape keeps the URL instead of the bytes. Request and reply are
   paired **by order**, which holds because `uploadImage` serialises pastes and
   `max_entries` is 1.

2. **Link previews.** A pasted URL goes to `handle_event("board:unfurl", …)`,
   which fetches the page, reads its OpenGraph tags, lays a card out with
   `open_fresco` and replies with an SVG. The client rasterises that and sends
   it back through the image path above, so a card ends up in storage like any
   other pasted picture. SVG rather than PNG because open_fresco's rasterizer
   is an optional native dependency and "magick is installed" is not the same
   as "magick can draw an SVG" — the browser already has a correct renderer.

3. **Z-order.** Position in the annotation list *is* z-order. The diff keyed
   purely by uuid, so a pure reshuffle produced an empty delta: bringing a
   caption in front of an image was neither saved nor broadcast. The delta now
   carries `"reordered"` and a full `"order"` list, and the client re-imposes
   it with `setShapeOrder` after applying — necessary on *every* delta, not
   just reorders, because the client applies updates by removing and re-adding
   and re-adding appends.

4. **Unstamped migration tables.** `read_version/2` fell back to a hardcoded
   `1` when the `COMMENT ON TABLE` marker was missing, asserting "already
   current" about a table nobody had checked. It now infers the version from
   the table's actual columns, and `up/1` raises with recovery instructions
   when the shape matches no known version.

## Implementation Details

- **`fresco ~> 0.10`, `etcher ~> 0.10`.** `fresco` matches PhoenixKit core
  exactly. `etcher` is deliberately tighter than core's `~> 0.9` because
  `setImageUploader`/`setLinkUnfurler` arrived in 0.10.0 and core's constraint
  would resolve 0.9.0 and leave both features silently degraded. Narrower is
  still compatible: a two-part `~>` runs to the next major.
- **`open_fresco` needs no rasterizer here.** The optional `:resvg` NIF and the
  CLI backends are unused; cards are emitted as SVG.
- The hidden upload `<form>` is load-bearing, not decoration: `this.upload/2`
  tracks files and dispatches a bubbling `input` event, and a form's
  `phx-change` is what carries that to the server.

## Testing

- [x] Unit tests added (`board_delta_test.exs`, `migrations_test.exs`, and
      `link_preview_test.exs` added during review)
- [x] `mix precommit` green
- [ ] Integration tests — not applicable; this suite runs without a DB
- [ ] Migration tested on staging — the V1 DDL is unchanged; only version
      *detection* moved

## Related

- Review: [`CLAUDE_REVIEW.md`](CLAUDE_REVIEW.md)
- Previous PR: [#1](/dev_docs/pull_requests/2026/1-add-collaborative-boards-module/)
