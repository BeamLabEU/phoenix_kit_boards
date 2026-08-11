# Changelog

All notable changes to **PhoenixKitBoards** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

## 0.4.3 - 2026-08-11

### Fixed

- **Live cursors, in-flight drags and stored preferences never arrived** (#6),
  the third release running whose symptom was "collaboration is broken". 0.4.1
  fixed bundle *delivery*; this fixes what delivering late does to the join
  handshake.

  Anything `push_event`-ed from the connected `mount` rides the join reply and
  is dispatched the moment it lands. That was safe while hooks were registered
  on the host's LiveSocket at construction time — `mounted` had already run.
  Under runtime-hook delivery it is a race that is *always* lost: the shim's
  `mounted` starts a ~40 KB fetch, and the real `BoardSync.mounted`, where
  `handleEvent("board:channel")` is registered, runs hundreds of milliseconds
  later. Both of this board's mount-time pushes are load-bearing — the
  ephemeral channel's token and the user's preferences — so the board rendered,
  edited and saved while the collaborative half silently never started. A host
  log showed 12 successful bundle fetches and zero `BoardSocket` connections.

  Both hooks now push `board:ready` as the last thing their `mounted` does, and
  the LiveView answers with the prefs and the channel offer; `mount_connected`
  pushes nothing. Correct under both delivery models — a host-registered hook
  simply pings a few milliseconds earlier — and any push added later inherits
  the guarantee instead of quietly reintroducing the race.

## 0.4.2 - 2026-08-11

### Changed

- Dependency updates: `phoenix_kit` 2.2.0 and the transitive set it pulls
  (`phoenix` 1.8.10, `hackney` 4.7.3). No source changes in this package.

## [0.4.1] - 2026-08-11

### Fixed

- **The hook bundle was refused with a 403 on every load, so boards were never
  collaborative** (#5). 0.4.0 moved hook delivery onto a route this module
  serves, and `Plug.CSRFProtection` refuses any GET that returns a JavaScript
  content-type, is not an XHR, and has not opted out — all three held, because
  the shim loads the bundle with `document.createElement("script")`. The guard
  runs in `before_send`, so a signed-in admin with a perfectly good session got
  the same 403 and it never presented as an authorization problem. The route
  now sets `plug_skip_csrf_protection`, which is safe here: the bundle is read
  at compile time and is byte-identical for every visitor, carrying no user,
  session or board data.

- **A failed bundle load was memoized**, so one bad response left the tab
  non-collaborative until someone reloaded it, and navigating between boards
  never retried. The failure is now forgotten, and the dead `<script>` node is
  removed rather than left in `<head>`.

### Changed

- **A failed load now says why.** A script element's error event carries no
  status, so the shim refetches and reports it — naming CSRF's
  cross-origin-script guard on a 403, and the page's Content-Security-Policy
  when the refetch succeeds (the response was fine; something blocked execution).
  It also no longer contradicts itself: the "loaded but defined no hooks"
  message is suppressed on a path where nothing loaded at all.

## [0.4.0] - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7. Core 2.0.0 squashes the
  migration chain into a single `V135` baseline and *refuses* to migrate a
  database below it — check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` (the migration bridge),
  migrate to at least V135, and only then move to 2.0. This package does not
  call migration internals, so the change is the pin itself.

### Added

- **Collaboration works on any host, with no JS setup.** The board page now
  delivers its own hooks as LiveView runtime hooks, and serves the bundle from
  a route this module owns. Adding the dependency is the whole installation —
  no `compilers:` entry, no vendor `<script>` tag, no `app.js` import.

  Hosts running core's `:phoenix_kit_js_sources` compiler are unaffected:
  LiveView checks the host's own registration first, so it keeps using that
  and there is never a second copy. A host enforcing a Content-Security-Policy
  can pass a nonce.

### Fixed

- **Collaboration silently did nothing on some hosts.** The hooks were
  delivered only through `js_sources/0`, which only core's
  `:phoenix_kit_js_sources` compiler consumes. A host that bundles dependency
  JS its own way got no hooks and no error anywhere — the board rendered, the
  canvas worked, local edits saved, and only peers' edits and cursors never
  arrived, so it read as "collaboration is broken" rather than "the JS never
  loaded". See the runtime-hook delivery above.

## [0.3.0] — 2026-08-08

### Added

- **Audio and video on a board, played together.** Drop or paste an audio or
  video file and it becomes a player (etcher 0.11). Whoever presses play, pauses, or
  scrubs drives it for everyone in the room — a teacher and their students
  hear the same moment of a recording.

  Anyone may control it: commands are relayed verbatim over the board's
  existing PubSub topic and the last one to arrive wins. There is no
  ownership check and no conflict resolution, because for a shared listening
  session there is nothing to resolve — the useful behaviour is that the
  transport does what the last person to touch it said.

  Uploads accept audio and video alongside images, with the size cap raised to
  256MB (a screen recording runs to hundreds of MB where a pasted screenshot
  is under one). This is the LiveView upload channel, which chunks — not the
  socket's frame limit. Past this the answer isn't a bigger number but an
  external uploader, so bytes go straight to storage instead of through the
  server; worth doing when someone actually hits it.

  Upload progress reaches the placeholder Etcher draws on drop. The LiveView
  has pushed `board:image-progress` all along and the hook only used it to
  keep a watchdog alive; it now also feeds Etcher's bar, so a large file
  shows how far along it is rather than only that it started.

  The accept list is filtered at runtime against what the host's `mime`
  config can actually resolve. `allow_upload` raises on a filter it can't
  map — and on a default install `.m4a`, `.ogg`, `.m4v` and `audio/mp4` are
  all unmappable — which took the whole board page down at mount instead of
  degrading. Every format is named both by extension and by MIME type, so
  dropping one form leaves the other.

  A peer joining **while something is already playing** is caught up: on join
  the room is asked to announce where it is, and the answer is relayed.
  Clients already in step ignore it, since it lands inside etcher's drift
  tolerance, so this costs one round trip per join.

- **Watch someone move a shape while they are moving it.** Shapes are emitted
  for persistence when a gesture *ends*, so a peer saw nothing for the length
  of a drag and then the shape somewhere new. In-flight positions travel too
  now, and peers patch them into place as they arrive.

  Nothing about them is stored: the edit itself still lands the usual way on
  release, and an abandoned drag snaps back rather than leaving everyone at a
  position nobody recorded.

- **A cursor shows who is holding what.** A peer's pointer is drawn as the
  cursor they actually have in hand — etcher's own per-tool mark, in that
  person's colour — rather than as one of several identical arrows with a name
  beside it. Someone holding nothing keeps the arrow.

- **Cursors and in-flight drags have a channel of their own.** Both are
  high-rate and worthless a moment later, and through a LiveView every
  position paid for a render and a diff, queued behind that process's real
  work — saving edits, uploads, link previews.

  Optional, because sockets are declared on the endpoint and that belongs to
  the host. One line enables it:

  ```elixir
  socket "/phoenix_kit/board", PhoenixKitBoards.Web.BoardSocket, websocket: true
  ```

  A host that skips it loses nothing that worked before: cursors fall back to
  the LiveView relay, and live drags simply don't appear. The client also
  falls back while the channel is joining, or if it fails, so a socket that
  dies mid-session degrades rather than dropping cursors silently.

  Joining is governed by a signed token naming the board and the peer, minted
  by the LiveView that rendered the page. The channel re-derives both from it,
  so a client cannot join a board it was never shown, or present as somebody
  else.

### Fixed

- **The whole board was sent on every edit.** `Fresco.canvas` writes the
  annotations into `data-extensions`, and the template rendered the canvas
  assign — which every edit changes. So each edit re-encoded and diffed the
  entire board and pushed the result down the socket, from either end. On a
  board carrying a few images that is megabytes, per edit.

  All of it was discarded on arrival, since `#board-root` is
  `phx-update="ignore"`. The cost was not: the encode blocked the LiveView
  while cursor messages queued behind it, which is what made remote cursors
  choppy and about a second late, and a frame that size is enough to drop the
  socket and remount the peer. The canvas is rendered once at mount now and
  skipped forever after.

- **An image pasted before uploads worked was re-sent forever.** An image
  whose upload fails is embedded in the shape as a base64 data URL so the
  paste survives, and the client re-sends every shape on every edit — so one
  screenshot went up the socket again each time anyone nudged a marker. Those
  bytes are moved into storage the first time they arrive and the shape
  rewritten to point at the stored file, once per image, at open as well as on
  edit. A real board went from 5.36 MB per edit to 22.9 KB.

- **Watching a peer edit flashed the whole board.** Every changed shape was
  deleted and re-added, which rebuilds the element — media reloads, images
  re-decode — and because re-adding appends, the layering was then re-imposed
  across every shape on the board. Changed shapes are patched in place now,
  and the order re-imposed only when it can actually have moved.

- **A peer's cursor stuttered.** Its position was handed to a CSS transition,
  and a transition restarts every time the transform is set, so an early or
  late packet visibly changed the cursor's speed. Positions feed an
  animation-frame loop now, interpolating over the interval they are
  measurably arriving at, which decouples what is drawn from when packets
  land. Cursors are also held in canvas coordinates and converted per frame,
  so a peer standing still stays on the spot they are pointing at while you
  pan or zoom.

- **A shape the viewer could not patch jumped to the front and stayed there.**
  Layering is only re-imposed when it can have moved, and an update was assumed
  not to move anything. But an update patching cannot express — a peer removed
  a style or metadata key, the shape changed kind, or this viewer's etcher has
  no `patchShape` at all — falls back to deleting and re-adding it, and
  re-adding appends. On an older etcher that is *every* peer edit, quietly
  reshuffling the board one shape at a time for that viewer alone, with nothing
  to correct it until someone added or removed something. The decision now
  comes from what actually happened on this client, which is the only place it
  can: the server cannot know which of its updates a given viewer managed to
  patch.

- **Leaving a board left its socket open and a draw loop running.** The
  ephemeral channel lives on a map that outlives the page and nothing closed
  it, so walking back to the board list kept the connection joined with a
  cursor handler still holding the torn-down hook. Every packet from a peer
  still on that board then drew into an element no longer in the document and
  restarted the animation-frame loop, which by then had nothing left to cancel
  it — one per board opened, for the life of the tab. Both hooks close the link
  on teardown now, and a packet that races the close lands nowhere.

- **The media transport relayed two unchecked fields.** `uuid` and `action`
  arrive from a browser and go straight to every peer; every other value on
  that path is constrained, and these were not. Non-string commands are now
  ignored rather than passed on. Not narrowed further than that on purpose —
  the vocabulary is etcher's, and a whitelist here would silently drop a
  command a later release adds.

- **The optional socket was undocumented where a host would look.** The one
  endpoint line that enables it appeared only in this changelog and the
  module's own docs, which disagreed on what it should say — so on an ordinary
  install the channel silently never engaged and cursors quietly used the
  fallback the feature exists to replace. It is in the README now, together
  with the `board_socket_path` override.

## [0.2.0] — 2026-08-04

First release to reach Hex — 0.1.0 was tagged in the changelog but never
published, so everything below ships alongside it.

### Added

- **Pasted images go to storage, not into the board.** Paste, drop, or pick an
  image and it is uploaded through PhoenixKit's Storage module; the shape keeps
  a URL. Etcher re-emits the *whole* annotation list on every edit, so an
  embedded screenshot was re-sent in full every time anything on the board
  changed — two or three of them pushed routine edits past the socket's frame
  limit, where the socket closes with 1009 and the edit is silently lost.
  Requires the Storage module with at least one bucket enabled; without it
  Etcher falls back to embedding, so a paste is never lost to a failed upload.
- **Pasted URLs become preview cards.** The server fetches the page, reads its
  OpenGraph tags, and draws a card, which goes through the same upload path as
  any other board image. The fetch is guarded: only `http(s)`, a
  private/loopback/link-local/CGNAT/reserved address check on every hop
  including redirects, a 2MB cap enforced as the body streams, and a 12s budget
  for the whole unfurl. No rasterizer needed — cards are emitted as SVG and
  rasterised by the browser. A link that can't be previewed stays as text.
- **Boards open ready to edit** — annotation mode on and the grabber selected,
  so the toolbar is visible and the first drag pans rather than draws.

### Fixed

- **Z-order changes were silently dropped.** Position in the annotation list
  *is* z-order, but the diff keyed purely by uuid, so a pure reshuffle produced
  an empty delta: bringing a caption in front of an image was neither saved nor
  sent to the other viewers. Deltas now carry the full uuid order and the
  client re-imposes it — needed on every delta, not just reorders, because
  applying an edit removes and re-adds shapes and re-adding appends.
- **An unstamped boards table was assumed to be current.** With the
  `COMMENT ON TABLE` version marker missing — a table predating stamping, or a
  dump that dropped comments — `read_version/1` returned a hardcoded `1`.
  `mix phoenix_kit.update` then generated nothing, `create_if_not_exists` made
  a forced re-run a no-op, and the mismatch surfaced only at runtime as
  `column p0.uuid does not exist`, with no upgrade path out. The version is now
  inferred from the table's actual columns, and `up/1` refuses a table matching
  no known version, with recovery instructions.
- **Link previews could reach private addresses through a redirect.** The hero
  image fetch let `Req` follow redirects itself, so the address check ran on
  the first hop only and a `Location` header could point anywhere — including
  at a cloud metadata endpoint, whose response was then inlined into the card.
  Page and hero now share one guarded walk that checks every hop.
- **A failed link preview could take the board down.** The unfurl ran unrescued
  in the LiveView process, so a raise anywhere in fetch/parse/render cost the
  user their board view rather than just the preview.
- **A page body was capped only after being read in full**, so a URL serving
  gigabytes cost gigabytes before it was rejected.
- **Repeated pastes of an image missing from storage returned a dead URL.** The
  upload path short-circuited on a checksum lookup, skipping the check that
  re-stores an object that has gone missing from its bucket.
- **A timed-out upload could hand a later paste the wrong image.** Replies are
  paired with requests by order; dropping a timed-out request from the queue
  let a late reply settle the next one instead.

### Changed

- `fresco` and `etcher` are now pinned `~> 0.10`. `fresco` matches PhoenixKit
  core exactly; `etcher` is deliberately tighter than core's `~> 0.9` because
  `setImageUploader` and `setLinkUnfurler` arrived in 0.10.0, and core's
  constraint would resolve 0.9.0 and leave both features silently degraded.
- New dependencies for link previews: `req`, `floki`, `open_fresco`.
- **Hosts should raise the LiveView socket's `max_frame_size`** — see the
  README. This is headroom for the embed fallback, not the normal path.

## [0.1.0] — 2026-07-22

Initial release.

### Added

- **Boards admin** — a `Boards` sidebar tab; create, open, and delete
  collaborative infinite-canvas boards (`/admin/boards`, `/admin/boards/:id`).
- **Collaboration** — multiple people on one board see each other's shapes,
  text, and images appear live (Etcher annotations synced over PubSub, echo
  suppressed server-side; deltas applied without a canvas remount).
- **Presence + live cursors** — a roster of who's viewing and their cursors,
  in canvas coordinates (so they track each viewer's pan/zoom), over the
  board's PubSub topic.
- **DB persistence** — one row per board in `phoenix_kit_boards`; the
  `Fresco.Canvas` document lives in the `data` jsonb column. Table created by
  the versioned migration coordinator (`mix phoenix_kit.update`).
- **Zero JS setup** — reuses the fresco/etcher engines PhoenixKit core already
  loads; the collaboration hook ships via `js_sources/0`.
