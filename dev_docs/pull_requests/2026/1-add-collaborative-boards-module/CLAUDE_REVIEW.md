# PR #1 Review — Add collaborative boards module (0.1.0)

**Reviewer:** Claude | **Date:** 2026-07-23, follow-up 2026-07-24 | **Verdict:**
Approve. The delete-handler truthiness bug was fixed same-night; the
schema/migration cluster (missing `use PhoenixKit.SchemaPrefix`, integer `id`
instead of the umbrella's UUIDv7 primary-key convention, missing conformance
test) was deferred for a dedicated migrations discussion and has now been
resolved in the follow-up session below. No release has been cut yet — the
package is still unpublished (0.1.0 never reached Hex), which is exactly why
it was safe to rewrite the V1 migration DDL in place rather than shipping a
V2: there is no installed host to carry forward.

## Scope of what we reviewed

The full diff (9 new `lib/` files, migrations, routes, both LiveViews, the
JS hook bundle, mix.exs). Cross-checked against sibling PhoenixKit modules —
`phoenix_kit_calendar` (mount/handle_params discipline), `phoenix_kit_locations`
and `phoenix_kit_hello_world` (the canonical module template, including its
`schemas/example_item.ex` reference file — the load-bearing conventions for
new table-backed schemas live there), and `phoenix_kit_sync` (a comparable
standalone migration coordinator with a UUIDv7 primary key, for the DDL shape
a fix would need).

---

## What we fixed ourselves

### `BUG - MEDIUM` — deleting a board always "succeeds", even when the delete fails *(fixed)*

```elixir
def handle_event("delete", %{"id" => id}, socket) do
  case Boards.get_board(id) do
    nil -> {:noreply, socket}
    board -> Boards.delete_board(board) && {:noreply, load_boards(socket)}
  end
end
```

