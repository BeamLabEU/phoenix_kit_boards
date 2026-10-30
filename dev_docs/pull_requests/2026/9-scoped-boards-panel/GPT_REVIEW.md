# GPT review — PR #9

Reviewer: Codex (OpenAI) · 2026-10-30  
Author: @alexdont · Merge: `ccefd84` · Baseline: `4187308` on main.

## BUG — HIGH: cached panel access survives revocation

The panel only asked the host's authorize hook when the user UUID or normalized
scope changed. Polls and refreshes reused that answer, as did mutations. A user
removed from a place could continue reading, creating, pinning, renaming or
deleting its boards. An invalid scope replacing a valid unscoped widget also
normalized to nil and incorrectly retained the former access decision.

Fixed by retaining scope validity explicitly, rechecking host access on each
list refresh and mutation, and checking current admin authority for management.
Creation requires both view and create access. Tests revoke permission on a
mounted widget before any refresh, exercise forged mutations, refresh its list,
and replace an unscoped widget with a malformed place.

## BUG — HIGH: open editors and channels survive a privacy change

BoardLive checked Access only at mount. A shared board made private remained
readable and editable through an already open page. Deleting a board likewise
left viewers attached to its topic. The independent ephemeral token lasted
24 hours regardless of page access.

Visibility changes and deletion now announce access invalidation on the board
topic. Existing viewers reload access, unsubscribe and redirect when refused.
User-route durable events, token requests, received annotations and deferred
image storage check current access. A five-second timer checks idle pages for
host permission changes without querying for every cursor frame. Access reads
omit the canvas blob. Signed channel tokens are bound to the page process;
the channel monitors it and closes when it ends. Remounts replace the old
connection, retaining the existing LiveView fallback.

Mounted-editor integration tests cover privacy changes, the creator staying
connected, denied edits, denied peer annotations, idle rechecks and deletion.
Channel and executable JS tests cover page termination and token replacement.
Host access revocation on an otherwise idle ephemeral connection is detected
within the polling interval; it is not claimed to be instantaneous. Existing
page tokens from before this change must be replaced by a page reload/remount.

## BUG — HIGH: a private-only replacement can still create shared boards

The selected visibility was initialized once and retained when the host changed
visibility_options. Switching an existing widget to private-only could thus
create a shared board while showing no visibility selector. Draft text and
upload entries also survived a change of place/user.

Fixed by constraining the selection to the current options and resetting draft,
rename, expanded-list and upload state when the user/place/validity changes.
Tests exercise private-only updates and moving a widget with an unsaved draft.

## BUG — MEDIUM: stale structs miss folder cleanup and rename

Uploads persist folder_uuid independently, leaving the editor's or quick
capture's Board struct stale. Deleting that struct trashed no folder, and
renaming it skipped the folder. Existing tests reloaded the row first and
therefore missed the production path.

Deletion now reads the persisted row under a row lock before deleting, then
trashes the returned folder. Rename resolves the persisted folder pointer.
Regression tests intentionally retain the stale pre-upload struct.

## BUG — MEDIUM: folder failures violate the documented fallback

A folder function returning a missing UUID silently selected the media root,
and a failing host hook did the same. A thrown folder function escaped the
best-effort resolver and prevented board creation.

Functions and hooks now distinguish an explicit root from an unusable folder.
Failures fall back to the default Boards/place layout, with safe failure logs.
Throws are caught alongside exits and exceptions. Tests cover each case. The
parent_hook/4 API was checked in the pinned core floor, v2.64.1.

## BUG — MEDIUM: fresh databases silently lose integration coverage

Setup deleted a schema_migrations row before that table existed. A broad rescue
then reported a connected, empty database as unavailable and excluded all
integration tests. That rescue also hid migration and endpoint failures.

Only the connection probe now permits exclusion; schema/cache/endpoint setup
failures fail the run. Cleanup checks for schema_migrations before using it.
A fresh disposable database successfully ran the four migration tests. Replacing
its boards table with an incompatible schema caused a nonzero setup failure
instead of a passing run with excluded integration tests. The scratch database
was removed afterwards.

## IMPROVEMENT — MEDIUM: polling needlessly loads complete canvas documents

The preview column kept the UI small, but the panel query still selected data,
loading every listed canvas on every poll. Added an optional include_data:
false projection for lists and single-board metadata reads, preserving the
existing default API behavior. The panel and access checks use it. A regression
test verifies previews remain available and default calls retain full documents.
Removed the dead daisyUI 4 input-bordered class from the rename field.

## Related security fix

The new ordinary-user board route invalidated the old admin-only rationale for
leaving link-preview DNS rebinding open. The common page/hero request now pins
the validated IP while preserving HTTP/TLS hostnames. See PR #2's GPT review
for the finding and transport tests.

## Validation

- Baseline with database setup repaired: 277 tests, zero failures, no exclusions.
- Final PostgreSQL suite: 296 tests, zero failures, no exclusions
  (`PGPOOL=8 mix test --max-cases 6`).
- Regression verification: running the panel/folder/editor/channel regression
  suite against the original source produced 18 failures out of 92 tests; the
  fixed full suite passes.
- `mix precommit`: compile with warnings as errors, unused dependency check,
  Hex audit, formatting, strict Credo and Dialyzer all pass.
- Disposable fresh database: four migration tests passed; an incompatible
  boards schema exited nonzero during setup, with no integration exclusion.
- HTTPS smoke fetch: the checked-IP request to https://example.com succeeded
  with certificate verification enabled, returning HTML and the original URL.

No package version, changelog, release tag or schema version change is part of
this review.

Automated checks use PostgreSQL, isolated LiveViews, Node execution of the shipped
bundle and a real local HTTP socket. They do not replace a real-browser or
multi-node deployment test. The existing five-second annotation omission grace
is unchanged; revision-based concurrent-edit resolution is outside this patch.
