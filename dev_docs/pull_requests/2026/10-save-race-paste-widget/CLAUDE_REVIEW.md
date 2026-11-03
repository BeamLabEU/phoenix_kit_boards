# Claude review — PR #10

Reviewer: Claude (Anthropic) · 2026-11-03
Author: @alexdont · Merge: `2cd48d8` · Reviewed at `c75e030` (after GPT's
follow-up), so this covers what that pass left.

Overall: the save path is now right. I re-derived the claim the revision chain
depends on, `apply_delta(stored, diff(stored, merged)) == merged`, for both the
`reordered: false` path (`place_created/3` re-inserts each new shape before its
next known neighbour) and the explicit-reorder path (`impose_order/2` names
every shape). It holds, so a peer whose revision matches `base_revision` ends
up exactly on the stored list, and anything else falls back to a reload of the
committed row. The client-side unfurl pairing, the paste queue and the
view-restore teardown are sound. The defects that remain are in the
quick-capture surface this PR grew: one in the public component API and two in
what a paste produces. All are fixed.

## BUG - MEDIUM: `paste` and `script_nonce` are not declared on the component

The moduledoc and the README tell a host to write
`<PhoenixKitBoards.Web.Components.boards_panel ... paste={false} />`, and a
host with a CSP to pass `script_nonce`. `boards_panel/1` declares its
attributes with `attr/3`, but this PR added neither of those two. Phoenix
warns on an undeclared attribute **in the host's template**:

```
warning: undefined attribute "paste" for component PhoenixKitBoards.Web.Components.boards_panel/1
warning: undefined attribute "script_nonce" for component PhoenixKitBoards.Web.Components.boards_panel/1
```

(reproduced by compiling such a template). A host building with
`--warnings-as-errors`, which is every repo in this umbrella (`mix precommit`),
fails to compile as soon as it follows the docs. At runtime the value still
arrives, which is why the suite never noticed: `Test.HostLive` passes its
options as a dynamic `{Map.new(@opts)}`, and dynamic attributes are not
checked.

**Fix:** declare both. The new test `components_attrs_test.exs` reads the
`## Attributes` list from `BoardsPanel`'s moduledoc and requires every entry to
be declared on the component, so the two lists cannot drift apart again.

## BUG - MEDIUM: a long note on its own board runs off the canvas

GPT fixed this for a note *above pictures* (`fit_note/2` in `layout/2`). The
plain note never goes through `layout/2`. That covers the **Text** tile, and
also every text-only paste, since `create_collection(_, _, [], text)` hands off
to `create_note/4`. `note_shape/1` placed text at the full 300-unit font, which
fits 19 lines on the 8000-unit canvas. A 40-line note (the cap) spanned y=−4100
to y=12100 and was centred on a canvas it overflowed at both ends. Pasting a
paragraph made this the common case.

Related, from PR #9's wrapping: `wrap_line/1` counted **bytes** while the box
width counts characters. Cyrillic text wrapped at 21 characters instead of 40,
so it hit the 40-line cap after about half as much text.

**Fix:** `note_shape/1` fits the note to the canvas minus the margin and
centres it. `fit_note/2` now scales from the shape's current font size, so the
second fit in `layout/2` composes correctly with the first. Wrapping measures
`String.length/1`. Tests in `quick_layout_test.exs`: a long note alone stays
inside the canvas and centred, a short note keeps the full font size, and
non-ASCII text wraps at the same width as ASCII.

## BUG - LOW: a refused image paste leaves the paste queue waiting forever

When the host withdrew `:create` while files were uploading, `make_image_board`
refused without consuming the entries ("dropped with the upload"). They were
not dropped. They stayed on the upload as done entries, so:

- the file input kept rendering `data-phx-active-refs`, which is exactly what
  the paste hook's `uploading()` reads. Every later image paste queued behind
  them indefinitely;
- the new-board tile, the only place their cancel buttons render, is hidden
  once `can_create?` is false, so the person could not clear them;
- had access come back, the next board made here would have included those
  files.

**Fix:** cancel the entries on refusal (shared with `reset_context/2` as
`cancel_image_entries/1`). Test: `boards_panel_test.exs` "an image refused at
the end is dropped, not left on the upload" checks that no active refs remain.

## Not changed, on record

- **A client unfurl timeout does not free the server's slot.** After 25 s the
  client gives up, but the task keeps its `@max_unfurls` slot until
  `LinkPreview`'s own budget ends it. That budget is shorter than the client's
  timeout, so the slot is freed shortly after. This is intended.
- **A sender that folded in a peer's edit reloads when that peer's message
  arrives**, because the message's `base_revision` is now behind. The result is
  correct, at the cost of one full read of the row in that race. Avoiding it
  would mean keeping a revision history, which is not worth it.
- **Legacy tokenless `board_delta` senders force a reload**, as GPT recorded.
  This only applies during a rolling deploy.

## Validation

Committed together with the [PR #9 review](../9-scoped-boards-panel/CLAUDE_REVIEW.md); see that file for the run details.
In short: 372 tests, 0 failures, 0 excluded, on a disposable PostgreSQL 18.6
(`postgres-test` was in recovery). Every new regression test fails against the
pre-fix `lib/`. `mix precommit` is clean. No version, changelog, tag or schema
change.