`Boards.delete_board/1` returns `{:ok, board}` or `{:error, changeset}`.
In Elixir only `nil` and `false` are falsy — `{:error, changeset}` is
truthy, so `&&` always takes the right-hand side. A failed delete (FK
constraint, stale row, whatever) silently re-renders the list with no error
shown, and the board that "failed" to delete is still sitting right there
with no explanation. Likely a JS-truthiness habit (`x && y` reads as "if x,
then y" in JS, where `{error: ...}` isn't special) leaking into Elixir,
where only `nil`/`false` short-circuit.

**Fix:** replaced with an explicit `case` on `{:ok, _}` / `{:error, _}`,
flashing an error on failure — matching `create_board`'s handler two lines
above it, which already does this correctly.

---

## Follow-up session (2026-07-24) — migrations cluster resolved

Before touching anything, we mapped how per-module migrations actually work
in this umbrella, since the open question was whether decentralizing
migrations out of `phoenix_kit` core was even a supported path. Short
version: **it already is** — `migration_module/0` (a `PhoenixKit.Module`
callback, shipped in core `v1.7.63`) is discovered by `mix phoenix_kit.update`
(`PhoenixKit.ModuleDiscovery.discover_external_modules/0` →
`phoenix_kit.update.ex`'s `discover_module_migrations/0` /
`run_module_migrations/1`), which diffs `migrated_version_runtime/1` against
`current_version/0` per module and generates+runs a separate host migration
file per module — completely independent of core's own V01–V157 chain.
Three modules use it in production today (`phoenix_kit_boards`,
`phoenix_kit_legal`, `phoenix_kit_stats`); `phoenix_kit_hello_world`'s
README ("Versioned migrations" section) is the authoritative how-to,
including a `COMMENT ON TABLE`-based version-tracking scheme that scales
past V1 (matching how core tracks its own version) and a template for a
`mix <module>.install` task for first-time setup. None of the three real
modules fully followed that template — each hand-rolled a boolean
"does the table exist" check instead of real version tracking, and boards
additionally skipped the schema-prefix line and the UUIDv7 primary key.
Per the decision to keep this session scoped to boards, the fixes below
bring *this module* in line with the documented template; core itself,
`phoenix_kit_legal`, and `phoenix_kit_stats` were left untouched.

### `BUG - HIGH` — `Board` schema is missing `use PhoenixKit.SchemaPrefix` *(fixed)*

Every table-backed schema in this ecosystem must `use PhoenixKit.SchemaPrefix`
immediately after `use Ecto.Schema` — it sets `@schema_prefix` from
`config :phoenix_kit, :prefix` at compile time
(`phoenix_kit/lib/phoenix_kit/schema_prefix.ex`), so queries target the
Postgres schema the host installed into via
`mix phoenix_kit.install --prefix "..."`. `PhoenixKitBoards.Migrations.up/1`
already threads `prefix` through correctly (`create_if_not_exists
table(:phoenix_kit_boards, prefix: prefix)`) — the table lands in the right
place. But `Board` has no `@schema_prefix`, so every query the context
issues (`list_boards`, `get_board`, `create_board`, …) resolves the table via
the connection's `search_path` instead. On a default (`public`-schema)
install this is invisible — which is almost certainly why the standalone
`mix test` + manual verification the author describes didn't catch it. On
any `--prefix`-installed host it either raises `undefined table` or, worse,
silently reads/writes a same-named table in the wrong schema if one exists.
`phoenix_kit_locations/lib/phoenix_kit_locations/schemas/location.ex` and
every other sibling schema (123 files across the umbrella) carry this line;
the umbrella's own module template
(`phoenix_kit_hello_world/lib/phoenix_kit_hello_world/schemas/example_item.ex`)
calls it out explicitly as convention #1, "load-bearing... each one exists
because a real module got it wrong once."

**Fix:** added `use PhoenixKit.SchemaPrefix` to `board.ex`, right after
`use Ecto.Schema`.

### `IMPROVEMENT - MEDIUM` — `Board`'s primary key is the Ecto default integer `id`, not the umbrella's UUIDv7 convention *(fixed)*

```elixir
schema "phoenix_kit_boards" do
  field(:name, :string)
  ...
```

No `@primary_key {:uuid, UUIDv7, autogenerate: true}` / `@foreign_key_type
UUIDv7`, and the migration doesn't declare a `:uuid` primary-key column
either — so `phoenix_kit_boards` gets Ecto's default auto-increment `id`.
Every other schema in the umbrella (123 files) uses the UUIDv7 convention;
the module template calls integer ids "the deprecated legacy convention in
this ecosystem." Practically: board ids were small sequential integers
exposed directly in the URL (`/admin/boards/1`, `/admin/boards/2`, …) —
trivially enumerable. Low severity on its own (the whole `/admin` tree is
already permission-gated), but it's the kind of inconsistency that bites
later if boards ever get referenced from another module expecting a UUID.

**Fix:** `board.ex` now declares `@primary_key {:uuid, UUIDv7, autogenerate:
true}` / `@foreign_key_type UUIDv7`. `migrations.ex`'s `up_v1` creates the
table with `primary_key: false` and an explicit
`add(:uuid, :uuid, primary_key: true, null: false, default: fragment(...))`,
where the default expression is
`PhoenixKit.Migrations.Postgres.Helpers.uuid_v7_call(prefix)` — the same
schema-qualified-`uuid_generate_v7()` helper core's own V-chain uses, reused
rather than reinvented (the naive `fragment("uuid_generate_v7()")` that
`phoenix_kit_sync` and `phoenix_kit_boards`'s pre-fix draft both would have
used resolves via `search_path` and has the exact same `--prefix` blind spot
as finding #1 above — worth a follow-up note to `phoenix_kit_sync` and any
future modules copying that snippet). Every `board.id` call site
(`board_live.ex`'s `topic/1`, `index_live.ex`'s `Paths.board/1` and
`phx-value-id`) was updated to `board.uuid`. This was safe to do as a V1
rewrite rather than a new V2 step — the package has never been published to
Hex, so no host has run this migration against a real database yet.

### `NITPICK` — no `test/schema_prefix_conformance_test.exs` *(fixed)*

Both `phoenix_kit_hello_world` and `phoenix_kit_locations` ship this test —
it scans `lib/` and fails the build if a table-backed schema is missing
`use PhoenixKit.SchemaPrefix`. Copied it over verbatim
(`test/schema_prefix_conformance_test.exs`) — it now passes because of the
fix above, and will catch any future schema that forgets the line.

### `NITPICK` — `timestamps(type: :utc_datetime_usec)` vs. the template's `:utc_datetime`

The module template documents `timestamps(type: :utc_datetime)` as the
workspace standard (core migration V58 standardized on non-`usec`
timestamptz columns). In practice every other *standalone* migration
coordinator that isn't on core's versioned chain (`phoenix_kit_sync`, and
this one) also uses `:utc_datetime_usec`. Left as-is — this reads as the
template doc lagging reality rather than boards being wrong, and it's a
column-type choice, not a correctness bug; not worth guessing at without
the module template's maintainer weighing in on which side to update.

### `IMPROVEMENT (bonus, beyond the original findings)` — version tracking was a boolean, not a real version *(fixed)*

`migrated_version_runtime/1` used to collapse to `if table_exists?(prefix),
do: 1, else: 0` — it can tell "not installed" from "installed," but nothing
else, so a future V2 would have had no way to distinguish "needs the V2
step" from "already has it." **Fix:** rewrote `migrations.ex` to track the
version via `COMMENT ON TABLE phoenix_kit_boards IS '<version>'`, mirroring
core's own `PhoenixKit.Migrations.Postgres` and the scheme documented (but,
per the research above, not actually used by any of the three real
production modules) in `phoenix_kit_hello_world`'s README. `up/1`/`down/1`
now dispatch over a version range via a small `change/3` helper instead of
a single bare `if`, so adding a V2 later is "add `up_v2`/`down_v2` and a
`change` clause," not "restructure the whole coordinator."

