defmodule PhoenixKitBoards.Integration.ScopeTest do
  use PhoenixKitBoards.DataCase, async: true

  alias PhoenixKitBoards.{Board, Boards}

  @scope {"project", "alpha"}

  defp board!(user, name, attrs \\ %{}) do
    base = %{
      "name" => name,
      "created_by" => user.uuid,
      "scope_type" => "project",
      "scope_id" => "alpha"
    }

    {:ok, board} = Boards.create_board(Map.merge(base, attrs))
    board
  end

  defp names(boards), do: Enum.map(boards, & &1.name)

  describe "changeset" do
    test "a scope is both halves or neither" do
      refute Board.changeset(%Board{}, %{"name" => "x", "scope_type" => "project"}).valid?
      refute Board.changeset(%Board{}, %{"name" => "x", "scope_id" => "alpha"}).valid?
      assert Board.changeset(%Board{}, %{"name" => "x"}).valid?

      assert Board.changeset(%Board{}, %{
               "name" => "x",
               "scope_type" => "project",
               "scope_id" => "a"
             }).valid?
    end

    test "scope_type is a plain lowercase key" do
      refute Board.changeset(%Board{}, %{
               "name" => "x",
               "scope_type" => "My Project",
               "scope_id" => "a"
             }).valid?
    end

    test "visibility and kind take only known values" do
      refute Board.changeset(%Board{}, %{"name" => "x", "visibility" => "public"}).valid?
      refute Board.changeset(%Board{}, %{"name" => "x", "kind" => "weird"}).valid?
    end
  end

  describe "list_for_scope/3" do
    test "metadata-only reads keep previews without loading the canvas" do
      user = user_fixture()
      {:ok, board} = PhoenixKitBoards.Quick.create_note(@scope, user.uuid, "Preview only")

      assert [listed] = Boards.list_for_scope(@scope, user.uuid, include_data: false)
      assert listed.data == %{}
      assert listed.preview["text"] == "Preview only"
      assert Boards.get_board(board.uuid, include_data: false).data == %{}
      assert Boards.get_board(board.uuid).data == board.data
      assert hd(Boards.list_for_scope(@scope, user.uuid)).data == board.data
    end

    test "lists only the place's boards" do
      u = user_fixture()
      board!(u, "here")
      board!(u, "elsewhere", %{"scope_id" => "beta"})
      {:ok, _} = Boards.create_board(%{"name" => "unscoped", "created_by" => u.uuid})

      assert names(Boards.list_for_scope(@scope, u.uuid)) == ["here"]
      assert names(Boards.list_for_scope(nil, u.uuid)) == ["unscoped"]
    end

    test "one user cannot see another's private board in the same place" do
      a = user_fixture()
      b = user_fixture()
      board!(a, "shared one")
      board!(a, "a private", %{"visibility" => "private"})

      assert Enum.sort(names(Boards.list_for_scope(@scope, a.uuid))) == [
               "a private",
               "shared one"
             ]

      assert names(Boards.list_for_scope(@scope, b.uuid)) == ["shared one"]
      assert names(Boards.list_for_scope(@scope, nil)) == ["shared one"]
    end

    test "pinned boards come first, then the most recently changed" do
      u = user_fixture()
      old = board!(u, "old")
      board!(u, "new")
      {:ok, _} = Boards.pin(old, u.uuid)

      assert names(Boards.list_for_scope(@scope, u.uuid)) == ["old", "new"]
      {:ok, _} = Boards.unpin(Boards.get_board(old.uuid), u.uuid)
      assert hd(names(Boards.list_for_scope(@scope, u.uuid))) in ["old", "new"]
    end

    test "archived boards are hidden unless asked for" do
      u = user_fixture()
      keep = board!(u, "keep")
      gone = board!(u, "gone")
      {:ok, _} = Boards.archive(gone, u.uuid)

      assert names(Boards.list_for_scope(@scope, u.uuid)) == ["keep"]
      assert "gone" in names(Boards.list_for_scope(@scope, u.uuid, include_archived: true))
      assert Boards.count_for_scope(@scope, u.uuid) == 1

      {:ok, _} = Boards.unarchive(Boards.get_board(gone.uuid), u.uuid)
      assert Boards.count_for_scope(@scope, u.uuid) == 2
      assert keep.uuid
    end

    test "search matches names without treating % and _ as wildcards" do
      u = user_fixture()
      board!(u, "Sprint notes")
      board!(u, "100% done")
      board!(u, "plain")

      assert names(Boards.list_for_scope(@scope, u.uuid, search: "sprint")) == ["Sprint notes"]
      assert names(Boards.list_for_scope(@scope, u.uuid, search: "%")) == ["100% done"]
      assert names(Boards.list_for_scope(@scope, u.uuid, search: "_")) == []
    end

    test "limit caps the list" do
      u = user_fixture()
      for n <- 1..3, do: board!(u, "b#{n}")
      assert length(Boards.list_for_scope(@scope, u.uuid, limit: 2)) == 2
    end
  end

  describe "who may change what" do
    test "only the creator changes visibility or archives" do
      a = user_fixture()
      b = user_fixture()
      board = board!(a, "mine")

      assert {:error, :forbidden} = Boards.set_visibility(board, "private", b.uuid)
      assert {:error, :forbidden} = Boards.archive(board, b.uuid)
      assert {:ok, %{visibility: "private"}} = Boards.set_visibility(board, "private", a.uuid)
    end

    test "an unknown visibility is refused" do
      a = user_fixture()
      assert {:error, %Ecto.Changeset{}} = Boards.set_visibility(board!(a, "x"), "public", a.uuid)
    end

    test "nobody pins a private board they cannot see" do
      a = user_fixture()
      b = user_fixture()
      board = board!(a, "secret", %{"visibility" => "private"})
      assert {:error, :forbidden} = Boards.pin(board, b.uuid)
      assert {:ok, _} = Boards.pin(board, a.uuid)
    end
  end

  test "visible_to?/2 and scope_of/1" do
    u = user_fixture()
    shared = board!(u, "s")
    private = board!(u, "p", %{"visibility" => "private"})

    assert Boards.visible_to?(shared, nil)
    assert Boards.visible_to?(private, u.uuid)
    refute Boards.visible_to?(private, Ecto.UUID.generate())
    refute Boards.visible_to?(private, nil)
    assert Boards.scope_of(shared) == @scope
    assert Boards.scope_of(%Board{}) == nil
  end
end
