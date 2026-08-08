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
- **Pasted images go to storage** — not into the board document. A pasted or
  dropped image is uploaded through PhoenixKit's Storage module and the shape
  keeps only its URL.
- **Pasted links become preview cards** — the server fetches the page's
  OpenGraph tags (under an SSRF guard, a size cap and a time budget), draws a
  card, and stores it like any other board image. A link that can't be
  previewed simply stays on the canvas as text.
- **DB-backed** — the `Fresco.Canvas` document is stored in the `data` jsonb
  column.

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

- `phoenix_kit ~> 1.7`, `fresco ~> 0.10`, `etcher ~> 0.10` (all resolved by the
  host — this module references their components and reuses their loaded JS).
- **PhoenixKit's Storage module, with at least one bucket enabled**, if you
  want pasted images to be uploaded rather than embedded. Without it every
  upload fails, Etcher falls back to embedding the bytes in the shape, and the
  `max_frame_size` note below becomes load-bearing again.
- **A rasterizer is *not* required.** Link preview cards are emitted as SVG and
  rasterised by the browser, so no `:resvg` NIF or `resvg`/`rsvg-convert`/
  `magick` binary is needed.
- **Raise the LiveView socket's `max_frame_size` in the host endpoint.**

  ```elixir
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], max_frame_size: 64_000_000],
    longpoll: [connect_info: [session: @session_options]]
  ```

  Every edit re-emits the *whole* annotation list. Pasted images are uploaded
  to storage and travel as URLs, which is what keeps that list small — but
  Etcher falls back to embedding an image as a base64 data URL whenever an
  upload fails (no bucket configured, storage unreachable, the board closed
  mid-transfer), and one embedded screenshot is easily a few MB. A board
  carrying a couple of those pushes routine edits — moving a shape, typing a
  label — past the 8 MB default. The socket then closes with 1009 (Message Too
  Big) and reconnects, so the edit never reaches the server and is lost, with
  nothing to show for it but a flicker of the page's loading bar.

  So this is headroom for the fallback path, not the mechanism boards rely on.
  It raises the ceiling; it does not remove it.

## License

MIT.
