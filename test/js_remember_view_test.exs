defmodule PhoenixKitBoards.JsRememberViewTest do
  @moduledoc """
  Runs `test/js/remember_view_test.js`, which pins how a board remembers where
  its viewer was looking: restored before it is watched, kept per board, saved
  on close, and never broken by missing or garbage storage.

  Shelled out to node, and skipped when node isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/remember_view_test.js", __DIR__)

  test "a board reopens where its viewer left it" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping remember view checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "remember view checks failed:\n\n#{output}"
    end
  end
end
