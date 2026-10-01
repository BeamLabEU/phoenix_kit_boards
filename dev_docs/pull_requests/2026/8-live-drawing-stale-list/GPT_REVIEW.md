# GPT review — published 0.4.6 and PR #8

**Reviewer:** Codex (OpenAI)
**Date:** 2026-10-01
**Baseline:** `v0.4.6` / `3a79ff5`, confirmed against the Hex package API.
**Result:** meaningful fixes included in patch release 0.4.7.

## BUG — HIGH: runtime hooks mount without their helper methods

The generated loader forwarded lifecycle callbacks with `hook[callback].call(ctx)`
but never installed the bundle's other methods on the LiveView hook instance.
LiveView had already copied the shim when creating that instance. Consequently
`BoardSync.mounted` failed at `this.armEditing()` and `BoardCursors.mounted`
failed at `this.attach()` when Fresco was ready. Automatic JS delivery failed
even though the script loaded, disabling collaboration and BoardSync's storage
upload, unfurl and preference integration. Hosts registering the bundle directly
were unaffected.

**Fix:** install helper methods before mounting while preserving lifecycle
wrappers and their destruction guards. Extend the generated-loader test to load
and mount the actual shipped bundle, rather than callback-only stand-ins. The
new test reproduced both TypeErrors before the fix.

## BUG — MEDIUM: CSP nonce stops at the inline loader

`scripts/1` accepted a nonce for its inline scripts, but the dynamically appended
bundle script had none. A nonce-based CSP without `strict-dynamic` can accept
the loader and block the bundle.

**Fix:** propagate the supplied nonce to the bundle script. The generated-loader
test asserts the injected script receives it.

## BUG — HIGH: reconnect guard still permits buffered ephemeral pushes

`link.joined` remembers a successful join. It remains true when Phoenix marks
the channel errored or starts rejoining. Checking only transport connectivity
therefore admits pushes after the WebSocket reconnects but before the channel
rejoins. Phoenix's `Channel.push` buffers those frames and replays them on join,
contradicting the 0.4.6 fix.

**Fix:** check the channel's current `canPush()` state in `BoardLink.get`.
Executable tests use the shipped bundle and simulate an open transport with a
rejoining channel, asserting all five ephemeral event types are dropped without
being buffered, and streaming resumes after join.

## BUG — HIGH: repeated restore replies append duplicate shapes

Several queued stale lists each earn a `created` restore reply. Etcher's
`addShape` renders and appends; it does not deduplicate by uuid. The browser thus
appended multiple copies after the server correctly protected a peer's work.
UUID-based diffs can conceal these duplicates and make subsequent edits and
deletes inconsistent.

**Fix:** skip already-present uuids in the delta's `created` list. The executable
apply test checks only one add across repeated replies and preserves a subsequent
local edit when an older restore arrives.

## BUG — MEDIUM: ghost lifecycle crosses strokes and board navigation

A delayed `drawn` for an older stroke unconditionally retired the peer's current
ghost. Older frames could also replace a newer stroke if the old end had not
arrived. Separately, `BoardSync.destroyed` left ghost timers alive; their callbacks
look up the current layer by canvas id, potentially touching a later board.

**Fix:** track each active ghost's stroke number, reject older frames and ends,
and cancel timers/retire ghosts on destruction. Tests cover timeout renewal,
abandonment, reordered ends, finished-stroke suppression, a new stroke, older
unnumbered clients and destruction.

## Validation and limits

- Baseline: 122 tests passed. Fixed suite: 123 tests passed, including the new
  executable Node coverage and the generated-loader integration test.
- Release gate passed: `mix precommit` (compile with warnings as errors, unused lock
  check, Hex audit, formatting, strict Credo and Dialyzer).
- No schema migration or dependency change is required.
- The suite does not boot a database-backed host or a real browser. CSP behavior
  is checked through nonce propagation; network ordering through executable
  stand-ins using the shipped hook bundle.
- The existing whole-list protocol still uses a five-second omission grace
  window. It does not provide revision-based conflict resolution for concurrent
  edits to the same shape or stale lists outside that window. Replacing that
  protocol is beyond this patch; these fixes preserve its current contract.
