defmodule PhoenixKitBoards.JsPanelViewerTest do
  use ExUnit.Case, async: true

  @script Path.expand("js/panel_viewer_test.js", __DIR__)

  test "Escape closes the embedded board only after the editor has finished with it" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping panel viewer checks")

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "panel viewer checks failed:\n\n#{output}"
    end
  end
end
