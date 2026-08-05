# Changelog

All notable changes to **PhoenixKitBoards** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Audio on a board, played together.** Drop or paste an audio file and it
  becomes a player card (etcher 0.11). Whoever presses play, pauses, or
  scrubs drives it for everyone in the room — a teacher and their students
  hear the same moment of a recording.

  Anyone may control it: commands are relayed verbatim over the board's
  existing PubSub topic and the last one to arrive wins. There is no
  ownership check and no conflict resolution, because for a shared listening
  session there is nothing to resolve — the useful behaviour is that the
  transport does what the last person to touch it said.

  Uploads now accept audio alongside images, with the size cap raised to 64MB
  (a lesson recording is routinely tens of MB where a pasted screenshot is
  under one). This is the LiveView upload channel, which chunks — not the
  socket's frame limit.

### Known limitation

- A peer who joins **while audio is already playing** stays silent until the
  next play/pause/seek, because state is relayed as commands rather than
  broadcast periodically. Joining before playback starts, which is the usual
  case for a lesson, works.

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
