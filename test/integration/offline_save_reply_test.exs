defmodule PhoenixKitBoards.Integration.OfflineSaveReplyTest do
  @moduledoc """
  What a save answers. Etcher's offline mode keeps a list on the device until
  the server has stored it, and reads any reply as "stored" — except
  `%{saved: false}`. A failed write has to say so, or the device throws away
  the only copy of work the server never got.
  """
  use PhoenixKitBoards.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias PhoenixKitBoards.{Boards, Quick}
  alias PhoenixKitBoards.Test.BoardHostLive
  alias PhoenixKitBoards.Web.BoardLive

  @endpoint PhoenixKitBoards.Test.Endpoint

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

  describe "the board page" do
    setup do
      previous = Application.fetch_env(:phoenix_kit, :offline_annotations)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, :offline_annotations, value)
          :error -> Application.delete_env(:phoenix_kit, :offline_annotations)
        end
      end)

      user = board_user_fixture()
      {:ok, board} = Quick.create_note({"project", "offline"}, user.uuid, "Kept")
      %{user: user, board: board}
    end

    defp open(board, user) do
      {:ok, _lv, html} =
        live_isolated(build_conn(), BoardHostLive,
          session: %{"user_uuid" => user.uuid, "board_uuid" => board.uuid}
        )

      html
    end

    # One worker per site: the board must name the URL the media viewer
    # registers (core's), or each would keep replacing the other.
    test "with offline on, keys the layer by board and names core's worker", ctx do
      Application.put_env(:phoenix_kit, :offline_annotations, true)
      html = open(ctx.board, ctx.user)

      assert html =~ ~s(data-offline-key="board:#{ctx.board.uuid}")
      assert html =~ ~s(data-offline-sw="#{PhoenixKit.Offline.worker_url()}")
      assert html =~ ~s(data-offline-root="board")
    end

    test "with offline off, the page carries none of it", ctx do
      Application.delete_env(:phoenix_kit, :offline_annotations)
      html = open(ctx.board, ctx.user)

      refute html =~ "data-offline-key"
      refute html =~ "data-offline-sw"
      refute html =~ "data-offline-root"
    end
  end
end
