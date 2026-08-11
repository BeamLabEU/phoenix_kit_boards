# PR #5 — Let the hook bundle past CSRF's cross-origin-script guard

**Author:** alexdont · **Branch:** `hooks-bundle-csrf` · **Reviewed:** 2026-08-11

Fixes the 0.4.0 regression where `/admin/boards/assets/hooks.js` answered 403
to every load, plus two diagnosability improvements to the shim.

## The fix is correct, and correctly argued

`Plug.CSRFProtection.cross_origin_js?/1` refuses a GET that returns a
JavaScript content-type, is not an XHR, and hasn't opted out. Verified against
the route: `PhoenixKitBookings`-style admin routes are injected inside core's
admin scope, which pipes through the host's `:browser` pipeline and therefore
`protect_from_forgery`; `AssetController` sets `text/javascript`; the shim
loads with `document.createElement("script")`, which sends no
`x-requested-with`. All three hold.

`put_private(:plug_skip_csrf_protection, true)` is the flag that guard reads,
and it is set first in the pipe, so it covers the 304 branch as well as the
200. The security argument holds on inspection: `@bundle File.read!(...)` is a
compile-time constant, byte-identical for every visitor, carrying no user,
session or board data — there is nothing for a cross-origin `<script>` include
to learn. The route is additionally admin-gated.

The Elixir test drives the real `Plug.CSRFProtection` rather than asserting the
private flag, which is the right level.

---

## IMPROVEMENT - MEDIUM — a failed load printed two contradictory errors

The retry change nulls the memo on `onerror` and calls `explain(SRC)`. But
`forward()` resolves regardless of outcome and then checks
`window.PhoenixKitBoardsHooks`; on a failure it is undefined, so it *also*
logged "loaded but defined no hooks — check that the URL returns the hook
bundle rather than a redirect or an error page".

Two messages for one cause, and the second is wrong: the bundle did not load at
all. The console then names the wrong class of problem right after the message
that named the right one.

**Fixed.** `onerror` now claims the once-per-page `__phoenixKitBoardsWarned`
flag, so only the accurate error is printed. Pinned in
`test/js/runtime_hook_test.js`; removing the line fails the test (verified by
mutation).

## IMPROVEMENT - MEDIUM — `explain()` could report "could not load (HTTP 200)"

The refetch reports the status and, on 403, names CSRF. Every other status fell
through to a bare `"(HTTP <n>)"`. The interesting one is 200: if the refetch
succeeds, the URL and the response are both fine and something stopped the
browser *executing* the script — a CSP, in practice, which is one of the three
causes the shim's own comments name. Printed as "could not load … (HTTP 200)",
that reads as a contradiction rather than as the clue it is.

**Fixed.** `hint/1` now handles the `response.ok` case explicitly and points at
the page's CSP and the `nonce` attr the `scripts/1` component accepts.

## NITPICK — failed `<script>` nodes accumulated in `<head>`

Each retry appends a new element and the failed one was never removed. Now
removed in `onerror`; asserted in the JS test.

---

## Test-harness changes (they were blocking the above)

- `browser()` now models `head.children` with a working `removeChild`, keeping
  `injected` append-only so existing index-based assertions still hold.
- `install()` passes `fetch` in explicitly. Without it the emitted shim reached
  Node's real `fetch` global straight past the stand-in and issued a live
  request during the test run, and `explain()` could not be exercised at all —
  it was the one new function in the PR with no coverage.

## Unrelated fix — a fragile assertion this PR would have tripped

`runtime_hooks_test.exs`, "the CSP nonce is absent unless the host supplies
one" matched `"nonce="` against the *whole* render, which is 4 KB of JavaScript
plus comments. Any comment mentioning the attribute fails it — as a comment
added here did. Narrowed to the `<script …>` opening tags, which is what the
test means.

---

## Verification

- `mix test` — 84 tests, 0 failures.
- `node test/js/runtime_hook_test.js` — all checks passed.
- `mix precommit` (incl. dialyzer) — clean, exit 0.
