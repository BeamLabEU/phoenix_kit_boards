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

  # Two people deleting the same board from the panel: the second delete used
  # to raise `Ecto.NoResultsError`, inside the HOST's LiveView.
  test "deleting a board somebody else already deleted is an answer, not a raise" do
    {:ok, board} = Boards.create_board(%{"name" => "Twice"})
    assert {:ok, _} = Boards.delete_board(board)
    assert {:error, :not_found} = Boards.delete_board(board)
  end

  test "the full list can leave the canvases out" do
    {:ok, board} = Boards.create_board(%{"name" => "Light"})

    assert %{data: %{}} =
             light = Enum.find(Boards.list_boards(include_data: false), &(&1.uuid == board.uuid))

    assert light.name == "Light"
    assert map_size(light.data) == 0

    full = Enum.find(Boards.list_boards(), &(&1.uuid == board.uuid))
    assert map_size(full.data) > 0
  end
end
