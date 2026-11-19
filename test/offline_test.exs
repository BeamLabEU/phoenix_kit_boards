defmodule PhoenixKitBoards.OfflineTest do
  @moduledoc """
  Offline boards (`config :phoenix_kit, offline_annotations: true`, core's
  `PhoenixKit.Offline` switch): the markers the disconnected render carries so
  Etcher can rebuild the page with no connection. The worker itself is core's
  (`PhoenixKit.Offline.worker_url/0`), shared with the media viewer.
  """
  # Global application env — not async.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PhoenixKitBoards.Web.BoardLive

  setup do
    previous = Application.fetch_env(:phoenix_kit, :offline_annotations)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :offline_annotations, value)
        :error -> Application.delete_env(:phoenix_kit, :offline_annotations)
      end
    end)
  end

  defp render_spinner do
    rendered_to_string(
      BoardLive.render(%{__changed__: nil, board: nil, gone?: false, embedded?: false})
    )
  end

  describe "the disconnected render (all the browser has offline)" do
    test "marks where the board is rebuilt, and loads the libraries, only with offline on" do
      Application.put_env(:phoenix_kit, :offline_annotations, true)
      html = render_spinner()
      assert html =~ ~s(data-offline-slot="board")
      assert html =~ "etcher-offline-copy"

      Application.delete_env(:phoenix_kit, :offline_annotations)
      html = render_spinner()
      refute html =~ "data-offline-slot"
      refute html =~ "<script"
    end

    test "follows core's switch: only a literal true turns it on" do
      Application.put_env(:phoenix_kit, :offline_annotations, "true")
      refute render_spinner() =~ "data-offline-slot"
    end
  end
end
