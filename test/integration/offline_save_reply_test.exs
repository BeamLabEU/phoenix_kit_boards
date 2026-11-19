defmodule PhoenixKitBoards.Integration.OfflineSaveReplyTest do
  @moduledoc """
  What a save answers. Etcher's offline mode keeps a list on the device until
  the server has stored it, and reads any reply as "stored" — except
  `%{saved: false}`. A failed write has to say so, or the device throws away
  the only copy of work the server never got.
  """
  use PhoenixKitBoards.DataCase, async: false

  alias Phoenix.LiveView.Socket
  alias PhoenixKitBoards.Boards
  alias PhoenixKitBoards.Web.BoardLive

  defp socket_for(board) do
    %Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        board: board,
        annotations: [],
        peer_arrivals: %{},
        topic: "phoenix_kit_boards:" <> board.uuid
      }
    }
  end

  defp shape(uuid), do: %{"uuid" => uuid, "kind" => "rectangle", "geometry" => %{"x" => 1}}

  test "a stored save answers nothing special" do
    {:ok, board} = Boards.create_board(%{"name" => "Saves"})

    assert {:noreply, socket} =
             BoardLive.handle_event(
               "etcher:annotations-changed",
               %{"annotations" => [shape("a")]},
               socket_for(board)
             )

    assert [%{"uuid" => "a"}] = socket.assigns.annotations
  end

  test "a save that could not be stored answers saved: false" do
    {:ok, board} = Boards.create_board(%{"name" => "Gone"})
    socket = socket_for(board)
    # Deleted while it was open: the write has no row to land on.
    {:ok, _} = Boards.delete_board(board)

    assert {:reply, %{saved: false}, socket} =
             BoardLive.handle_event(
               "etcher:annotations-changed",
               %{"annotations" => [shape("a")]},
               socket
             )

    assert Phoenix.Flash.get(socket.assigns.flash, :error) == "Could not save the board."
  end
end
