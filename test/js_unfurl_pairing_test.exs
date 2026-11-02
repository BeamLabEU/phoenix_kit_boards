defmodule PhoenixKitBoards.JsUnfurlPairingTest do
  @moduledoc """
  Runs `test/js/unfurl_pairing_test.js`, which pins how a pasted link's preview
  is asked for and answered as two events paired by `ref`, so the server can
  fetch the page without holding the board.

  Shelled out to node, and skipped when node isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/unfurl_pairing_test.js", __DIR__)

  test "a link preview is paired with its paste by ref" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping unfurl pairing checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "unfurl pairing checks failed:\n\n#{output}"
    end
  end
end
