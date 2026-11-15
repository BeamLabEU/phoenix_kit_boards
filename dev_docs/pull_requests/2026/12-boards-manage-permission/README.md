# PR #12 — Separate user and administrator permissions

**Author:** @timujinne · **Merged:** `4bfa3c8`

The base `boards` key allows user board access, subject to visibility and the
host's authorization hook. `boards.manage` allows the admin pages and all
boards. Enabled modules backfill the new sub-permission once for roles that
already hold `boards`; the `boards_manage_backfilled` setting records success.

Hosts must grant `boards` to users who previously used boards without a key.
Reviews: [GPT](GPT_REVIEW.md), [Claude](CLAUDE_REVIEW.md), [Grok](GROK_REVIEW.md).
