# Changelog

All notable changes to **PhoenixKitBoards** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
