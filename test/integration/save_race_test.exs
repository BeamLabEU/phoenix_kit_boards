defmodule PhoenixKitBoards.Integration.SaveRaceTest do
  use PhoenixKitBoards.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
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
          Sandbox.allow(Repo, parent, self())
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
    assert delta["base_revision"] == nil
    assert is_binary(delta["revision"])
    assert Boards.sync_revision(Boards.load_canvas(saved)) == delta["revision"]

    {:ok, next, _, _, next_delta} = Boards.apply_edit(board, merged, merged ++ [shape("b")])
    assert next_delta["base_revision"] == delta["revision"]
    assert next_delta["revision"] != delta["revision"]
    assert Boards.sync_revision(next) == next_delta["revision"]
  end

  test "concurrent transactions on separate connections preserve every edit" do
    # Sandbox allowances share a connection and serialize queries themselves.
    # A committed, disposable board lets independent transactions contend for
    # the real PostgreSQL row lock. It deliberately has no user or folders.
    {:ok, board} =
      Sandbox.unboxed_run(Repo, fn ->
        Boards.create_board(%{"name" => "Lock test"}, folder: :root)
      end)

    try do
      parent = self()

      tasks =
        for n <- 1..4 do
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              Repo.transaction(fn ->
                [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
                send(parent, {:ready_to_edit, self(), backend})

                receive do
                  :edit -> Boards.apply_edit(board, [], [shape("independent#{n}")])
                after
                  5_000 -> raise "concurrent save barrier timed out"
                end
              end)
            end)
          end)
        end

      backends =
        for _ <- tasks do
          assert_receive {:ready_to_edit, pid, backend}, 5_000
          {pid, backend}
        end

      assert backends |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 4
      Enum.each(backends, fn {pid, _} -> send(pid, :edit) end)
      assert Enum.all?(Task.await_many(tasks, 10_000), &match?({:ok, {:ok, _, _, _, _}}, &1))

      assert Sandbox.unboxed_run(Repo, fn -> ids(stored(board)) end) ==
               Enum.sort(for n <- 1..4, do: "independent#{n}")
    after
      Sandbox.unboxed_run(Repo, fn -> Boards.delete_board(board) end)
    end
  end

  test "a board deleted underneath an edit reports it instead of crashing", %{board: board} do
    {:ok, _} = Boards.delete_board(board)
    assert {:error, :not_found} = Boards.apply_edit(board, [], [shape("a")])
  end

  test "the returned delta describes the stored change and its authoritative order", %{
    board: board
  } do
    base = [shape("a"), shape("b")]
    {:ok, _, _, _, _} = Boards.apply_edit(board, [], Enum.reverse(base))
    {:ok, _, _, merged, delta} = Boards.apply_edit(board, base, base ++ [shape("new")])

    assert merged == [shape("b"), shape("a"), shape("new")]
    assert delta["order"] == ["b", "a", "new"]
    assert Boards.apply_delta(Enum.reverse(base), delta) == merged
  end

  test "returning a preview to a stale caller's value still announces the change", %{board: board} do
    {:ok, _, stale, _, _} = Boards.apply_edit(board, [], [shape("a")])
    {:ok, _, _, _, _} = Boards.apply_edit(board, [shape("a")], [])
    Boards.subscribe_scope(nil)

    {:ok, _, _, _, _} = Boards.apply_edit(stale, [], [shape("a")])

    assert_receive {:boards_scope_changed, uuid}
    assert uuid == board.uuid
  end
end
