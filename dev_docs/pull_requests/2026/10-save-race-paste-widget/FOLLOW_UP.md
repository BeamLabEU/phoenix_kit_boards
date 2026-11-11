# Follow-up review of PRs #9 and #10

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
