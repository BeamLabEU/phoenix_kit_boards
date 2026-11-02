# GPT review — PR #10

Reviewer: Codex (OpenAI) · 2026-11-02  
Author: @alexdont · Merge: `2cd48d8` · Reviewed baseline: `e441a7d` on main.

## BUG — HIGH: delayed deltas regress editors after newer writes

The row lock orders database writes, but messages sent by different LiveViews
after commit can arrive in the opposite order. Applying an older update after
a newer one rolls the viewer back; receiving a late create after its delete
resurrects the shape locally. An editor that caught up during its own save can
also receive the already incorporated peer message afterwards.

Each locked edit now persists an opaque revision in `extensions.boards_sync`
and returns the effective stored delta with base/new revision tokens. Peers
apply consecutive revisions directly, ignore exact duplicates, and reload the
committed row on a gap or an older sender's tokenless message. The normal path
retains small deltas without another full-document query. Sender catch-up is
computed against the submitted list, including edits that the merge declined
because another editor had deleted the shape. No schema migration is needed.

Mounted-editor tests deliver updates in reverse order and deliver a create
after its delete. A unit test exercises the consecutive/duplicate paths
without a board assign or database. Context tests verify revision persistence
and chaining from the locked row even when the caller's Board struct is stale.

## BUG — MEDIUM: ordinary stale edits undo saved z-order

`apply_delta/2` imposed the sender's full order even when it had only changed
a shape's content. That silently reversed a peer's reorder, including when
adding a new shape. The returned delta also described the original intent,
rather than the order and changes that actually landed in storage.

Survivors now keep their stored order unless the delta explicitly reordered
them. New shapes are inserted before their next known neighbour, or appended
when none follows. Explicit reorders still preserve the slots of unknown peer
shapes. Returned deltas come from the locked stored/merged lists and carry the
authoritative order. Unit and database regressions cover both stale content
edits and insertion around reordered survivors.

## BUG — MEDIUM: preview changes can miss their scope announcement

The save compared the new preview with the caller's stale Board struct. If a
peer changed the preview and this edit returned it to that stale value, no
announcement was sent even though the persisted preview changed.

The comparison now uses the locked row. A regression changes the shape count
away from and back to a stale caller's value and checks the scope message.

## BUG — HIGH: pending clipboard content crosses widget contexts

Changing the widget's user or place cleared its old note draft and uploads,
but retained `paste_text` and its creation notice. A later picture selected in
the new context received text pasted in the old one.

Context resets now clear both assigns. The paste hook also discards queued
images when its context changes. Integration coverage switches places with
pending text, then uploads a picture and checks that only the picture lands.
The JS coverage verifies that queued clipboard data is discarded on a context
change as well.

## BUG — MEDIUM: overlapping pastes share a batch and overwrite captions

Every image paste immediately reused the same LiveView upload and single
`paste_text` assign. Pasting again before the first batch completed could
combine separate pastes into one board with only the last caption, or exceed
the eight-entry limit.

The hook now queues image pastes until the current upload's active references
clear. It waits through the initial context-only patch and also waits behind a
picker/drop upload. Each paste therefore gets its own collection and caption.
Node tests cover immediate successive pastes, upload completion, waiting behind
a picker upload and context replacement. Text-only pastes remain independent.

## BUG — MEDIUM: image cancellation leaks text or strands completed files

Canceling the last image left its caption for an unrelated later upload.
Canceling an unfinished member of a batch after its siblings finished never
created their board: no further progress callback was coming. LiveView may
retain canceled entries until their upload channels shut down, so checking
only whether the entries list is empty does not handle cancellation correctly.

Cancellation now evaluates active entries, clears text when none remain and
finishes a batch whose remaining entries are done. Consumption takes only the
active entries, allowing canceled channels to finish shutting down separately.
Per-entry validation errors are displayed beside their cancel controls, and
the batch-size error now states the actual eight-image limit.
Temporary-copy failures now fail the collection instead of silently dropping
one image while reporting success; successful temporary copies are cleaned up.
Integration tests exercise both cancellation sequences with actual uploads.

## BUG — MEDIUM: long notes draw through the image grid and off the canvas

The collection layout clamped the pictures' starting position without reducing
the note. Forty lines at the fixed font size extended to y=16700 on an
8000-unit canvas while the pictures began around y=4600.

The note's font and bounding box now scale together to the available area above
the pictures. The long-note regression checks every shape is inside the canvas
and every pair of boxes is disjoint, in addition to checking picture size.

## BUG — MEDIUM: duplicate request IDs bypass the preview task limit

The task budget counted map keys, but `start_async/3` with a reused name starts
another task without canceling the old one. Repeated requests with one ref
could therefore start arbitrarily many fetches under one budget slot.
Malformed refs also fell through to the synchronous legacy handler.

In-flight refs are now refused before starting another task. Only requests
that omit the ref entirely use the compatibility handler; malformed refs get
`bad_request`. Unit regressions cover duplicate refs, the normal budget cap
and malformed refs. The existing integration test retains the no-ref contract.

## BUG — MEDIUM: viewport restoration survives hook teardown

Destroying a hook while `onReady` or `whenLayoutSettled` was pending still
allowed its callback to fit a view and register listeners later. Since board
pages reuse the same canvas ID, an old callback could act on the next board.
A rejected layout promise was also left unhandled.

Teardown invalidates restoration before clearing the handle and listeners.
Both readiness stages check that invalidation, and rejected layouts are
handled. The executable JS tests cover destruction before layout settles,
readiness after destruction and rejected layout promises.

## IMPROVEMENT — MEDIUM: verify locks with independent transactions

The existing concurrency test allowed tasks onto one sandbox connection;
those queries were serialized by the connection even without a PostgreSQL row
lock. Added a test with four distinct database backend PIDs, an explicit start
barrier and independent transactions against a committed disposable board.
All four edits must survive, and cleanup removes the board afterwards.

The affected save/collection helpers were also split to satisfy the current
strict Credo nesting and complexity checks without suppressions.

## Validation

- Full suite against a disposable local PostgreSQL 15 instance: **362 tests,
  zero failures, no exclusions** (`PGPOOL=8 mix test --max-cases 6`). The
  configured `postgres-test` server was in recovery, so the review used an
  isolated instance instead of accepting a run with integration tests excluded.
- Pre-review source with the regression suite: **13 failures in 117 tests**.
  Both the viewport teardown and rapid-paste JS regressions also fail against
  their original shipped scripts and pass with the fixes.
- Removing `FOR UPDATE` makes the independent-transaction test lose three of
  four simultaneous edits. Restoring it passes all seven save-race tests.
- `mix precommit`: compile with warnings as errors, unused-dependency check,
  Hex audit, format check, strict Credo and Dialyzer pass. Dialyzer reports zero
  errors and zero skips.

## Scope and limits

No version, changelog, release tag or database schema version changed. Revision
tokens are document metadata; no timestamp ordering or node clock assumption
is involved. Legacy tokenless `board_delta` messages trigger a reload. Boards
still running the protocol from before PR #10 require a reload during upgrade;
this review does not retrofit those already running processes.

The existing omission grace window and last-writer behavior for concurrent
updates to the same shape remain. The checks use PostgreSQL, isolated LiveViews
and Node execution of shipped JS; a real-browser, multi-node deployment was
not exercised.
