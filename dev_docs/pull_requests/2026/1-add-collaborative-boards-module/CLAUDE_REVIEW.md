# PR #1 Review — Add collaborative boards module (0.1.0)

**Reviewer:** Claude | **Date:** 2026-07-23 | **Verdict:** Approve, with one
fix applied now (a truthiness bug that silently swallows delete failures) and
a cluster of schema/migration findings **intentionally deferred** — this is
the module's first PR, the primary-key convention it deviates from touches
already-shipped migration DDL, and that deserves its own session rather than
a same-night patch. No release was cut for this review; see "Deferred to a
follow-up session" below before publishing to Hex.

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

## Deferred to a follow-up session (migrations — do not act on these without discussing first)

These four are related and all touch the schema/migration layer, which per
the PR author's note we're revisiting in a dedicated session rather than
patching tonight. Do not `mix phoenix_kit.update`/publish against a
production install with the current migration until these are resolved —
findings #1 and #2 are the ones that actually change behavior; #3 and #4 are
paperwork that should land in the same pass.

### `BUG - HIGH` — `Board` schema is missing `use PhoenixKit.SchemaPrefix`

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

### `IMPROVEMENT - MEDIUM` — `Board`'s primary key is the Ecto default integer `id`, not the umbrella's UUIDv7 convention

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
this ecosystem." Practically: board ids are now small sequential integers
exposed directly in the URL (`/admin/boards/1`, `/admin/boards/2`, …) —
trivially enumerable. Low severity on its own (the whole `/admin` tree is
already permission-gated), but it's the kind of inconsistency that bites
later if boards ever get referenced from another module expecting a UUID.
`phoenix_kit_sync/lib/phoenix_kit_sync/migration.ex:69-71` is a same-shaped
standalone (non-core-chain) coordinator that does this correctly and is the
right template for the fix:

```elixir
create_if_not_exists table(@connections_table, primary_key: false, prefix: prefix) do
  add(:uuid, :uuid, primary_key: true, null: false, default: fragment("uuid_generate_v7()"))
  ...
```

**Why this is deferred rather than fixed now:** changing the primary-key
strategy means rewriting `migrations.ex`'s `up_v1`/`down_v1` and bumping the
coordinator to a v2 (or rewriting v1, if we're confident nobody has run
`mix phoenix_kit.update` against this table yet — worth confirming before
touching it). That's exactly the kind of change that deserves the dedicated
migrations conversation rather than a same-night patch on top of an
already-merged first PR.

### `NITPICK` — no `test/schema_prefix_conformance_test.exs`

Both `phoenix_kit_hello_world` and `phoenix_kit_locations` ship this test —
it scans `lib/` and fails the build if a table-backed schema is missing
`use PhoenixKit.SchemaPrefix`. Copy it over alongside the schema-prefix fix;
it would have caught finding #1 in CI instead of code review.

### `NITPICK` — `timestamps(type: :utc_datetime_usec)` vs. the template's `:utc_datetime`

The module template documents `timestamps(type: :utc_datetime)` as the
workspace standard (core migration V58 standardized on non-`usec`
timestamptz columns). In practice every other *standalone* migration
coordinator that isn't on core's versioned chain (`phoenix_kit_sync`, and
now this one) also uses `:utc_datetime_usec`, so this may be the template
doc lagging reality rather than boards being wrong — flagging for the same
migrations conversation rather than guessing which side to fix.

---

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
