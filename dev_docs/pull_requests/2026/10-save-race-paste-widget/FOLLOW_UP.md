# Follow-up review of PRs #9 and #10

Reviewer: Codex (OpenAI) · 2026-11-11 · fixes in `4b26af8`.

Reviewed `8ccd2f3` on `main`, including the fixes from both prior reviews.
Both PRs were merged and GitHub listed no open PRs for this repository.

## Medium severity · A joining editor could miss a committed edit

The connected mount read the canvas before subscribing to the board topic.
If a peer committed and broadcast in that interval, the new editor retained
the old snapshot until another change prompted it to catch up. Updates after
subscription could also arrive while the browser was loading the runtime hook.

The mount now subscribes using the canonical UUID before taking the snapshot.
It accumulates any subsequent changes in server state and sends the difference
from the rendered canvas when BoardSync announces it is ready. Both hooks also
announce themselves on reconnect. The mounted LiveView regression commits and
broadcasts an edit from another process during authorization, then checks that
the cursor handshake leaves the delta pending and BoardSync receives it once.

## Medium severity · Revoked create access left a pending paste behind

A panel that refreshed after losing create access still accepted clipboard
events and kept its pending uploads and caption. Restoring access could leave
the next upload sharing the old batch. A refresh now cancels active captures
and disables clipboard capture and the file input while the panel is read-only.
The LiveView test revokes permission mid-upload and verifies that the next
picture gets a board of its own when access returns. The JavaScript test checks
that the hook drops its queue when capture is disabled.

## Dependency audit

Updated the lockfile from Ecto 3.14.2 to 3.14.3 to clear CVE-2026-118391.
[Ecto security advisory](https://github.com/elixir-ecto/ecto/security/advisories/GHSA-cxjx-vmm2-qr8r)

## Validation

- `PGHOST=postgres-test PGPOOL=8 mix test --max-cases 6` ran 374 tests,
  including the LiveView integration and Node hook tests, with zero failures
  or exclusions.
- `mix precommit` passed compilation, dependency checks, Hex audit, formatting,
  strict Credo and Dialyzer.

## Medium severity · A reconnecting page stayed stale and could revert peers

Found by Claude (Anthropic) on 2026-11-11 while checking the pass above.
That pass sends `board:ready` from both hooks on `reconnected()`, so a
reconnect gets a fresh channel token. The annotations were still wrong,
though. A reconnect mounts a new LiveView from the stored board, while the page
still holds the board from before the drop. The page also holds any edits made
offline, which the server never received because hook events pushed while
disconnected are dropped. The catch-up diffed from the new mount's snapshot, so
the page saw none of its peers' changes until its next edit. That edit's list
was stale and wrote back the old versions of whatever peers had changed. It
also brought back shapes they had deleted.

BoardSync now snapshots the board on `disconnected()`. On `reconnected()` it
sends `board:ready` with `resync`, containing its whole list and the uuids it
created, updated or deleted since the snapshot. The server applies only those
changes on top of the stored board with `Boards.apply_delta/2`. A peer's
delete beats an offline edit of the same shape. The server stores and
broadcasts the result, then sends the page the diff from the list it holds.
The page's listed shapes count as acknowledged, so a later list that omits
one is a delete.

A related bug showed up while tracing this. `board:apply` deleted first, and
etcher's `deleteShape` reports the whole list synchronously while
`patchShape` reports nothing. A delta that both deleted one shape and updated
another therefore stored the old version of the updated shape. Deletes now run
last, so the final report is the finished board.

Still open: a delta that deletes several shapes still reports once per delete.
Each intermediate list briefly restores the shapes not yet deleted, and the
last report removes them again. Fixing this needs a batch delete in etcher, or
a server-side grace period for deletes like `peer_arrivals`.
