defmodule PhoenixKitBoards.LaserMeasureToolsTest do
  # Global application env — not async.
  use ExUnit.Case, async: false

  alias PhoenixKitBoards.Web.BoardLive

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit, :laser_measure) end)
  end

  test "the laser measure is off unless the host turns it on" do
    Application.delete_env(:phoenix_kit, :laser_measure)
    refute :measure in BoardLive.tools()
    assert :dimension in BoardLive.tools()
  end

  test "config :phoenix_kit, laser_measure: true puts it on the board" do
    Application.put_env(:phoenix_kit, :laser_measure, true)
    assert List.last(BoardLive.tools()) == :measure
  end

  test "anything but true leaves it off" do
    Application.put_env(:phoenix_kit, :laser_measure, "yes")
    refute :measure in BoardLive.tools()
  end
end
