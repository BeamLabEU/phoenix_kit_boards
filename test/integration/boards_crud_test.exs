defmodule PhoenixKitBoards.Integration.BoardsCrudTest do
  use PhoenixKitBoards.DataCase, async: true

  alias PhoenixKitBoards.Boards

  test "creates, fetches and deletes a board" do
    user = user_fixture()

    assert {:ok, board} = Boards.create_board(%{"name" => "Smoke", "created_by" => user.uuid})
    assert %{name: "Smoke"} = Boards.get_board(board.uuid)
    assert {:ok, _} = Boards.delete_board(board)
    assert Boards.get_board(board.uuid) == nil
  end
end
