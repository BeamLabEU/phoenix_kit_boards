# Vibe Review — PR #16

**Title:** Rename the board page's initials helper: it clashes with core's once the people picker lands
**Author:** Tymofii Shapovalov (timujinne)
**Merged:** 2026-11-19, into `main` (merge commit `d2459ce`, commit `c6cc294`)
**Reviewer:** Mistral Vibe
**Date:** 2026-11-23

---

## Verdict

Correct and complete. No findings.

## Checked

- Core 3.7.0 (now in `mix.lock`) really does export
  `PhoenixKitWeb.Components.Core.UserInfo.initials/1`
  (`deps/phoenix_kit/lib/phoenix_kit_web/components/core/user_info.ex:359`),
  which `use PhoenixKitWeb, :live_view` imports — so the local `initials/1`
  this PR renamed would have failed the host's build with "imported …
  conflicts with local function".
- The rename is complete: the only `initials` references left in `lib/` are
  the two `presence_initials/...` call sites and the `defp presence_initials/1`
  itself (`board_live.ex:1573,1581,1664`). The helper's behaviour is unchanged
  (still a single upcased first character).
- Compiles with `--warnings-as-errors` against the locked core 3.7.0;
  `mix test` green (see the #15 review doc for the gate numbers).

## Release note (carried from the earlier review, still true)

boards 0.8.0 on Hex has the old name under a core floor that admits the core
release carrying `UserInfo.initials/1`; the release with this rename must be
on Hex no later than that core release. Core 3.7.0 is now out and the floor
has been raised to it (see the #15 review), which resolves the pairing.
