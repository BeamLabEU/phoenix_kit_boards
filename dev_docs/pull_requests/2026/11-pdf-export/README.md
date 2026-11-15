# PR #11 — PDF export and embedded board viewer

**Author:** @alexdont · **Merged:** `3251941`

Adds PDF export to board pages and tile menus, adopts Fresco's media-viewer
navigation, and opens widget boards in an overlay by default. The overlay
frames the authenticated user board route with `embed=1`. Tile exports mount
an off-screen Fresco canvas with Etcher's drawing layer.

Requires Fresco 0.16 and Etcher 0.25; PhoenixKit's compatible floor is 3.6.0.
Hosts that prohibit same-origin frames can use `open={:navigate}`.

Reviews: [GPT](GPT_REVIEW.md), [Claude](CLAUDE_REVIEW.md), [Grok](GROK_REVIEW.md).
