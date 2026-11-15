# PR #12 — Separate user and administrator permissions

**Author:** @timujinne · **Reviewer:** GPT/Codex · **Date:** 2026-11-15
**Result:** One follow-up fixed.

Rechecked this PR and its follow-ups as part of the complete review since
v0.7.0. Reviewed base/sub-key enforcement, host-hook refusal, private and
unscoped boards, admin scope-change callbacks, durable event checks, and the
one-time backfill's failure and retry behavior against PhoenixKit 3.6.0.

## BUG — MEDIUM: Permission restoration resurrected an old viewer and export

A refresh after losing view access rendered an empty widget but kept
`viewing` and `exporting` in the LiveComponent's assigns. If access returned
before the export watchdog expired, the old viewer reopened and the export
hook mounted again with its old canvas snapshot, without a new user action.

The access refresh now clears both assigns when view permission is absent.
A PostgreSQL/LiveView regression opens a board and starts an export, revokes
access, refreshes, restores permission, and confirms neither activity returns.
A deliberate new export still works with the next sequence number.

No additional defects found in the backfill or admin-page checks. Full
validation and related fixes are in the [release-range review](../11-pdf-export/GPT_REVIEW.md#validation-for-the-complete-release-range-review).
