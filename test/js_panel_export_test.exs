defmodule PhoenixKitBoards.JsPanelExportTest do
  @moduledoc """
  Runs `test/js/panel_export_test.js`, which pins how a tile's "Export as PDF" waits for the
  off-screen board, runs the export and always reports back so the copy
  is taken down.

  Shelled out to node, and skipped when node isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/panel_export_test.js", __DIR__)

  test "a tile exports its board and always reports back" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping panel export checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "panel export checks failed:\n\n#{output}"
    end
  end
end
