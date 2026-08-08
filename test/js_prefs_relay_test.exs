defmodule PhoenixKitBoards.JsPrefsRelayTest do
  @moduledoc """
  Runs `test/js/prefs_relay_test.js`, which pins the host half of the
  preferences contract: carrying them between etcher and the server.

  Etcher emits every preference as a DOM event when any of them changes, and
  takes the whole set back through `setPrefs`. Everything between those two
  points belongs to the host — here, a user's custom_fields — and etcher knows
  nothing about it. Another host storing them in a cookie or a per-board row
  satisfies the same contract.

  Two failure modes are worth the coverage. The stored set arrives with the
  mount reply, which can beat etcher's own setup because it lazy-loads its
  script; dropping it there leaves the board on its defaults. And an empty set
  has to mean "nothing stored" rather than "everything off", or a first-time
  user gets a board with no tools on it.

  Shelled out to node so the hook can be driven directly. Skipped when node
  isn't on PATH.
  """
  use ExUnit.Case, async: true

  @script Path.expand("js/prefs_relay_test.js", __DIR__)

  test "preferences reach the server and come back to the layer" do
    case System.find_executable("node") do
      nil ->
        IO.puts("\n[skip] node not found — skipping preferences relay checks")
        assert true

      node ->
        {output, status} = System.cmd(node, [@script], stderr_to_stdout: true)
        assert status == 0, "preferences relay checks failed:\n\n#{output}"
    end
  end
end
