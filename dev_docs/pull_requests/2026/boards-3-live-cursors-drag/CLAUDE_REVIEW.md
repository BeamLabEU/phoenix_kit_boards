# Claude Review — PR #3

**Title:** Make boards feel live: smooth cursors, visible drags, and a much smaller wire
**Author:** Sasha Don (alexdont)
**Merged:** 2026-08-08 (`4bad16a`)
**Reviewer:** Claude (Anthropic)
**Date:** 2026-08-08
**Scope:** post-merge review of the merged diff, plus the fixes below applied on `main`.

A second review of the same PR sits alongside this one in `phase1.md` (Pincer).
That one is not amended here — its one open question is answered under
"Answered from the other review" below.

---

## Verdict

The PR is sound and the performance work is the real thing: rendering the
canvas once at mount, hoisting embedded images into storage, patching shapes in
place, and moving cursors onto a channel each attack a distinct cost, and the
reasoning in the comments holds up against the code.

Two defects survived it, both in the JS hook, both introduced by this PR's own
changes. Both are fixed here with tests that fail without the fix. Three
smaller items and one pre-existing gate failure are also addressed.

---

## Findings

### BUG - HIGH — a rebuilt shape jumps to the top of the z-stack and stays there

`apply()` used to re-impose the sender's layering whenever a delta carried an
`order`. This PR narrowed that to structural deltas:

```js
const structural = created.length > 0 || deleted.length > 0 || delta.reordered;
```

The premise is that an update patches a shape where it stands and so cannot
move it. But the same function's own fallback contradicts that — when
`patchInPlace` declines, the shape is deleted and re-added, and **re-adding
appends**. The shape lands on top of everything else and the order pass that
would have put it back is now gated off, because the delta says nothing about
`created`, `deleted`, or `reordered`.

`patchInPlace` declines on four paths this PR added, all reachable in normal
use:

- the peer removed a `style` key (cleared a fill, dropped a dash)
- the peer removed a `metadata` key
- the shape changed `kind`
- **the viewer's etcher has no `patchShape`** — the compatibility path the PR
  explicitly keeps, where *every* update rebuilds

The last one is the bad case: on an older etcher every peer edit silently
reshuffles the board's layering, one shape at a time, for that viewer only.
Nothing corrects it until someone happens to add or delete a shape.

It also defeats `tell_sender_about_hoisted/3` (`board_live.ex`), which sends
`updated` + `order` together and says in its own comment that the order is
there because "re-adding a shape appends" — the gate discarded exactly the
value that comment exists to justify.

**Fixed.** The decision now comes from what actually happened rather than from
what was sent, which is the only place it can come from: the server has no way
to know which of its updates a given viewer was able to patch.

`priv/static/assets/phoenix_kit_boards.js:475`

```js
let rebuilt = false;
updated.forEach((shape) => {
  if (!this.patchInPlace(layer, shape)) {
    layer.deleteShape(shape.uuid);
    layer.addShape(shape);
    rebuilt = true;
  }
});
...
const structural = created.length > 0 || deleted.length > 0 || rebuilt || delta.reordered;
```

Pinned by three new cases in `test/js/apply_delta_test.js` — a rebuild on an
etcher without `patchShape`, a rebuild forced by a removed style key, and the
negative: two shapes both patched still touch nothing else. The existing
`noPatch` case was updated to expect the order pass, since it now correctly
gets one.

---

### BUG - MEDIUM — leaving a board leaks the socket and an endless rAF loop

`BoardLink` holds its connections in a module-level map that outlives the page,
and nothing closed them. `BoardCursors.destroyed()` cancelled its timers and
its in-flight frame; it did not close the link.

So walking back to the board list (`.link navigate` in the header) left the
WebSocket connected and the channel joined, with the `"cursor"` handler still
closing over the destroyed hook. Every packet from a peer still on that board
then ran `update()` against a hook whose `el` is no longer in the document:
a cursor appended to a detached node, and `startDrawing()` called again — a
`requestAnimationFrame` loop with nothing left to cancel it, since `destroyed`
had already run. One such loop per board opened, for the life of the tab, each
one holding its cursors and its fresco handle live.

Navigating board → board happened to escape it, because `ensure` closes a link
whose topic differs. Board → anywhere else did not.

**Fixed.** Both hooks close the link on teardown (`close` is idempotent, and
they are destroyed together — `#board-cursors` is inside `#board-root`), and
`BoardCursors` drops its fresco handle so a packet racing the close lands
nowhere: `draw()` and `update()` both bail without one.

`priv/static/assets/phoenix_kit_boards.js:257`, `:568`

Pinned by a new teardown case in `test/js/cursor_pointer_test.js`: the channel
and socket are both closed, the link is forgotten, and a packet arriving after
`destroyed()` draws nothing and schedules no frame.

