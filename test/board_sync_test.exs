defmodule PhoenixKitBoards.BoardSyncTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.{Socket, Utils}
  alias PhoenixKitBoards.Boards
  alias PhoenixKitBoards.Web.BoardLive

  test "consecutive revisions use only the delta, without reading the database" do
    first = %{"uuid" => "a", "kind" => "rectangle", "geometry" => %{"x" => 1}}
    next = [first, %{"uuid" => "b", "kind" => "circle"}]

    canvas =
      Boards.blank_canvas() |> Boards.put_annotations([first]) |> Boards.put_sync_revision("one")

    socket = %Socket{
      assigns: %{__changed__: %{}, canvas: canvas, annotations: [first], peer_arrivals: %{}},
      private: %{live_temp: %{}}
    }

    delta =
      Boards.diff([first], next) |> Map.merge(%{"base_revision" => "one", "revision" => "two"})

    # No board assign or repo is available: attempting a reload fails here.
    assert {:noreply, socket} = BoardLive.handle_info({:board_delta, delta, nil}, socket)
    assert socket.assigns.annotations == next
    assert Boards.sync_revision(socket.assigns.canvas) == "two"
    assert [["board:apply", %{"created" => [%{"uuid" => "b"}]}]] = Utils.get_push_events(socket)

    socket = %{socket | private: %{live_temp: %{}}}
    assert {:noreply, same} = BoardLive.handle_info({:board_delta, delta, nil}, socket)
    assert same == socket
    assert Utils.get_push_events(same) == []
  end
end
