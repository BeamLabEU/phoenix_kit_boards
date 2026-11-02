defmodule PhoenixKitBoards.JsPanelPasteTest do
  @moduledoc """
  Runs `test/js/panel_paste_test.js`, which pins when the boards widget listens
  to a paste (only itself, never a field inside it, never when switched off)
  and what it asks the server for.

  Shelled out to node, and skipped when node isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/panel_paste_test.js", __DIR__)

  test "the widget listens to paste only when it should" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping panel paste checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "panel paste checks failed:\n\n#{output}"
    end
  end
end
