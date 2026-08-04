# Changelog

All notable changes to **PhoenixKitBoards** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

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
