# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## Project Overview

PhoenixKitBoards — a PhoenixKit plugin module providing collaborative
infinite-canvas **boards**. An admin creates a board from the sidebar and opens
it: an infinite [Fresco](https://hex.pm/packages/fresco) canvas with the
[Etcher](https://hex.pm/packages/etcher) drawing layer (shapes, text, images).
Everyone on the same board sees each other's edits, cursors, and presence in
real time. One board = one row in `phoenix_kit_boards`, its `Fresco.Canvas`
document serialized into the `data` jsonb column. No files, no external storage.

Implements the `PhoenixKit.Module` behaviour for auto-discovery — the host app
adds the dep and enables the module; the sidebar tab, routes, permission, CSS,
and JS all wire up with no host configuration.

## Common Commands

```bash
mix deps.get                # Install dependencies
mix test                    # Run all tests (no database required)
mix test test/phoenix_kit_boards_test.exs
mix format                  # Format code
mix credo --strict          # Lint / code quality
mix dialyzer                # Static type checking
mix precommit               # compile --warnings-as-errors + deps.unlock check + hex.audit + quality.ci
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Dependencies

This is a **library** (not a standalone Phoenix app) — no `config/`, endpoint,
or router of its own.

- `phoenix_kit` (`~> 1.7`) — Module behaviour, Settings, RepoHelper, Dashboard tabs, `Utils.Routes`, `SchemaPrefix`
- `phoenix_live_view` (`~> 1.1`) — the two admin LiveViews
- `fresco` (`~> 0.6`) — the infinite-canvas engine and `Fresco.Canvas` document
- `etcher` (`~> 0.7`) — the annotation/drawing layer over the canvas
- `lazy_html` (test only)

Constraints on `fresco`/`etcher` deliberately match PhoenixKit core so the
host's resolution is never in conflict — core already depends on both for its
media annotation feature. **That is also why this module needs no host JS
setup:** core already loads `fresco.js` and `etcher.js`, so `<Fresco.canvas>`
and `<Etcher.layer>` work here out of the box.

## Local cross-repo development

`phoenix_kit`, `fresco`, and `etcher` resolve from Hex by default. Export
`<APP>_PATH` to swap any of them for a local `path:` + `override: true` dep at
resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit FRESCO_PATH=../fresco mix test
```

Unset = the published pin, so `mix hex.publish` and CI are unaffected.
Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a path dep in.

## Architecture

### Key modules

- **`PhoenixKitBoards`** (`lib/phoenix_kit_boards.ex`) — the `PhoenixKit.Module`
  facade: module key/name, enable/disable, permission metadata, admin tab,
  `route_module/0`, `migration_module/0`, `css_sources/0`, `js_sources/0`.
- **`PhoenixKitBoards.Boards`** (`boards.ex`) — the context. Board CRUD against
  the host repo via `PhoenixKit.RepoHelper.repo()`, canvas load/save into the
  `data` column, and the annotation-list helpers the collaboration layer uses.
- **`PhoenixKitBoards.Board`** (`board.ex`) — the Ecto schema.
- **`PhoenixKitBoards.Migrations`** (`migrations.ex`) — versioned migration
  coordinator; see "Versioned migrations" below.
- **`PhoenixKitBoards.Routes`** (`routes.ex`) — route macros returned from
  `route_module/0`; PhoenixKit injects them inside the admin `live_session`.
- **`PhoenixKitBoards.Paths`** (`paths.ex`) — every link/redirect, via
  `PhoenixKit.Utils.Routes.path/1`.
- **`Web.IndexLive`** — the list page: create, open, delete.
- **`Web.BoardLive`** — a single board: canvas, collaboration, presence, cursors.

### Routes

| Path | LiveView | Action |
|------|----------|--------|
| `/admin/boards` | `Web.IndexLive` | `:index` |
| `/admin/boards/:id` | `Web.BoardLive` | `:show` |

Both a localized (`/:locale/admin/...`) and a non-localized set are defined, as
PhoenixKit requires. **Each route needs a unique `:as`** — hence the
`_localized` suffixes in `routes.ex`. The admin tab carries no `:live_view`
because this is a multi-page module (routes come from `route_module/0`); the
tab is the sidebar entry and active-state anchor only, matched by `:prefix`.

### Database table

**`phoenix_kit_boards`** — one row per board.

- `uuid` (UUIDv7 primary key), `name` (string, required, 1–200 chars)
- `data` (jsonb, not null) — the serialized `Fresco.Canvas` document, including
  `extensions.etcher` with the annotation list
- `created_by` (binary_id, optional)
- `inserted_at` / `updated_at` (`:utc_datetime_usec`)

This is the only table.

### Collaboration protocol

All real-time traffic for a board rides one PubSub topic:
`"phoenix_kit_boards:<board_uuid>"`. Messages, all tagged with the sender's
`self()` so senders can ignore their own:

| Message | Meaning |
|---------|---------|
| `{:board_annotations, list, from}` | The full etcher annotation list changed |
| `{:board_join, peer, from}` | A newcomer arrived |
| `{:board_hello, peer, from}` | Reply to a join, so the newcomer learns about existing viewers |
| `{:board_leave, peer_id}` | A viewer disconnected (sent from `terminate/2`) |
| `{:board_cursor, id, x, y, from}` | A pointer moved, in **canvas** coordinates |

**Echo suppression is server-side**, via `when from == self()` guards on each
`handle_info/2` clause. Editing re-emits the *entire* annotation list
(`etcher:annotations-changed`); the LiveView diffs it, persists, and broadcasts,
and peers apply the delta without remounting the canvas — an unchanged list
diffs to empty, so no work happens.

Cursors are sent in canvas coordinates rather than screen pixels so they track
each viewer's own pan and zoom.

### Client-side assets

`priv/static/assets/phoenix_kit_boards.js` — the collaboration + cursor hook
bundle, declared through `js_sources/0` with global `PhoenixKitBoardsHooks`.
Core's `:phoenix_kit_js_sources` compiler concatenates it into the host's
`phoenix_kit_modules.js` (loaded before `app.js`) and folds the global into
`window.PhoenixKitHooks`. The host does nothing.

### Versioned migrations

`PhoenixKitBoards.Migrations` is the coordinator `mix phoenix_kit.update`
discovers. It compares `migrated_version_runtime/1` (installed) against
`current_version/0` (what the code needs) and, when behind, generates a host
migration calling `up/1`. The host never hand-writes a migration, and the
host's `--prefix` (named-schema installs) is honoured.

The installed version is tracked with a **`COMMENT ON TABLE`** on
`phoenix_kit_boards` itself — mirroring core's `PhoenixKit.Migrations.Postgres`
— not merely "does the table exist", so a future V2 can distinguish "not
installed" from "installed at V1".

- `0` — table absent
- `1` — table present, UUIDv7 primary key

Adding a version means: bump `@current_version`, add `up_vN/1` + `down_vN/1`,
and extend the `change/3` dispatch.

## Critical Conventions

- **Module key** is `"boards"`, consistent across every callback.
- **One setting**: `boards_enabled` (boolean, default `false`). `enabled?/0`
  must rescue *and* catch `:exit` and fall back to `false` — it runs before the
  DB may be available, and a sandbox shutdown mid-test raises an exit that
  `rescue` alone will not catch.
- **Navigation** always goes through `PhoenixKitBoards.Paths`, never a
  hardcoded path — the host's URL prefix and locale are applied by
  `PhoenixKit.Utils.Routes.path/1`.
- **Every table-backed schema must `use PhoenixKit.SchemaPrefix`.** Without it,
  queries silently fall back to `search_path` resolution — invisible on public
  installs, broken on prefixed ones. Pinned by
  `test/schema_prefix_conformance_test.exs`.
- **`version/0` in `lib/phoenix_kit_boards.ex` is a hardcoded string**, separate
  from `@version` in `mix.exs`. A release must update **both** — see the release
  checklist below.
- **Repo access** is always `PhoenixKit.RepoHelper.repo()`; this module owns no
  repo of its own.
- `Web.BoardLive.mount/3` fetches the board on *both* the HTTP and the WebSocket
  mount (LiveView mounts twice); only the PubSub subscribe and join broadcast
  are guarded by `connected?/1`. Moving the fetch to `handle_params/3` would
  halve that query count if you are already working in this area.

## Testing

No database is required — `test_helper.exs` is a bare `ExUnit.start()`, and the
suite covers module metadata, `js_sources/0`, and schema-prefix conformance.
Anything exercising `Boards` CRUD needs a host repo and does not run here.

## Versioning & Releases

This module has not been released yet — there are no tags and it is not on Hex.

### Tagging

Tags use a **`v` prefix**, matching `phoenix_kit` core and the rest of the
umbrella:

```bash
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin v0.1.0
```

This must stay in step with `docs.source_ref` in `mix.exs`, which is
`"v#{@version}"`. ExDoc bakes that ref into every "Source" link in the
generated HTML, so a bare tag (`0.1.0`) against a `v`-prefixed ref points at a
tag that does not exist and 404s every source link on HexDocs — for that
release, permanently, since fixing `mix.exs` afterwards only affects subsequent
releases. Ten sibling modules had exactly this defect (2026-07-25).

### Release order

Publish to Hex **before** tagging — never tag a release that failed to publish.

1. Update `@version` in `mix.exs` **and** `version/0` in `lib/phoenix_kit_boards.ex`
2. Add a `CHANGELOG.md` entry
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit and push, and verify the push succeeded
5. `mix hex.publish --yes`
6. `git tag -a v<x.y.z> -m "Release <x.y.z>" && git push origin v<x.y.z>`

## Commit Messages

Start with an action verb: `Add`, `Update`, `Fix`, `Remove`, `Merge`.
