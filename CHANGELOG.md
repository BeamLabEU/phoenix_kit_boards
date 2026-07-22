# Changelog

All notable changes to **PhoenixKitBoards** are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/).

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
