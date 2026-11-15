# PR #13 — Preserve the paste hint's layout space

**Author:** @timujinne · **Merged:** `679294c`

Uses `invisible`/`visible` for the focused widget's paste hint so its first
mousedown does not move the new-board buttons before mouseup. Paste-disabled
widgets still omit the hint entirely.

Reviews: [GPT](GPT_REVIEW.md), [Claude](CLAUDE_REVIEW.md).
