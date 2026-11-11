defmodule PhoenixKitBoards.JsReconnectResyncTest do
  @moduledoc """
  Runs `test/js/reconnect_resync_test.js`, which pins what a page tells the
  server when its LiveView reconnects: the board it holds, and which shapes it
  created, changed or deleted since its line dropped. Without that the page
  stayed stale until its next edit, which then wrote peers' work back to the
  old versions.

  Shelled out to node like the other hook checks. Skipped when node isn't on
  PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/reconnect_resync_test.js", __DIR__)

  test "a reconnecting page reports its board and its offline work" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping reconnect resync checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "reconnect resync checks failed:\n\n#{output}"
    end
  end
end
