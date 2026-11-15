# PR #11 — PDF export and embedded board viewer

**Author:** @alexdont · **Reviewer:** GPT/Codex · **Date:** 2026-11-15
**Result:** Three follow-ups fixed; full validation passed.

## Scope

Rechecked every change since the last published Hex release, v0.7.0
(`67acdf0`), through `8c1d884`, including the earlier review fixes. The other
PRs in this pass are [#12](../12-boards-manage-permission/GPT_REVIEW.md),
[#13](../13-paste-hint-layout-shift/GPT_REVIEW.md), and
[#14](../14-laser-measure/GPT_REVIEW.md). No version bump or publication.

Read the changed modules with their callers and the actual packaged Fresco,
Etcher, and LiveView implementations. Verified off-screen layer readiness,
export return values, hook event routing, embedded missing-board redirects,
flash rendering, watchdog phases, and stale export sequence handling.

## Findings fixed

### BUG — MEDIUM: A cancelled export could still download

After `exportPdf` started, `destroyed()` only suppressed its completion event.
Fresco itself still clicked the download link when rasterisation finished.
Changing the widget's place, losing access, navigating away, or hitting the
running watchdog could therefore be followed by an unexpected PDF download.

The hook now requests `download: false`, waits for Fresco's returned Blob,
and downloads only while the hook remains active. The link is removed and
the object URL is released. JS regression coverage resolves an in-flight
export after destruction and verifies there is no download or completion
event; the success case verifies exactly one named download.

Limitation: this suppresses the late download; Fresco has no cancellation API
to stop rasterisation already underway.

### BUG — LOW: Escape did not close the overlay after entering the board

The parent's `phx-window-keydown` never receives keyboard events from the
iframe. Added a small runtime hook on the iframe that listens for an idle
Escape in its own window. Etcher's capture handler still gets first use of
Escape to cancel drawing, deselect, or dismiss menus. Prevented events and
focused editable fields are left alone. Listeners are replaced on frame
loads and removed on destruction; cross-origin redirects are tolerated.

JS coverage checks idle/consumed Escape, editable fields, reloads, cleanup,
and inaccessible frames. LiveView coverage checks the hook is actually
attached to the rendered frame. These are Node and LiveView tests; this pass
does not claim an interactive browser session.

### IMPROVEMENT — MEDIUM: Authorize the same snapshot used for export

The export checked a metadata-only row, then fetched the full board again
without checking that second row's visibility or place. The two reads could
observe different versions during a concurrent visibility or place change.
`visible_board` now accepts query options, and export requests the document
in that same read. Existing scope/private/missing-board tests cover refusal;
ordinary tile actions still fetch metadata only.

## Validation for the complete release-range review

- Published Hex dependencies: PhoenixKit 3.6.0, Fresco 0.16.0, Etcher 0.26.0;
  no local dependency overrides.
- Baseline: 456 tests, zero failures, no integration exclusions.
- Focused checks: 94 tests, zero failures.
- Final full suite: 458 tests, zero failures, no integration exclusions.
- `mix precommit`: compilation with warnings as errors, unused-lock check,
  Hex audit, format check, strict Credo, and Dialyzer passed.
- The suite includes real PostgreSQL integration tests and Node hook tests.
