defmodule PhoenixKitBoards.Integration.SaveRaceTest do
  use PhoenixKitBoards.DataCase, async: false

  alias PhoenixKitBoards.Boards

  setup do
    {:ok, board} = Boards.create_board(%{"name" => "Race", "created_by" => user_fixture().uuid})
    %{board: board}
  end

  defp shape(id, x \\ 0), do: %{"uuid" => id, "kind" => "rectangle", "geometry" => %{"x" => x}}

  defp stored(board),
    do: board.uuid |> Boards.get_board() |> Boards.load_canvas() |> Boards.annotations()

  defp ids(list), do: list |> Enum.map(& &1["uuid"]) |> Enum.sort()

  test "an edit made from a stale list does not erase a peer's saved shape", %{board: board} do
    {:ok, _, _, _, _} = Boards.apply_edit(board, [], [shape("a")])

    # Both editors opened the board holding only "a".
    {:ok, _, _, _, _} = Boards.apply_edit(board, [shape("a")], [shape("a"), shape("peer")])
    {:ok, _, _, merged, _} = Boards.apply_edit(board, [shape("a")], [shape("a"), shape("mine")])

    assert ids(merged) == ["a", "mine", "peer"]
    assert ids(stored(board)) == ["a", "mine", "peer"]
  end

  test "editors saving at the same moment all land", %{board: board} do
    tasks =
      for n <- 1..12 do
        parent = self()

        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(PhoenixKitBoards.Test.Repo, parent, self())
          Boards.apply_edit(board, [], [shape("s#{n}")])
        end)
      end

    assert Enum.all?(Task.await_many(tasks, 15_000), &match?({:ok, _, _, _, _}, &1))
    assert ids(stored(board)) == Enum.sort(for n <- 1..12, do: "s#{n}")
  end

  test "the stored board is what the edit returns", %{board: board} do
    {:ok, canvas, saved, merged, delta} = Boards.apply_edit(board, [], [shape("a")])

    assert Boards.annotations(canvas) == merged
    assert saved.preview["count"] == 1
    assert [%{"uuid" => "a"}] = delta["created"]
  end

  test "a board deleted underneath an edit reports it instead of crashing", %{board: board} do
    {:ok, _} = Boards.delete_board(board)
    assert {:error, :not_found} = Boards.apply_edit(board, [], [shape("a")])
  end
end