## Recommendations we did *not* apply (flagged for follow-up, non-migration)

### `IMPROVEMENT - LOW` — both LiveViews query the database from `mount/3` instead of `handle_params/3`

```elixir
# board_live.ex
def mount(%{"id" => id}, _session, socket) do
  case Boards.get_board(id) do
    ...

# index_live.ex
def mount(_params, _session, socket) do
  {:ok, socket |> assign(:page_title, "Boards") |> load_boards()}
end
```

`phoenix_kit_calendar/web/calendar_live.ex` — the closest sibling with
real data loading — keeps `mount/3` to socket setup/subscriptions only and
does all querying in `handle_params/3`. To be precise about *why* this
matters here: it does **not** reduce the query count for a fresh page load
(`handle_params/3` runs once per mount cycle too, so both fire twice —
disconnected render, then the connected remount — regardless of which
callback holds the query). The real risk is params-driven staleness: if
`BoardLive` ever gains in-place navigation between boards via `push_patch`
(e.g. a "next board" control) instead of `push_navigate`, a mount-held query
would keep showing the *previous* board's data because `mount/3` doesn't
re-run on patch, only `handle_params/3` does. Currently harmless (only
`push_navigate`/full remounts are used), but worth aligning with the
established convention before that changes. Left unapplied tonight to keep
the diff to the one confirmed bug plus documentation — happy to do this
alongside the migrations follow-up.

### `IMPROVEMENT - LOW` — presence roster cleanup depends entirely on `terminate/2` firing

`BoardLive.terminate/2` is what broadcasts `{:board_leave, ...}` to remove a
departed viewer from every other client's roster. This fires reliably on a
normal disconnect (tab close, navigation away — the websocket closes
normally, which is a `:normal`/`:shutdown` exit and doesn't need
`trap_exit`). It will **not** fire on an abrupt process kill (node
restart, OOM, a supervisor `:brutal_kill`, or certain crash paths) — those
peers stick around in the avatar row indefinitely, with no equivalent of the
8s sweep that already exists for stale cursors (`sweep()` in the JS hook).
Low-severity (self-heals on next real join/hello round-trip since the
roster only grows from broadcast responses, and a page refresh clears it for
that viewer), but worth a heartbeat-based prune matching the cursor sweep if
this sees real usage. Not fixing now — needs a small design decision
(piggyback on the existing cursor heartbeat vs. a separate timer) rather
than a mechanical patch.

### `IMPROVEMENT - MEDIUM` — no context/LiveView/integration test coverage

`test/phoenix_kit_boards_test.exs` only asserts module metadata (2 tests).
Compare to `phoenix_kit_hello_world`'s test suite (851 lines: schema/
changeset unit tests that always run, plus DB-backed LiveView integration
tests gated behind a `:integration` tag and an auto-detected test database)
or `phoenix_kit_locations`'s. `Boards` (CRUD, canvas load/save, annotation
diffing) and both LiveViews currently have zero coverage. Setting up the
same two-tier harness (`test/support/{test_repo,test_endpoint,test_router,
data_case,live_case}.ex` + the `:integration` exclusion pattern) is a
non-trivial one-time cost — reasonable to bundle with the migrations
follow-up since a real test DB is also what's needed to actually verify the
schema-prefix/primary-key fix works end-to-end.

---

## What's good (worth highlighting)

1. **Zero-config JS integration** — `js_sources/0` + core's compiler means
   the collab hooks (`BoardSync`, `BoardCursors`) load with no host setup,
   and reuse the fresco/etcher engines the host already loads.
2. **Diff-based sync avoids full-canvas rebroadcasts** — re-emitting the
   full annotation list client-side but diffing server-side (by `uuid`)
   before persisting/broadcasting keeps the wire payload to just the delta,
   and the "unchanged list diffs to empty" trick cleanly breaks echo without
   needing to track "is this my own broadcast" state beyond the existing
   `from == self()` guards.
3. **Cursor coordinates travel in canvas space**, not screen space — each
   viewer maps them through their own pan/zoom via `screenToImage`/
   `imageToScreen`, so cursor rendering is correct regardless of who's
   zoomed/panned where.
4. **`create_board`/`rename_board` already handle `{:error, _}` correctly**
   — the delete-handler bug we fixed was the outlier, not the pattern.
