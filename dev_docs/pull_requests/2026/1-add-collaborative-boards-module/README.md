# PR #1: Add collaborative boards module (0.1.0)

**Author**: @alexdont
**Reviewer**: Claude
**Status**: Merged
**Commit**: `19465c1` (merged via `aa12fe6`)
**Date**: 2026-07-24

## Goal

First release of `phoenix_kit_boards`: admin-only, infinite-canvas collaborative
boards (shapes, text, images) built on `Fresco` + `Etcher`, with real-time
sync (shape edits, presence roster, live cursors) over PubSub.

## What Was Changed

### Files Modified

| File | Change |
|------|--------|
| `lib/phoenix_kit_boards.ex` | `PhoenixKit.Module` callbacks — admin tab, route/migration modules, JS bundle registration |
| `lib/phoenix_kit_boards/board.ex` | `Board` schema (`name`, `data` jsonb canvas doc, `created_by`) |
| `lib/phoenix_kit_boards/boards.ex` | Context: board CRUD + canvas load/save/diff helpers |
| `lib/phoenix_kit_boards/migrations.ex` | Standalone versioned migration coordinator (v0 → v1) |
| `lib/phoenix_kit_boards/routes.ex` | `/admin/boards` (list) + `/admin/boards/:id` (canvas) route macros |
| `lib/phoenix_kit_boards/paths.ex` | Centralized path helpers |
| `lib/phoenix_kit_boards/web/index_live.ex` | Boards list LiveView (create/open/delete) |
| `lib/phoenix_kit_boards/web/board_live.ex` | Single-board LiveView — canvas render + collab (shapes/presence/cursors) |
| `priv/static/assets/phoenix_kit_boards.js` | `BoardSync` + `BoardCursors` LiveView hooks (prebuilt JS bundle) |

### Schema

```elixir
schema "phoenix_kit_boards" do
  field(:name, :string)
  field(:data, :map, default: %{})
  field(:created_by, :binary_id)
  timestamps(type: :utc_datetime_usec)
end
```

## Implementation Details

- **Collaboration model**: no CRDT/OT — each client re-emits its full
  annotation list on every edit; the server diffs against the last-known
  list, persists, and broadcasts a `{created, updated, deleted}` delta.
  Peers apply the delta client-side via `window.Etcher.layerFor(id)` (no
  canvas remount). Last-write-wins on concurrent saves — acceptable for a
  v0.1 given the target usage (small teams, low edit contention).
- **Presence**: hand-rolled join/hello/leave broadcast over the board's
  PubSub topic, not `Phoenix.Presence`.
- **Zero host JS setup**: hooks ship via `js_sources/0`; core's compiler
  folds them into the host's `phoenix_kit_modules.js`.

## Testing

- [x] Module-metadata unit tests only (`test/phoenix_kit_boards_test.exs`, 2 tests)
- [ ] Context / LiveView / integration tests — **not present**, see review
- [ ] Migration tested against a real DB
- [ ] `--prefix` (named-schema) install verified

## Related

- Review: [CLAUDE_REVIEW.md](./CLAUDE_REVIEW.md)
