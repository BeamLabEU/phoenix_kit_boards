# PR #13 — Keep the paste hint's place so the first click on an empty boards panel is not lost

**Author:** timujinne · **Reviewer:** Claude · **Verdict:** approve as is

Merged into `main` as 679294c. It merged cleanly.

The hint under the new-board tile switched from `hidden` → `group-focus-within/panel:block` to `invisible` →
`group-focus-within/panel:visible`. It now reserves its line all the time, so focusing the panel on mousedown no
longer moves the centred buttons before mouseup, and the first click on an empty panel reaches its `phx-click`.

Checked and fine:
- **Other `focus-within` styles in the panel.** The tile border colour and a card's z-index don't change layout.
- **`paste: false`.** The `:if={@paste?}` still removes the hint and its line completely, and a test pins that.
- **Accessibility.** `visibility: hidden` keeps the hint out of the accessibility tree while it isn't shown, as
  `display: none` did.

## Findings

None. The tests can only pin the classes, because a LiveView test can't see layout; the PR says so.
