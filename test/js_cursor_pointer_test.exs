defmodule PhoenixKitBoards.JsCursorPointerTest do
  @moduledoc """
  Runs `test/js/cursor_pointer_test.js`, which pins how a peer's cursor is
  drawn while they present with the red pointer.

  One person is one cursor. While they present that cursor is a red laser dot
  drawn by etcher; the rest of the time it is the arrow with a name tag drawn
  by the board hook. The failure to guard against is showing both — two
  markers in the same place, reading as two people — or getting stuck in one
  state. Stuck is the worse one: a presenter who stops pointing but leaves a
  red dot on everyone's board has no way to clear it.

  Shelled out to node so the transitions can be driven directly instead of
  through a LiveView, and so the check lives inside `mix test` without a JS
  toolchain. Skipped when node isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/cursor_pointer_test.js", __DIR__)

  test "a presenting peer is drawn as a pointer, and only as a pointer" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping board cursor/pointer checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "cursor pointer checks failed:\n\n#{output}"
    end
  end
end
