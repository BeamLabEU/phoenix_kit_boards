# PR #7: Update to etcher 0.12 and classify board uploads properly

**Author**: @alexdont (Sasha Don)
**Reviewer**: Grok (`GROK_REVIEW.md`); earlier lock-only pass in `phase1.md`
**Status**: Merged
**Commit**: `dea2aa5..99f979a`, merged as `bccea24`
**Date**: 2026-08-14

## Goal

Two independent changes on one PR:

1. Move the etcher lock from 0.11.0 to 0.12.1. The `~> 0.11` constraint
   already admits it; only the lock was holding the module back. 0.12 is
   additive on every API this module calls.
2. Stop storing every board upload with `file_type: "image"`. `@image_accept`
   deliberately invites audio and video, and hardcoding `"image"` broke those
   files everywhere core's media page trusts the column.

## What Was Changed

| File | Change |
|------|--------|
| `mix.lock` | etcher `0.11.0` → `0.12.1` |
| `lib/phoenix_kit_boards/web/board_live.ex` | `store/4` classifies through `Storage.determine_file_type/2` |

No version bump on the PR itself. The follow-up release is 0.4.4.

## Implementation Details

- The etcher bump is lock-only. `onShapesMoving` / `applyShapesMoving`,
  `toolBadge`, the prefs relay and the annotations events are unchanged; the
  two new 0.12 prefs (snap toggle, remembered label colour) ride the same
  opaque prefs blob this module already persists.
- Classification uses core's one shared classifier, from the entry's client
  type with the filename as fallback — the same call the media browser, media
  selector and upload controller already make.

## Related

- Review: [`GROK_REVIEW.md`](GROK_REVIEW.md)
- Earlier lock-only pass: [`phase1.md`](phase1.md)
