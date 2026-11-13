# PR #14 — Boards: Etcher 0.26 laser measure, opt-in; the overlay may use Bluetooth

**Author:** alexdont · **Reviewer:** Claude · **Verdict:** approve; one follow-up applied

Merged into `main` as 2506181. It merged cleanly.

`BoardLive.tools/0` adds `:measure` when `config :phoenix_kit, laser_measure: true` (a literal `true`). That is the
same switch core's `MediaCanvasViewer.laser_measure_tools/0` reads (phoenix_kit #1032). The value is read at mount,
not compile time. The etcher requirement stays `~> 0.25`, which already admits 0.26, and an older Etcher ignores the
unknown tool name.

Checked and fine:
- **Test isolation.** The switch is application env, global to the VM, and the PR's tests are in an `async: false`
  module. Core's first version of #1032 got this wrong.
- **Permissions-Policy.** Core sets no `Permissions-Policy` header, so the top-level page doesn't block Bluetooth. A
  host that sets its own header has to allow `bluetooth` itself.

## Release ordering

The board page needs Etcher 0.26's JavaScript, and core serves it at the version core resolves. Core `main` carries
etcher 0.26 (#1032), but the latest core on Hex (3.5.0) does not. Boards `main` also already needs unpublished core
for another reason: since #11, `fresco >= 0.16` conflicts with core 3.5.0's `fresco ~> 0.15.0`, and
`mix deps.get` against the Hex pin fails. **Do not publish boards before core.** The suite here ran with
`PHOENIX_KIT_PATH=../phoenix_kit`.

## Findings

### IMPROVEMENT - MEDIUM — The overlay frame was given Bluetooth on every site (fixed)

`BoardsPanel`'s overlay `<iframe>` got `bluetooth` in `allow=` unconditionally. Every host, including the large
majority that never turn the measure on, delegated Web Bluetooth to the frame. The frame is the board page, which
only needs Bluetooth for the measure.

Fix: `BoardsPanel.frame_allow/0` adds `; bluetooth` only while `BoardLive.laser_measure?/0` is true.
`laser_measure?/0` is now the single reading of the switch, and `tools/0` uses it too. The panel's overlay test now
asserts that the default frame has no `bluetooth`. `LaserMeasureToolsTest` (async: false) asserts it appears with
the switch on, and not for `"true"`.

### NITPICK — The tests' `on_exit` deleted the switch instead of restoring it (fixed)

`Application.delete_env/2` in `on_exit` would wipe a value set in `config/test.exs`. The test now restores the
previous value, as core's test does.