---

### IMPROVEMENT - MEDIUM — the media relay trusted two fields the rest of the module checks

`etcher:media-command` took `uuid` and `action` off the browser and broadcast
both verbatim to every peer without checking they were even strings. Every
other browser-supplied value this PR relays is constrained — `cursor_tool/1`
and `BoardChannel.tool_name/1` bound and pattern-match the tool key,
`movable?/1` checks the drag payload, and the sibling `etcher:media-announce`
handler already guards `is_binary(uuid) and is_boolean(playing)`. The command
path was the one that didn't.

**Fixed** with `when is_binary(uuid) and is_binary(action)`; a malformed
command falls to the `"etcher:" <> _` catch-all and is ignored. Deliberately
not narrowed to a whitelist of actions: the transport vocabulary is etcher's,
and a whitelist here would silently drop a command a later release adds — the
failure mode this module keeps choosing against.

`lib/phoenix_kit_boards/web/board_live.ex:511`

---

### IMPROVEMENT - MEDIUM — the optional socket was undocumented, and the two places describing it disagreed

The ephemeral channel is opt-in and needs one line in the host's `endpoint.ex`.
The README — the only file a host integrator actually reads — did not mention
it, so on every install the channel silently never engages and the whole
feature degrades to the fallback it was written to replace. That is a working
board, which is why it would never be reported as a bug.

Worse, the two places that did document it disagreed on the line:

| Where | Line |
|---|---|
| `CHANGELOG.md` | `websocket: true` |
| `BoardSocket` moduledoc | `websocket: [connect_info: [:peer_data]]` |

`BoardSocket.connect/3` reads no `connect_info` at all — it takes the peer from
the signed token — so `:peer_data` is dead configuration that invites a host to
wonder what it is for.

**Fixed.** A "Optional: the ephemeral socket" section added to the README
(including the `board_socket_path` override), and the moduledoc aligned to
`websocket: true` with a note saying why there is nothing else to declare.

---

### NITPICK — README dependency versions went stale in this PR

`mix.exs` moved to `fresco ~> 0.11` / `etcher ~> 0.11`; the README's
Requirements list still said `~> 0.10`. **Fixed.**

---

### Housekeeping — `mix precommit` was failing before this PR

`mix.lock` carried eight orphaned entries (`ex_ast`, `glob_ex`, `igniter`,
`owl`, `rewrite`, `sourceror`, `spitfire`, `text_diff`) left behind by an
earlier core upgrade. `precommit` runs `deps.unlock --check-unused`, so the gate
could not pass on `main` regardless of this PR. Pruned with
`mix deps.unlock --unused`.

---

## Answered from the other review

`phase1.md` raises as Medium that the server may never set `reordered`, which
would silently break z-order relay for a pure reorder. It does set it:
`diff/2` computes `"reordered" => reordered?(old, new)` over the shapes present
in both lists (`board_live.ex:822`), and `reordered?/2` compares the surviving
uuids in list order. That concern is not a real gap — `test/board_delta_test.exs`
covers it.

The gap in the same area was the *client* half, which is the HIGH finding above.

---

## Considered and deliberately not changed

- **`broadcast` before `save_annotations`.** A failed save leaves peers holding
  an unstored edit with no peer-facing signal. Called out in the PR's own
  comment and correct for a collaborative canvas — making every collaborator
  wait on the disk is the worse trade, and the next successful save corrects
  it. Left as is; it is on record here rather than fixed.
- **Storage orphan when hoisting succeeds and the save then fails.** The file
  exists, the row still points at the `data:` URL. Dedup by checksum means a
  re-hoist reuses it rather than storing a second copy, so this is a small leak
  and not data loss. A cleanup path would need to know which uploads were
  speculative — more machinery than the leak justifies.
- **No cap on base64 decoded at mount.** `migrate_embedded_images/2` decodes
  every embedded `data:` URL on a board into memory before streaming it to
  storage. Only authenticated admins can put them there, and the bytes were
  already in the row being read, so the cap would be belated. Worth revisiting
  if boards ever become writable by less trusted users.
- **The directory name** (`boards-3-live-cursors-drag`) deviates from the
  `{pr_number}-{slug}` convention in `dev_docs/pull_requests/README.md`. Left
  alone rather than renamed out from under the other review file.

---

## Gate

```
mix format          clean
mix precommit       compile --warnings-as-errors ✓  deps.unlock --check-unused ✓
                    hex.audit ✓  format --check-formatted ✓  credo --strict ✓ (0 issues)
                    dialyzer ✓ (0 errors)
mix test            63 tests, 0 failures
node test/js/*.js   3 suites, all passing
```
