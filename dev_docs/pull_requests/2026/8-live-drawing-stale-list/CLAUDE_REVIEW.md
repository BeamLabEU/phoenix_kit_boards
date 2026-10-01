# Claude review — PR #8

Overall: sound design. Telling a delete from stale ignorance by age is the right
call given the whole-list wire format, the draft sanitiser is tight, and
dropping pushes while the socket is down fixes the replay-on-reconnect symptom
at its source. Three defects found; all fixed post-merge.

## BUG - HIGH: restored shapes were acknowledged by the merge

`etcher:annotations-changed` called `acknowledge_arrivals/2` with the list
*after* `merge_restored/3`. The restored uuids are in that list only because the
server put them there, so the first stale list removed their protection. The
scenario the PR exists for — a phone socket that stalled and flushes several
lists queued before the peer's shape arrived — restored the shape on the first
list and deleted it on the second.

**Fix:** acknowledge from the sender's own list, before merging. Protection now
lasts the full `@peer_grace_ms` as the comments in the PR describe.

## BUG - HIGH: sender not told when the corrected diff is empty

`tell_sender_about_restored/3` ran only in the non-empty branch. A stale list
that differs from the board *only* by the missing shape (the common case, and
the test's own "nothing to tell anyone") — or a user deleting a peer's brand-new
shape — returned `{:noreply, socket}`: the board kept the shape, the sender's
canvas showed it deleted, and the two disagreed until their next edit.

**Fix:** the empty-delta branch now pushes `board:apply` to the sender too.
Tests: `stale_list_test.exs` "the annotations handler, end to end".

## BUG - MEDIUM: ghost strokes were never retired on a missed `drawn`

Etcher ghosts are absent from `getShapes()`, so nothing but `applyDrawingEnd`
removes them. `drawn` is dropped when the sender's line is down at pen-up (the
new `joined`/`isConnected` guard) and never sent if they close the tab
mid-stroke, leaving a permanent line on peers' screens until reload.

**Fix:** per-sender watchdog (`GHOST_TTL_MS`, 4 s of silence) in `BoardSync`.

## NITPICK

- Seeding `peer_arrivals` with the whole board at mount means a genuine delete
  within 5 s of joining is put back. Accepted: it is what protects the
  reconnect case, and costs one repeat delete.
- `sanitize_draft/1` relays `geometry` and `style` maps unbounded. They are
  only ever read key-by-key by etcher, so not exploitable, but a size cap would
  match the "short, shaped like a key" treatment `kind` gets.
- `version/0` was `0.4.4` against `@version` `0.4.5` — fixed in the 0.4.6 bump.
- `AGENTS.md` still listed fresco/etcher `~> 0.11` — updated.
