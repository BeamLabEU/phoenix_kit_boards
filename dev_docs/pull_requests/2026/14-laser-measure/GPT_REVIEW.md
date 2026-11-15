# PR #14 — Opt-in laser measure

**Author:** @alexdont · **Reviewer:** GPT/Codex · **Date:** 2026-11-15
**Result:** No additional findings.

Rechecked the PR and follow-ups since v0.7.0. Both the tool list and iframe
Bluetooth delegation read the same runtime switch and require literal
`true`. Tests restore the original application setting. Checked the actual
Etcher tool and permission-facing call sites, plus dependency compatibility:
the published PhoenixKit 3.6.0 used here requires Etcher 0.26, so the older
release-order concern is resolved for this checkout's declared floor.

The [complete review](../11-pdf-export/GPT_REVIEW.md#validation-for-the-complete-release-range-review)
ran against published Hex dependencies, with the full suite and precommit
gate passing. No Bluetooth hardware was connected during this review.
