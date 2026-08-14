defmodule PhoenixKitBoards.JsUploadWatchdogTest do
  @moduledoc """
  Runs `test/js/upload_watchdog_test.js`.

  Once the bytes have arrived the LiveView still has to hash them and write
  them to storage — one blocking call, no further progress. The watchdog is
  15 s of silence, so a video at the 256 MB cap used to trip it and get
  embedded. Progress 100 now means "storing" and must rearm for the long
  budget.

  Shelled out to node so the hook can be driven directly. Skipped when node
  isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/upload_watchdog_test.js", __DIR__)

  test "100% progress rearms the store budget, not the transfer silence" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping upload watchdog checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "upload watchdog checks failed:\n\n#{output}"
    end
  end
end
