defmodule PhoenixKitBoards.JsLiveDrawingTest do
  use ExUnit.Case, async: true

  @script Path.expand("js/live_drawing_test.js", __DIR__)

  test "ephemeral reconnects and ghost stroke lifecycle" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping live drawing checks")

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "live drawing checks failed:\n\n#{output}"
    end
  end
end
