# Claude review — PR #9

Reviewer: Claude (Anthropic) · 2026-11-03
Author: @alexdont · Merge: `ccefd84` · Reviewed at `c75e030` (after GPT's
follow-ups `e3cddbb` and `c75e030`, so this covers what those left).

Overall: the access model is sound. Private stays the creator's, the host hook
fails closed, every panel event re-reads the board, and the folder resolver
cannot fail an upload. GPT's pass already closed the stale-access and stale-struct
holes. Four findings remain, all from the same change: **boards are no longer
admin-only**. Code that was safe when everyone on a board was an admin is not
safe now. All four are fixed.

## BUG - HIGH: every viewer is shown every other viewer's email address

`BoardLive.identity/1` named a peer `user.email || user.username`. It prefers
the email even when a username exists. That name goes into the presence avatar
(`title`), the cursor label, the `board_join`/`board_hello` messages and the
signed channel token. Everyone on the board gets it. Before this PR, everyone on
a board was an admin. Since the `/dashboard/boards/:id` route, anyone the host
lets see a project can open its shared boards, so every member gets every other
member's address.

Core removed exactly this in 2.0 (`d5aa6b11d`, "stop publishing email
addresses") and made `User.display_name/1` the one answer: organisation name or
full name, then username, then the email's local part, never the address.

**Fix:** `identity/1` uses `User.display_name/1` (`"Guest"` with no user).
Test: `board_access_lifecycle_test.exs` "peers are shown a display name, never
the email address" checks both the rendered page and the `board_join` a peer
receives.

## BUG - MEDIUM: an unscoped panel lists the admin-only boards to anyone

`Access.can_open?/3` opens a board with no place for admins only (pinned by
`access_test.exs`). Those are the boards `/admin/boards` lists. The panel
decided whether to show `scope={nil}` with the host's `:view` rule alone, which
with no hook configured is "any signed-in user". So a host page with an
unscoped panel showed every non-admin the names, first 140 characters of text
and first image URL of the admins' shared boards. It also let them pin those
boards, which reorders them for everyone. Each tile then led to
"Board not found.". Nothing about that combination worked for a non-admin.

**Fix:** a new `Access.can_list?/2`: the host's `:view` rule, plus the `boards`
admin permission for `nil`. The panel uses it for listing, for `visible_board/2`
(every per-board event) and for `allow_create/1`. The panel moduledoc and
README say so. Tests: `access_test.exs` "the boards with no place are listed for
admins only, too", and `boards_panel_test.exs` "the boards with no place are not
shown to a user who is not an admin" (listing, a forged `pin`, and creation).

The other choice was to widen `can_open?/3` instead. It was rejected: with no
hook, every signed-in user could then open every admin board by uuid.

## IMPROVEMENT - MEDIUM: the admin list holds every board's canvas in memory

`IndexLive` assigned `Boards.list_boards/0`, which loads the `data` column (the
whole drawing) for every board. Before this PR that meant the handful of admin
boards. Now every quick board from every panel in the host app lands there, and
a single board can run to megabytes (the 5 MB demo board in `BoardLive`'s
comments). GPT added `include_data: false` for the panel but not for this list,
which needs it more.

**Fix:** `list_boards/1` takes `include_data:` (default `true`, so the public
API is unchanged). `IndexLive` passes `false`, and its delete reads metadata
only. Test: `boards_crud_test.exs` "the full list can leave the canvases out".

## BUG - LOW: a second delete of the same board raised inside the host's page

`delete_board/1` re-reads the row under `FOR UPDATE` using `repo().one!`. If a
second person deletes the same board between the panel's `visible_board/2` and
that lock, `Ecto.NoResultsError` propagates out of the transaction and crashes
the LiveComponent, which takes down the host's LiveView with it. (The code
before GPT's lock raised `Ecto.StaleEntryError` in the same window.)

**Fix:** `{:error, :not_found}`, which the panel already reports as "That board
is no longer available." and `IndexLive` treats as a refresh. Test:
`boards_crud_test.exs` "deleting a board somebody else already deleted is an
answer, not a raise".

## Not changed, on record

- **Access is rechecked on every peer edit.** On the user route, `watch_access`
  re-reads the board's metadata for each `board_delta`, so N viewers cost N
  small queries per edit. This is what makes revocation take effect before the
  next edit is shown. A busy board could throttle it, but no one has measured
  it as a problem.
- **A tile's preview image is whatever URL an editor gave it.** Anyone who may
  edit a shared board can point an image shape at a tracking URL, and the panel
  loads it for everyone who sees the tile. The board itself already loads it,
  so the panel adds no new exposure. HEEx escapes the attribute.
- **Pinning is global.** Anyone who can see a board may pin it, and that
  reorders the board for everyone. Documented as intended.
- **A collection that fails partway** has already filed its earlier files in
  the board's folder. That folder is trashed along with the board, and files
  are never deleted, so this is consistent with the module's rules.
- `delete_board/1` still loads the canvas with the locked row. All callers
  ignore it, but `{:ok, board}` is public API, so it is left whole.

## Validation

Covers this review and the [PR #10 review](../10-save-race-paste-widget/CLAUDE_REVIEW.md), which were committed together.

- `postgres-test` was in recovery mode (`57P03`), and a run against it silently
  excludes all 124 integration tests. Instead, the suite ran against a disposable
  PostgreSQL 18.6 (the PGDG server package, extracted into a scratch
  directory, TCP on 127.0.0.1 only) that was removed afterwards: **372 tests, 0
  failures, 0 excluded** (`PGPOOL=8 mix test --max-cases 6`).
- With `lib/` reverted to `c75e030` and the new tests kept, **9 of the new
  tests fail**, one per finding across both reviews, and all pass with the fixes.
- `mix precommit`: compile with warnings as errors, unused-dependency check,
  Hex audit, format check, strict Credo (no issues) and Dialyzer (0 errors,
  0 skips) all pass.

No version, changelog, tag or schema change.
