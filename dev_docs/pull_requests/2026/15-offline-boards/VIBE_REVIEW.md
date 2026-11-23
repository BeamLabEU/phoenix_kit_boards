# Vibe Review — PR #15 + the post-v0.8.0 changes

**Title:** Boards: work offline (Etcher 0.28 offline mode), opt-in — plus the
follow-ups merged after it (`6b2ec2c`, `92eb5ea`) and the two `lib upgrades`
commits (`b14a5cf`, `c8f8cbc`) that moved the lock to phoenix_kit 3.7.0 /
fresco 0.17.0 / etcher 0.29.1. Together these are everything since the v0.8.0
tag.
**Author:** Sasha Don (alexdont), Dmitri Don (lib upgrades)
**Merged:** 2026-11-18/19, into `main` (merge commit `e9c46ba`)
**Reviewer:** Mistral Vibe
**Date:** 2026-11-23

---

## Verdict

The offline wiring is sound: I checked every marker against Etcher 0.29.1's
own code (`deps/etcher`), not just its docs. One real bug and one staleness
issue, both fixed:

1. the `phoenix_kit` floor was still 3.6.0 although core 3.7.0 — the release
   the code's own comment said to wait for — is on Hex and in `mix.lock`;
2. a malformed `etcher:annotations-changed` was answered `:noreply`, which
   Etcher reads as "stored".

---

## Findings

### BUG - HIGH — the core floor was not raised once 3.7.0 was out

`BoardLive` calls `PhoenixKit.Offline.enabled?/0` and `worker_url/0`
**unguarded** (`offline?/0`, and `worker_url/0` again in the layer's
`offline_sw`), but `mix.exs` still declared `phoenix_kit >= 3.6.0 and < 4.0.0`.
`PhoenixKit.Offline` does not exist in 3.6.x (3.6.1 pins `fresco ~> 0.16.0`,
verified via `mix hex.info phoenix_kit 3.6.1`; 3.6.1 is retired). The
fresco `>= 0.17.0` floor made an old core unresolvable in practice, but only
as a side effect — a host pinning or overriding core 3.6.x would compile and
then crash on every board-page render. The `mix.exs` comment next to the
fresco floor said exactly this: "Raise the core floor to that release once it
is out." The `lib upgrades` commits put 3.7.0 in `mix.lock`, so the condition
has landed.

**Fixed:** floor is now `>= 3.7.0 and < 4.0.0` in `mix.exs` (comment
rewritten to say why: 3.7.0 is the first core that admits fresco 0.17 *and*
carries `PhoenixKit.Offline`), and the fresco/etcher comment no longer ends
with the open instruction. `AGENTS.md` and the README's Requirements section
updated to match — the README also still listed `fresco >= 0.16.0` /
`etcher ~> 0.25`, stale since the floor bump.

### BUG - MEDIUM — a malformed save was acknowledged as stored

The catch-all `handle_event("etcher:annotations-changed", _params, socket)`
answered `{:noreply, socket}`. Etcher's `acknowledged/1`
(`deps/etcher/priv/static/etcher.js:753`) treats **any** reply other than
`saved: false` as "the server stored this list" and clears the device's
`dirty` flag — so a non-list payload that reached this clause would make an
offline device drop the only copy of work the server never got. The PR's own
rule ("a save that was not stored must reply `%{saved: false}`") covers it:
nothing was stored.

**Fixed:** the clause now replies `{:reply, %{saved: false}, socket}`.
Pinned by a new test in `test/integration/offline_save_reply_test.exs`
(non-list payload and missing key both answer `saved: false`).

### IMPROVEMENT - LOW — `offline?()` evaluated once per render, not three times

The connected render called `offline?()` inline in three attributes
(`data-offline-root`, `offline`, `offline_sw`) while the disconnected render
already assigned it once. **Fixed:** the connected render now starts with
`assigns = assign(assigns, :offline?, offline?())` and the template uses
`@offline?` — same shape as the `board: nil` clause.

### TEST GAP - the presence roster's `data-offline-hide` was unpinned

The header's "who is here" block carries `data-offline-hide` so Etcher
strips it from the saved offline shell (`shellHtml` removes
`[data-offline-hide], script`). Nothing asserted it. **Fixed:**
`offline_save_reply_test.exs` now asserts the marker on the board page with
offline on.

---

## Checked, no finding

- **Layer attributes vs Etcher 0.29.1:** `offline`/`offline_sw` render as
  `data-offline-key`/`data-offline-sw` (`etcher/layer.ex:680-682`); the board
  passes `"board:" <> uuid` and core's `worker_url/0`. HEEx omits the attrs
  when `offline?()` is false, so `@offline` is nil there — matches the
  defaults.
- **The one-worker-per-site invariant:** `worker_url/0` is core's
  `/assets/etcher-offline-sw.js`; core's `AssetsController` serves it with
  `service-worker-allowed: /` and 404s while offline is off. No second
  worker is served from this module (the dead fallback route was already
  removed in `92eb5ea`).
- **Offline rebuild markers:** `data-offline-slot` on the disconnected render,
  `data-offline-root` on the connected one, `data-offline-hide` on the roster —
  exactly what `etcher.js` `standalone/1` looks up (`[data-offline-slot]`,
  `closest("[data-offline-root]")`), and the SW's `etcher-offline-copy` meta
  is what both Etcher's `boot()` and the page's inline loader key on.
- **The inline loader script:** early-returns on an online load without the
  SW's copy marker; offline is always a full page load so a plain `<script>`
  runs (patches never would). Nonce comes from `assigns[:script_csp_nonce]`,
  the same assign `RuntimeHooks.scripts` already uses; `loadVendored` with a
  `check` exists in core 3.7.0's `phoenix_kit.js`. The SW caches the CSP
  header with the page, so the nonce still matches offline.
- **`saved: false` contract:** Etcher pushes saves through `pushEventTo`, so
  the reply reaches `acknowledged/1`; a `:noreply` success still sends an
  empty reply envelope, which counts as stored — correct for the stored and
  empty-delta paths. The resync path rides plain `pushEvent("board:ready")`,
  which the client does not await, so it needs no reply (same conclusion as
  the earlier review's note on the access-hook halt).
- **PR #16's rename** (`initials/1` → `presence_initials/1`) is complete: no
  other `initials(` call in `lib/`, and core 3.7.0 really does export
  `PhoenixKitWeb.Components.Core.UserInfo.initials/1`, so the clash it
  pre-empts is real. Compiles with `--warnings-as-errors`.
- **Lock-only commits** (`b14a5cf`, `c8f8cbc`): `mix.lock` moves to phoenix_kit
  3.7.0, fresco 0.17.0, etcher 0.29.1, phoenix 1.8.17, live_view 1.2.15 — all
  within the declared requirements; nothing hand-edited.

## Gate

`mix format` clean; `mix compile --force --warnings-as-errors` clean;
`mix test`: 465 tests, 0 failures, 0 excluded (postgres reachable; the two
offline test files alone: 7 tests, 0 failures, 0 excluded);
`mix precommit` (format check + credo --strict + dialyzer + hex.audit):
passed — credo 812 mods/funs no issues, dialyzer 0 errors, no retired or
advisory packages.
