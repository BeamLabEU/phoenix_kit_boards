defmodule PhoenixKitBoards.LaserMeasureToolsTest do
  # Global application env — not async.
  use ExUnit.Case, async: false

  alias PhoenixKitBoards.Web.{BoardLive, BoardsPanel}

  setup do
    previous = Application.fetch_env(:phoenix_kit, :laser_measure)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :laser_measure, value)
        :error -> Application.delete_env(:phoenix_kit, :laser_measure)
      end
    end)
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

  # A frame may use Web Bluetooth only when its parent delegates it. The
  # widget's overlay delegates it only while the measure is on.
  test "the overlay frame gets Bluetooth only with the measure on" do
    Application.delete_env(:phoenix_kit, :laser_measure)
    refute BoardsPanel.frame_allow() =~ "bluetooth"

    Application.put_env(:phoenix_kit, :laser_measure, "true")
    refute BoardsPanel.frame_allow() =~ "bluetooth"

    Application.put_env(:phoenix_kit, :laser_measure, true)
    assert BoardsPanel.frame_allow() == "fullscreen; clipboard-read; clipboard-write; bluetooth"
  end
end
