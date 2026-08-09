defmodule PhoenixKitBoards.JsRuntimeHookTest do
  @moduledoc """
  Runs `test/js/runtime_hook_test.js`, which pins the shim that delivers this
  module's hooks without the host wiring anything.

  LiveView asks for a hook definition *synchronously* when an element mounts,
  so the shim must hand one back before the bundle can have loaded and forward
  to the real hook afterwards. The ordering is the risk: an element can be
  gone before the bundle lands, and then `mounted` would attach listeners and
  timers nothing will ever tear down.

  Shelled out to node so the shim can be driven against a stand-in browser,
  and so the check lives inside `mix test` without a JS toolchain. The script
  it evaluates is generated from Elixir rather than restated, so a copy cannot
  drift from what ships. Skipped when node isn't on PATH.
  """
  use ExUnit.Case, async: false

  @script Path.expand("js/runtime_hook_test.js", __DIR__)

  @tag timeout: 120_000
  test "the shim resolves immediately and forwards once the bundle lands" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping runtime hook checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "runtime hook checks failed:\n\n#{output}"
    end
  end
end
