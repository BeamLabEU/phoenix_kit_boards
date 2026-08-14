# PR #7 Phase 1 Review — phoenix_kit_boards
**Title:** Update the lock to etcher 0.12.0
**Author:** Sasha Don (alexdont)
**Date:** 2026-08-14
**Verdict:** APPROVE

## Summary

Lock-only bump: etcher `0.11.0` → `0.12.0` in `mix.lock`. Single file, single line changed. The existing `~> 0.11` constraint in `mix.exs` already admits this version (Elixir interprets it as `>= 0.11.0 and < 1.0.0`), so no constraint change is needed. This is the expected downstream propagation of the phoenix_kit #715 rollout.

PR body is thorough: documents API compatibility check across all call sites (`onShapesMoving`, `applyShapesMoving`, `toolBadge`, prefs relay, annotations events), and notes that the two new 0.12 prefs (snap toggle, remembered label colour) ride the existing opaque prefs blob without any code changes needed. Claims 85 tests green (including 5 node suites against the real etcher handle API) and credo --strict clean.

## Findings

### Blockers
None.

### Non-blockers
- **No CI checks reported on the branch.** `gh pr checks` returned "no checks reported on 'deps/etcher-0.12'". The PR body claims full suite green locally, but there's no automated signal to confirm. If the repo has CI, worth checking why it didn't run. Low concern for a lock-only change — not blocking.

### Nitpicks
- None. PR body is model-quality for a dependency bump: explains *why* the constraint already works, lists every API this module calls and confirms it's unchanged in 0.12, and notes the new prefs are transparent to the module. No version bump for the module itself is correct — no public API changed.

## Stats
- **Files changed:** 1 (`mix.lock`)
- **Additions:** 1 / **Deletions:** 1
- **Tests:** No new tests (correct — lock bump only). PR body claims 85 existing tests pass.
- **Migrations:** None
- **Version bump (module):** None (appropriate — lock-only change, module API unchanged)
- **Dependency changes:** etcher `0.11.0` → `0.12.0` only; all other lock entries untouched; etcher's own transitive dep range unchanged

---

## Delta Review (2026-08-14)

**Trigger:** PR updated to add "classify board uploads properly" — new commit beyond the lock bump.
**Files changed (delta):** +1 (`lib/phoenix_kit_boards/web/board_live.ex`) — 6 lines added (comment block), 1 line changed (the classifier call); `mix.lock` unchanged from original.

### What changed

`store/4` in `board_live.ex` (line 251) replaces the hardcoded `"image"` argument to `Storage.store_file_in_buckets/6` with `Storage.determine_file_type(entry.client_type, entry.client_name)`.

The root cause documented in the PR body is confirmed by reading `@image_accept` (lines 40–44): it explicitly allows audio (`.mp3 .m4a .wav .ogg .opus`) and video (`.mp4 .m4v .webm .mov`) formats alongside images. Every upload through this path — including audio and video — was being stored with `file_type: "image"`, breaking the media page's type column, filters, variant processing, and typed pickers.

### Correctness

**Fix is correct.** `Storage.determine_file_type/2` is the one shared classifier used by every other core upload path (`media_browser.ex`, `media_selector_modal.ex`, `media_selector.ex`, `upload_controller.ex`). Its logic: classify by MIME type prefix (`image/`, `video/`, `audio/`), fall back to filename extension when the MIME is `application/octet-stream` or unknown. This exactly matches what the boards upload path needs.

The `store_data_url` path (line 368) also calls `store/4` with `client_type: MIME.type(ext)` — constructed from the data URL's extension. These are clipboard-pasted images and will correctly classify as `"image"`. No regression there.

### Edge cases & security

- **Unknown/exotic MIME types:** `determine_file_type` gracefully returns `"other"` — the same fallback core uses everywhere. No crash risk.
- **`application/octet-stream` uploads:** filename extension fallback fires correctly — the `@image_accept` filter ensures only named types reach `store/4`.
- **Security improvement:** before, `.mov` files could trigger image variant processing against a video — the fix stops that misrouting. Correct type means correct downstream pipeline.
- **data URL path:** always image MIME types (clipboard paste), no regression.

### Tests

No new tests for the classification path in boards. Non-blocking because:
1. `Storage.determine_file_type/2` has its own test suite in core (`determine_file_type_test.exs`, confirmed in CHANGELOG).
2. The boards upload path requires full LiveView socket integration to test end-to-end.
3. PR body claims 85 tests pass (including JS node suites).

**Mild gap:** there is no test asserting that a video/audio upload through boards results in the correct `file_type` on the stored file. Worth a follow-up test, but not a blocker.

### Version bump

The original review noted "no version bump (appropriate — lock-only change)." That context has changed. This is now a behavior fix with observable user impact (file_type column data was wrong; it will now be correct for all new uploads). A **patch bump is warranted**. The PR body says "No version bump" — this is the one thing worth pushing back on.

### Findings

#### Blockers
None.

#### Non-blockers
- **Version bump omitted.** The fix corrects `file_type` for all new audio/video uploads — observable behavior change. A patch version bump should accompany this commit. Worth flagging to Sasha.

#### Nitpicks
- None. The comment block added above `store/4` clearly explains the historical bug and the fix rationale. Model quality for a behavior fix.

### Delta verdict: APPROVE (with note on version bump)

The classification fix is correct, uses the right shared function, and closes a real data-correctness bug confirmed on live data. APPROVE stands; request a version bump before merge.
