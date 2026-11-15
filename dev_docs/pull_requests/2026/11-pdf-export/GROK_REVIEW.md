# Post-v0.7.0 — PDF export, overlay, permissions, laser measure

**Reviewer:** Grok · **Range:** `v0.7.0..HEAD` (PRs #11–#14, the core-floor bump, and `e161bf4`)
**Verdict:** fixes applied in this pass; not a release

This is the review of everything after the last Hex tag, `v0.7.0`. Claude's notes for the same range are in this directory's `CLAUDE_REVIEW.md` and in `12-boards-manage-permission`, `13-paste-hint-layout-shift`, and `14-laser-measure`. Those files were not edited. The permission finding is also written up on its own in `12-boards-manage-permission/GROK_REVIEW.md`.

`version/0` and `mix.exs` stay at `0.7.0`. Nothing here is a publish.

## What was already in good shape

Checked against the code, not the commit messages:

- **Core floor.** `phoenix_kit >= 3.6.0 and < 4.0.0` matches a core that allows fresco `~> 0.16.0` and etcher `~> 0.26.0`. Core 3.5.0 pins fresco `~> 0.15` and cannot resolve next to this package. The lock did not need to move. Left as it is.
- **Overlay.** A board that is gone or refused reloads the frame at `Paths.embedded_gone/1` ("Board not found.", no `#board-root`). The embedded page draws its own flash group. `layout: false` still drops the host chrome. A change of place clears `viewing` and `exporting`.
- **Export watchdog, first cut.** `export_done` is ignored unless its `seq` is the export on screen. The hook stops polling once `destroyed` sets `done`.
- **Permissions split.** `boards` is the user key, `boards.manage` is the admin key. The backfill flag is read with `Settings.Queries.get_setting_by_key/1` (a query that raises). `migrate_legacy/0` catches `:exit`.
- **Laser measure.** `BoardLive.tools/0` appends `:measure` only when `config :phoenix_kit, laser_measure: true`. `BoardsPanel.frame_allow/0` adds `bluetooth` only then.
- **Paste hint.** The hint stays in the layout (`invisible` / `visible`) so the first click on an empty widget is not lost.

## Findings

### BUG - MEDIUM — A tile's PDF kept the raw board name (fixed)

Fresco's `exportPdf` uses `opts.filename` as the download name and skips `exportName`, which is the function that appends `.pdf` and replaces `\ / : * ? " < > |`. The board page sets `export_filename` and lets the nav button call `exportPdf()` with no options, so `exportName` runs. The widget passed the board's name through and did not.

A board may be named anything from 1 to 200 characters, so `Q3: plan` downloaded as `Q3: plan` with no `.pdf`.

**Fixed.** `BoardsPanel.pdf_filename/1` and the same function in `boards_panel_export.js` strip one short trailing extension, drop control characters, replace the filesystem characters, trim, drop leading dots, and append `.pdf`. An empty result is `board.pdf`. The status line still shows the real title. The two copies are pinned to the same inputs in `test/pdf_filename_test.exs` and `test/js/panel_export_test.js`.

### BUG - MEDIUM — Taking the export down after the layer was ready still downloaded (fixed)

`destroyed` set `done`, and the wait loop checked it. The two `requestAnimationFrame` callbacks did not. A place change or a watchdog that removed the node after Etcher was ready and before those frames still called `exportPdf` on a detached canvas.

**Fixed.** Both frames return when `done` is set. `exportPdf` is wrapped in `try` and `Promise.resolve`, so a throw is reported once. JS tests destroy the hook with each frame already queued and assert that nothing is called and nothing is sent.

### BUG - MEDIUM — A slow export was reported as a failure while it was still running (fixed)

The hook's 30 second timer was armed at mount and was not cleared when `exportPdf` started. The server's 45 second timer matched any export with that `seq`, including one already drawing. A board of images can outlast both. The server then removed the off-screen canvas and showed "Could not export the board as a PDF." while the browser might still finish the file.

**Fixed.** Two phases. The export starts in `:wait`, and the 45 second watch only ends that phase, so a script that never loads still frees the menu. The hook sends `export_started` when it is about to call `exportPdf`, clears its own 30 second timer, and the server moves that one export to `:running` with a three minute watch. `export_started` is honoured once, and only for the seq on screen, so it cannot extend the watch forever. A late start from an abandoned export does not protect the next one. If `export_started` is lost, the export stays in `:wait` and the 45 second watch still ends it.

### BUG - HIGH — An open admin page kept showing every board after `boards.manage` was taken away (fixed)

Core refreshes the session scope and then calls `view.phoenix_kit_scope_changed/1` before `scope_refresh_decision/4`. That decision evicts a module only when `module_access?/2` fails for `phoenix_kit_current_module_key`. For `PhoenixKitBoards.Web.IndexLive` and `BoardLive` the key is inferred from the namespace as the base key `"boards"` (the admin tab has no `:live_view`, and a `route_module/0` route is not tied to a sub-key). A person who loses `boards.manage` and still holds `boards` gets `:stay`. `:stay` returns the socket unchanged, so a `push_navigate` done inside the callback is what the visitor gets.

`IndexLive` only asked `Access.admin?/1` on mount and on the next event. Until that click it kept rendering every board name, including other people's private boards. `BoardLive` asked again within five seconds. The list had no timer.

**Fixed.** Both pages export `phoenix_kit_scope_changed/1`. The list leaves for the admin home. An open board calls `refresh_access/1`, so an admin board goes home and a user board (including the overlay frame) follows the existing not-found path. The event hook and the five second check stay, for a click or a tick that meets an assign already replaced. Tests: a scope refresh redirects by itself; `{:replace_scope, user}` skips the callback so the event hook and the timer are still reached; a refresh while the key is held stays on the list.

The test host is `AdminHostLive`, not the page. It now makes the same callback call core does. Production is unchanged in that respect: core calls the page because `socket.view` is `IndexLive` or `BoardLive`.

### BUG - MEDIUM — The widget kept offering rename and delete after `boards.manage` was revoked (fixed)

`assign_access/1` already rebuilt the scope on every poll, and clicks already called `admin?/1`. The menu read `@admin?`, which `assign_config/2` set only when the host re-rendered the component. A revoked admin kept seeing manage actions on someone else's board until that happened.

**Fixed.** `assign_access/1` sets `:admin?` from the scope it just built. One read, shared with the list check. The test revokes `boards.manage`, refreshes the panel, and asserts the board is still listed and Rename is gone.

## Left as they are

- **Escape and the overlay.** Escape closes the overlay only while focus is outside the frame. Inside the frame it belongs to Etcher. The close button stays.
- **Tile export stays an off-screen canvas on the host page.** A hidden iframe would be a different design. The bugs above were in the hook and the watch, and those are what changed.
- **Three minutes is a cap.** An export that is still running then is reported as failed and taken down. That is the bound, not a second watch.
- **`boards` without `boards.manage` and `can_access_admin_area?/1`.** That is core's rule for who may enter the admin area. This module does not grant the area.
- **Unscoped `can_list?/3` does not ask the host hook.** Documented. Admins only.
- **Translations.** The new permission strings are en, et, and ru.
- **Upload content type.** Still classified with `Storage.determine_file_type/2`. Not reopened.

## For the next release notes

`CHANGELOG.md` `Unreleased` records the user-visible fixes (safe PDF name, the slow-export watch, leaving when `boards.manage` is taken away). Version and tag stay for the publish step.
