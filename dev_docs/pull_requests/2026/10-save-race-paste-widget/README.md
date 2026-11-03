# PR #10: Fix the save race; paste to make a board; widget and board robustness

Author: @alexdont · Merged: 2026-11-02 · Merge: `2cd48d8`

[GitHub PR](https://github.com/BeamLabEU/phoenix_kit_boards/pull/10)

The PR moves editor saves to a row-locked delta merge, adds paste-to-create
boards containing text and multiple images, and improves board presence,
viewport restoration and asynchronous link previews. It also announces images
hoisted during mount so peers stop retaining their embedded copies.

The follow-up [GPT review](GPT_REVIEW.md) fixes collaboration ordering and
revision recovery, preview notifications, paste isolation and cancellation,
collection layout, preview task limits and viewport teardown. It strengthens
concurrency coverage using independent PostgreSQL connections.

There is no migration, version bump or package release in the review follow-up.

A second pass, [CLAUDE_REVIEW.md](CLAUDE_REVIEW.md), fixes the component's undeclared
`paste`/`script_nonce` attributes, long notes off the canvas, and a paste queue
left waiting by a refused upload.
