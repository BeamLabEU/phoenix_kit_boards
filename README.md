# PhoenixKitBoards

Collaborative infinite-canvas **boards** for [PhoenixKit](https://hexdocs.pm/phoenix_kit).

Admins open **Boards** in the sidebar, create a board, and open it — an
infinite [Fresco](https://hex.pm/packages/fresco) canvas with the
[Etcher](https://hex.pm/packages/etcher) drawing layer (shapes, text, images).
Multiple people on the same board see each other's edits, cursors, and presence
in real time. Each board is one row in `phoenix_kit_boards`.

## Installation

```elixir
# host app mix.exs
{:phoenix_kit_boards, "~> 0.1"}
```

```bash
mix deps.get
mix phoenix_kit.update   # creates the phoenix_kit_boards table
```

Enable **Boards** on the admin Modules page. That's it — the sidebar tab,
routes, permission, and JS all wire up automatically (PhoenixKit auto-discovers
the module).

## What you get

- **Boards list** at `/admin/boards` — create / open / delete.
- **A board** at `/admin/boards/:id` — the collaborative canvas.
- **Real-time collaboration** — shapes/text/images sync across everyone on the
  board; a presence roster and live cursors show who's there.
- **DB-backed** — the `Fresco.Canvas` document is stored in the `data` jsonb
  column; no files.

## How it works

- PhoenixKit core already ships and loads `fresco.js` + `etcher.js` (the media
  annotation feature), so `<Fresco.canvas>` + `<Etcher.layer>` work here with
  **no host JS setup**. This module's collaboration hook is delivered via
  `js_sources/0`, which core's `:phoenix_kit_js_sources` compiler folds into
  the host LiveSocket.
- Editing re-emits the full etcher annotation list (`etcher:annotations-changed`);
  the LiveView diffs, persists, and broadcasts over PubSub; peers apply the
  delta. Echo is broken server-side (an unchanged list diffs to empty).
- Presence and cursors ride the same PubSub topic; cursors are sent in canvas
  coordinates so they track each viewer's pan/zoom.

## Requirements

- `phoenix_kit ~> 1.7`, `fresco ~> 0.6`, `etcher ~> 0.7` (all resolved by the
  host — this module references their components and reuses their loaded JS).

## License

MIT.
