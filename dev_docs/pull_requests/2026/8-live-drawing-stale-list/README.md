# PR #8: Relay a stroke as it is drawn, and stop a stale list deleting somebody's work

**Author**: @alexdont
**Reviewer**: Claude
**Status**: Merged
**Commit**: `0cef6f4..fcd6c2d` (merge `03b38ef`)
**Date**: 2026-10-01

## Goal

Peers should see a stroke appear while it is being drawn, and a phone whose
socket stalled should no longer delete a shape a desktop drew in the meantime.

## What Was Changed

| File | Change |
|------|--------|
| `board_channel.ex` | `"drawing"` / `"drawn"` relay, `sanitize_draft/1`, per-stroke number |
| `board_live.ex` | `peer_arrivals` + `unseen_by_sender/4` / `merge_restored/3` — restore shapes a list omits that the sender cannot have seen; touch `select-none` |
| `phoenix_kit_boards.js` | `streamDrawing`, ghost handlers, stroke numbering, drop pushes while the socket is down |
| `mix.exs` | fresco `>= 0.13.1 and < 1.0.0`, etcher `~> 0.18` |
| `test/*` | `live_drawing_relay_test`, `stale_list_test`, `touch_selection_test` |
