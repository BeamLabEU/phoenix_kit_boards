# PR #4 — Deliver the collaboration hooks without host JS wiring

**Reviewed:** 2026-08-10 · **Author:** alexdont · **Verdict:** merged, no
changes required. Released in **0.4.0**.

+760 / −5 across 11 files. Reviewed as part of the phoenix_kit 2.0 sweep.

## The bug is well-diagnosed

Hooks were delivered only via `js_sources/0`, which only core's
`:phoenix_kit_js_sources` compiler consumes. A host that bundles dependency JS
its own way gets nothing: `window.PhoenixKitBoardsHooks` is never defined while
the board renders `phx-hook="BoardSync"` / `phx-hook="BoardCursors"` naming
hooks the LiveSocket has never heard of.

The PR is right that the *shape* of the failure is the expensive part. The
canvas renders and local edits persist, because only the inbound half needs the
hook — so it presents as "collaboration is broken", not "the JS never loaded",
and there is no console or log error to follow. That is a genuinely costly
class of bug, and the fix removes the host's ability to get it wrong rather
than documenting the requirement harder.

The premise it retires is also correctly identified: hooks no longer must be in
the host's `LiveSocket` at construction. Since LiveView 1.1,
`getHookDefinition/1` resolves a name at element mount, falling back to
`script[data-phx-runtime-hook="Name"]`.

## Asset controller — checked, safe

This is the part that warranted scrutiny, since it serves a file over HTTP:

- **No path traversal is possible.** The bundle is read **at compile time**
  into a module attribute (`@bundle File.read!(@bundle_path)`) and the response
  body is that fixed binary. No request parameter reaches a filesystem call —
  `js/2` ignores `params` entirely. This also sidesteps `priv_dir` resolving
  differently inside a release, which the moduledoc calls out.
- **Caching is correct and safe.** The digest rides on the URL as a query
  parameter, so `max-age=31536000, immutable` cannot pin a stale bundle: a new
  bundle is a new URL. ETag/`304` handling parses a comma-separated
  `if-none-match` and honours `*`.
- **Content type is explicit** (`text/javascript; charset=utf-8`).
- **Route ordering is right**, and commented: the asset route is declared
  before `/admin/boards/:id`, which would otherwise claim
  `/admin/boards/assets/hooks.js` as an `:id`. Both the localized and
  non-localized route sets get it.

Implementing it as a bare `Plug` rather than `use Phoenix.Controller` is the
right call for a fixed binary with fixed headers — no view, layout or format
negotiation is involved.

## Verification

| Check | Result |
|---|---|
| `mix precommit` | **passes** against core 2.0.0 |
| `mix test` | **82 tests, 0 failures** |

Test coverage is unusually good for this class of change: `runtime_hooks_test.exs`,
`asset_controller_test.exs`, and a JS-level `test/js/runtime_hook_test.js` driven
from `js_runtime_hook_test.exs`. The one thing not verified here is the actual
end-to-end behaviour in a host that bundles its own JS — which is the scenario
the PR exists for, and needs a real host app.
