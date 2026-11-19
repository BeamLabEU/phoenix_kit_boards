# Claude Review — PR #16

**Title:** Rename the board page's initials helper: it clashes with core's once the people picker lands
**Author:** Tymofii Shapovalov (timujinne)
**Merged:** 2026-11-19, locally into `main` (merge commit)
**Reviewer:** Claude (Anthropic)
**Date:** 2026-11-19

---

## Verdict

Correct and complete. Core's `PhoenixKitWeb.Components.Core.UserInfo` now
exports `initials/1` (phoenix_kit#1046, merged on core `main`), and every
`use PhoenixKitWeb, :live_view` module imports it, so a local `defp initials/1`
fails the build ("imported … conflicts with local function"). The PR renames
the board page's helper to `presence_initials/1` and moves both call sites.

Checked: no other `initials(` call is left in `lib/`, and the module compiles
with `--warnings-as-errors` against both the published core 3.6.1 and core
`main`. No findings.

## Release note

phoenix_kit_boards 0.8.0 on Hex has the old name, and its core requirement
(`>= 3.6.0 and < 4.0.0`) admits the next core release, which carries #1046. A
host on boards 0.8.0 that takes that core will not compile. The boards release
with this rename has to be on Hex no later than that core release. Since #15
(merged right after this one) makes boards' `main` resolve only against that
same core, the two have to ship together: core first, boards right after.
