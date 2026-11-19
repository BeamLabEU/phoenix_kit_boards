# Claude Review — PR #15

**Title:** Boards: work offline (Etcher 0.28 offline mode), opt-in
**Author:** Sasha Don (alexdont)
**Merged:** 2026-11-19, locally into `main` (merge commit), with the fixes below in a follow-up commit
**Reviewer:** Claude (Anthropic)
**Date:** 2026-11-19

---

## Verdict

Sound. The offline machinery lives in Etcher (0.28+) and Fresco (0.17). The PR
wires boards to it: the key on the layer, the page markers, a loader in the
disconnected render, and the `saved: false` reply on a failed write. I checked
the reply contract against Etcher 0.29's `acknowledged/1`: any reply other than
`saved: false` clears `dirty`, so a failed write that answered `:noreply` would
throw away the only copy. The PR fixes exactly that path.

One improvement was applied: the module's own copy of the service worker was
dead code and has been removed. Two other items are on record without a code
change.

---

## Findings

### IMPROVEMENT - MEDIUM — the module's own service worker could never be used

The PR added `GET /admin/boards/assets/offline-sw.js` (both route sets,
`AssetController.offline_worker/1`). `BoardLive.offline_worker_url/0` named
core's worker (`PhoenixKit.Offline.worker_url/0`) "when the core in use has
one" and fell back to this route otherwise.

The fallback cannot be reached. The PR raises the floors to fresco
`>= 0.17.0` / etcher `~> 0.28`. Published core 3.6.1 pins `fresco ~> 0.16.0`,
so these resolve only next to a core that admits fresco 0.17. That core is the
next release, and its `main` already has `PhoenixKit.Offline` (#1045 and #1047
were merged together). The fallback therefore only added surface:

- a route that served a site-wide-scope worker (`service-worker-allowed: /`)
  even with offline off. Core's version answers 404 while
  `PhoenixKit.Offline.enabled?/0` is false;
- a second definition of the switch (`BoardLive.offline?/0` duplicated
  `PhoenixKit.Offline.enabled?/0`);
- `Code.ensure_loaded?/1` + `function_exported?/3` on every render.

**Fixed:** the route and the controller action are gone. `BoardLive` uses
`PhoenixKit.Offline.enabled?/0` and `worker_url/0` directly through a private
`offline?/0`. The `mix.exs` comment records that the fresco floor implies that
core, and that the core floor should be raised once that release has a number.
README no longer describes the removed route.

### TEST GAP — nothing checked that the page actually turns offline on

The unit tests covered the switch, the worker response and the spinner's slot
marker. Nothing rendered a real board page and looked at the layer.

**Fixed:** `offline_save_reply_test.exs` now mounts the board page. With
offline on, the layer carries `data-offline-key="board:<uuid>"`, and
`data-offline-sw` is **core's** worker URL. That URL is the one-worker-per-site
invariant: if the board named a different URL than the media viewer, each
registration would replace the other. The root carries `data-offline-root`.
With offline off, the page carries none of these. `offline_test.exs` now checks
the spinner's loader script, and that a non-`true` value (`"true"`) leaves it
out.

### NOTE — saves refused by the access hook are not answered `saved: false`

On a board whose access was just revoked, `attach_hook(:board_access, …)` halts
`etcher:annotations-changed` with `{:halt, socket}`. That is a plain no-reply.
**Not changed.** The halt always comes with `leave/1`'s redirect, so the page
navigates away and the push's reply never settles. The device's copy stays
dirty and is merged on the next online load if access comes back. An explicit
`{:halt, %{saved: false}, socket}` would cost nothing, but `render_hook` sees
only the redirect, so a test could not pin it.

### NOTE — the offline copy outlives a sign-out

The page's shell (Cache Storage) and the board's shapes (IndexedDB) stay in the
browser after the person signs out, or after they lose access. This is
inherent in offline mode and is the same for core's media viewer. It is
opt-in. **Documented** in the README ("turn it on only where devices are not
shared").

---

## Checked, no finding

- **`{:reply, %{saved: false}, …}`** is valid from `handle_event/3`. Etcher
  pushes through `pushEventTo`, so the reply reaches it.
- **Empty-delta path** (`:noreply`, nothing stored) is correctly an
  acknowledgement: the server already holds that list.
- **Inline loader script** runs only on a full page load. A LiveView patch does
  not execute `<script>`, and the script returns early unless the service
  worker marked the page as the offline copy (`etcher-offline-copy`) or the
  browser is offline. `window.PhoenixKitLibraries.loadVendored` is in core's
  `phoenix_kit.js`. It carries the CSP nonce when the host sets one.
- **Merged with `main`'s "Board not found." render** without conflict.
- **Interplay with BoardSync's reconnect resync:** the two do not overlap.
  Resync covers a socket that drops while the page stays open. Etcher's offline
  path covers a page reloaded from the worker, and sends its merge through the
  ordinary `etcher:annotations-changed`, under the same revision and
  `peer_arrivals` rules as any edit.

## Gate

`mix test` against core `main` (`PHOENIX_KIT_PATH=../phoenix_kit`): 464 tests,
0 failures, 0 excluded (postgres-test reachable). `mix precommit`: see the
commit. `mix.lock` is left as on `main`, as the PR did. It cannot hold fresco
0.17 next to the published core 3.6.1, so **boards' `main` resolves only with
`PHOENIX_KIT_PATH` until the next core is on Hex.**
