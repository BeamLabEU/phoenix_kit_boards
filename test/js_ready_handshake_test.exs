defmodule PhoenixKitBoards.JsReadyHandshakeTest do
  @moduledoc """
  Runs `test/js/ready_handshake_test.js`, which pins the join handshake.

  Anything the LiveView pushes from its connected mount rides the join reply
  and dispatches immediately — which under runtime-hook delivery is hundreds
  of milliseconds before the real hooks' handlers exist. The board rendered
  and saved while cursors, live drags and stored preferences never appeared.

  Shelled out to node so the hooks' `mounted` can be driven directly and the
  ORDER of registrations against the ping can be asserted, and so the check
  lives inside `mix test` without a JS toolchain. Skipped when node isn't on
  PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/ready_handshake_test.js", __DIR__)

  test "handlers are registered before the hooks announce themselves" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping ready handshake checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "ready handshake checks failed:\n\n#{output}"
    end
  end
end
