# PR #14 — Opt-in laser measure

**Author:** @alexdont · **Merged:** `2506181`

Adds Etcher's laser measurement tool only when the host configures
`config :phoenix_kit, laser_measure: true`. The widget's frame delegates
Bluetooth only while that switch is enabled. PhoenixKit 3.6.0 resolves the
Etcher 0.26 JavaScript required by the tool.

Reviews: [GPT](GPT_REVIEW.md), [Claude](CLAUDE_REVIEW.md).
