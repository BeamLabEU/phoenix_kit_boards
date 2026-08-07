defmodule PhoenixKitBoards.JsApplyDeltaTest do
  @moduledoc """
  Runs `test/js/apply_delta_test.js`, which pins how a peer's edit is applied.

  The board used to delete and re-add every changed shape, which rebuilds the
  element and — because re-adding appends — forced the layering to be
  re-imposed over every shape afterwards. Watching someone drag one thing
  flashed the whole board. A changed shape is now patched in place, and the
  order is only re-imposed when it can actually have moved.

  Shelled out to node so the apply path can be driven directly against a
  recording stand-in for the etcher layer, and so the check lives inside
  `mix test` without a JS toolchain. Skipped when node isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/apply_delta_test.js", __DIR__)

  test "a peer's edit is patched in place, and only rebuilt when it must be" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping board apply-delta checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "apply delta checks failed:\n\n#{output}"
    end
  end
end
