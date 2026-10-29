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
{:phoenix_kit_boards, "~> 0.4"}
```

```bash
mix deps.get
mix phoenix_kit.update   # creates the phoenix_kit_boards table
```

Enable **Boards** on the admin Modules page. That's it — the sidebar tab,
routes, permission, and JS all wire up automatically (PhoenixKit auto-discovers
the module).

## What you get

- **Boards list** at `/admin/boards` — create / open / delete (all boards,
  whoever they belong to).
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
- **Boards that belong somewhere** — a board can belong to a *place* (a project,
  a contact, a page…), be private to its creator or shared with everyone who can
  see that place, and keep its files in a media folder of its own. See
  "Boards in your own pages" below.
- **A drop-in widget** — `PhoenixKitBoards.Web.Components.boards_panel/1` is a grid
  of a place's quick boards with a **+** tile: start from nothing, a note or a
  picture.

## Boards in your own pages

A widget for the quick boards of one place — put it in a section of any page,
wherever people jot things down:

```heex
<PhoenixKitBoards.Web.Components.boards_panel
  id="project-notes"
  scope={{"project", @project.uuid}}
  label="Notes"
  current_user={@current_scope.user}
  return_to={~p"/projects/#{@project}"}
/>
```

It is a grid of tiles, one per board, and a last tile of the same size that makes a
new one. With no boards yet that tile is all there is, centred:

- the big **+** makes an empty canvas and opens it;
- **Text** makes a canvas with a note already on it;
- **Image** makes a canvas with a picture already on it — the phone's camera or any
  file, and the tile is a drop target too.

Text and image boards stay on the page and show up as tiles; the empty one opens,
since there is nothing in it to see. A tile's menu renames, pins, makes private or
shared, archives or deletes. The widget does not manage places or projects: *you*
choose what place it is for (`scope` is any `{type, id}` pair of strings — a record,
`{"project", uuid}`, or something that is not one, `{"page", "/docs/setup"}`) and put
one wherever you want one. Every attribute is in the `PhoenixKitBoards.Web.BoardsPanel`
moduledoc; the ones you will reach for:

| attribute | what it does |
|---|---|
| `folder` | where the files of these boards go (below) |
| `visibility_options` / `default_visibility` | who can see what people create here; one value hides the choice (`[:private]` = a personal notepad, `[:shared]` = a team one) |
| `actions` | which ways to start a board to offer, from `[:empty, :text, :image]` |
| `limit` | tiles shown before "Show all" |
| `open` | `:navigate` or `:new_tab` |
| `show_label` | `false` to keep `label` for the folder name without drawing it |

Boards opened from the widget open at `/dashboard/boards/:id` (so people who are not
admins can open them) and link back to `return_to`.

### Who may see a place

The module cannot know what "can see project X" means in your app, so it asks:

```elixir
config :phoenix_kit_boards, :authorize, {MyApp.Boards, :can?}

# MyApp.Boards
def can?(action, user, {"project", id}) when action in [:view, :create],
  do: MyApp.Projects.member?(id, user)
```

With no hook any signed-in user may view and create. A hook that raises, exits or
answers anything but a boolean **denies**. The hook can narrow access, never
widen it: **private is always its creator's** (users holding the `boards` admin
permission may still open any board, as they always could on `/admin/boards`).
The panel renders nothing for a place the user may not view.

### Where a board's files go

Every upload on a board is filed in that board's own media folder, created on its
first upload, so boards in different places never mix their files in the media
root. By default: `Boards / <place> / <board>`. Change it per panel:

```heex
<%!-- inside that folder --%>
<PhoenixKitBoards.Web.Components.boards_panel ... folder={{:under, @project.files_folder_uuid}} />

<%!-- that chain of folders from the media root, created as needed --%>
<PhoenixKitBoards.Web.Components.boards_panel ... folder={{:path, ["Clients", "Acme"]}} />

<%!-- the media root itself --%>
<PhoenixKitBoards.Web.Components.boards_panel ... folder={:root} />
```

or for the whole app, with the same hook convention the other modules use:

```elixir
config :phoenix_kit_boards,
  attachments_parent_folder: {MyApp.Media, :board_parent},   # fun(:board, actor_uuid, %{scope:, label:})
  attachments_folder_name: {MyApp.Media, :board_name}        # fun(board, actor_uuid)
```

Deleting a board moves its folder to the media trash; files are never deleted.

### Staying current

The widget re-reads itself every few seconds (`poll`, in milliseconds; `0` turns it
off), which needs nothing from your page. For instant updates, subscribe your
LiveView to the place and forward the message:

```elixir
# mount/3, when connected?
PhoenixKitBoards.Boards.subscribe_scope({"project", project.uuid})

def handle_info({:boards_scope_changed, _board_uuid}, socket) do
  PhoenixKitBoards.Web.BoardsPanel.refresh("project-notes")
  {:noreply, socket}
end
```

## How it works

- PhoenixKit core already ships and loads `fresco.js` + `etcher.js` (the media
  annotation feature), so `<Fresco.canvas>` + `<Etcher.layer>` work here with
  **no host JS setup**. This module's collaboration hooks are delivered by the
  board page itself, as LiveView runtime hooks, so they work whatever the host
  does about JS — no compiler entry, no script tag, no `app.js` import.
  `js_sources/0` is still declared as a fast path for hosts running core's
  `:phoenix_kit_js_sources` compiler, and LiveView prefers it where it exists.
- Editing re-emits the full etcher annotation list (`etcher:annotations-changed`);
  the LiveView diffs, persists, and broadcasts over PubSub; peers apply the
  delta. Echo is broken server-side (an unchanged list diffs to empty).
- Presence and cursors ride the same PubSub topic; cursors are sent in canvas
  coordinates so they track each viewer's pan/zoom.

## Requirements

- `phoenix_kit ~> 2.0`, `fresco ~> 0.11`, `etcher ~> 0.11` (all resolved by the
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

## Optional: the ephemeral socket

Cursors and in-flight drags are high-rate and worthless a moment later, and
through a LiveView every position pays for a render and a diff — queued behind
that process's real work: saving edits, uploads, link previews. They can go
over a channel of their own instead. Sockets are declared on the endpoint, and
that belongs to the host, so this is one line in `endpoint.ex`:

```elixir
socket "/phoenix_kit/board", PhoenixKitBoards.Web.BoardSocket, websocket: true
```

Skipping it loses nothing that worked before: cursors fall back to the LiveView
relay, which is where they used to go, and live drags simply don't appear. The
client also falls back while the channel is joining and if it fails, so a
socket that dies mid-session degrades rather than dropping cursors silently.

Joining is governed by a short-lived signed token naming the board and the
peer, minted by the LiveView that rendered the page. The channel re-derives
both from it, so a client cannot join a board it was never shown, or present as
somebody else. Mounted somewhere other than the default path? Say so, and the
client is told rather than left to guess:

```elixir
config :phoenix_kit_boards, board_socket_path: "/somewhere/else"
```

## License

MIT.
