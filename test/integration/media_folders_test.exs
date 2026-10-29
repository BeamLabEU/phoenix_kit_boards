defmodule PhoenixKitBoards.Integration.MediaFoldersTest do
  # Not async: the module folder and the hook config are global.
  use PhoenixKitBoards.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitBoards.{Boards, MediaFolders}

  defmodule Hooks do
    def parent(:board, _actor, %{label: label}) do
      send(self(), {:parent_hook, label})
      {:ok, Process.get(:hook_parent)}
    end

    def name(board, _actor), do: {:ok, "Hooked " <> board.name}
    def broken_parent(_kind, _actor, _subject), do: raise("nope")
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_boards, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_boards, :attachments_folder_name)
    end)

    %{user: user_fixture()}
  end

  defp board!(user, name, attrs \\ %{}, opts \\ []) do
    base = %{
      "name" => name,
      "created_by" => user.uuid,
      "scope_type" => "project",
      "scope_id" => "alpha"
    }

    {:ok, board} = Boards.create_board(Map.merge(base, attrs), opts)
    board
  end

  defp folder!(uuid), do: Repo.get!(Folder, uuid)

  defp parent_name(board), do: folder!(board.folder_parent_uuid).name

  describe "the default layout: Boards / <place> / <board>" do
    test "a scoped board's folder goes in a folder named after its place", %{user: u} do
      board = board!(u, "Roadmap", %{}, label: "Alpha Co")

      assert parent_name(board) == "Alpha Co"
      assert folder!(folder!(board.folder_parent_uuid).parent_uuid).name == "Boards"

      assert {:ok, folder} = MediaFolders.ensure_folder(board, u.uuid)
      assert folder.name == "Roadmap"
      assert folder.parent_uuid == board.folder_parent_uuid
      assert Boards.get_board(board.uuid).folder_uuid == folder.uuid
    end

    test "boards with no place go straight under Boards", %{user: u} do
      board = board!(u, "Loose", %{"scope_type" => nil, "scope_id" => nil})
      assert parent_name(board) == "Boards"
    end

    test "creating a board makes no folder of its own", %{user: u} do
      board = board!(u, "Empty", %{}, label: "Alpha Co")
      assert board.folder_uuid == nil
      assert MediaFolders.board_folder(board) == nil
    end

    test "a place without a label is named after its scope", %{user: u} do
      assert parent_name(board!(u, "x")) == "project alpha"
    end

    test "boards of one place share its folder; places never share", %{user: u} do
      a1 = board!(u, "One", %{}, label: "Website")
      a2 = board!(u, "Two", %{}, label: "Website")
      b = board!(u, "Three", %{"scope_id" => "beta"}, label: "Website")

      assert a1.folder_parent_uuid == a2.folder_parent_uuid
      refute a1.folder_parent_uuid == b.folder_parent_uuid
      assert parent_name(b) =~ ~r/^Website · [0-9a-f]{6}$/
    end

    test "renaming the place's folder later keeps the files together", %{user: u} do
      first = board!(u, "One", %{}, label: "Old name")
      {:ok, _} = Storage.update_folder(folder!(first.folder_parent_uuid), %{name: "Renamed"})
      second = board!(u, "Two", %{}, label: "Old name")

      assert second.folder_parent_uuid == first.folder_parent_uuid
    end
  end

  describe "explicit folder" do
    test "{:under, uuid}", %{user: u} do
      {:ok, target} = Storage.create_folder(%{name: "Mine", user_uuid: u.uuid})
      board = board!(u, "B", %{}, folder: {:under, target.uuid})
      assert board.folder_parent_uuid == target.uuid
      assert {:ok, folder} = MediaFolders.ensure_folder(board, u.uuid)
      assert folder.parent_uuid == target.uuid
    end

    test "{:under, uuid} that is gone falls back to the default", %{user: u} do
      board = board!(u, "B", %{}, folder: {:under, Ecto.UUID.generate()}, label: "Fallback")
      assert parent_name(board) == "Fallback"
    end

    test "{:path, names} creates the chain from the root", %{user: u} do
      board = board!(u, "B", %{}, folder: {:path, ["Clients", "Acme"]})
      acme = folder!(board.folder_parent_uuid)
      assert acme.name == "Acme"
      assert folder!(acme.parent_uuid).name == "Clients"

      again = board!(u, "C", %{}, folder: {:path, ["Clients", "Acme"]})
      assert again.folder_parent_uuid == board.folder_parent_uuid
    end

    test ":root", %{user: u} do
      board = board!(u, "B", %{}, folder: :root)
      assert board.folder_parent_uuid == "00000000-0000-0000-0000-000000000000"
      assert {:ok, %{parent_uuid: nil, name: "B"}} = MediaFolders.ensure_folder(board, u.uuid)
    end

    test "a function gets the scope and the actor", %{user: u} do
      {:ok, target} = Storage.create_folder(%{name: "FromFun", user_uuid: u.uuid})
      me = self()

      fun = fn scope, actor ->
        send(me, {:fun, scope, actor})
        {:ok, target.uuid}
      end

      board = board!(u, "B", %{}, folder: fun)
      assert board.folder_parent_uuid == target.uuid
      assert_received {:fun, {"project", "alpha"}, actor} when actor == u.uuid
    end
  end

  describe "host hooks" do
    test "the parent hook is asked and wins over the default", %{user: u} do
      {:ok, target} = Storage.create_folder(%{name: "HostChoice", user_uuid: u.uuid})
      Process.put(:hook_parent, target.uuid)

      Application.put_env(
        :phoenix_kit_boards,
        :attachments_parent_folder,
        {Hooks, :parent}
      )

      board = board!(u, "B", %{}, label: "Proj")
      assert board.folder_parent_uuid == target.uuid
      assert_received {:parent_hook, "Proj"}
    end

    test "a failing parent hook falls back to the media root, never an error", %{user: u} do
      Application.put_env(
        :phoenix_kit_boards,
        :attachments_parent_folder,
        {Hooks, :broken_parent}
      )

      board = board!(u, "B")
      assert {:ok, %Folder{parent_uuid: nil}} = MediaFolders.ensure_folder(board, u.uuid)
    end

    test "the name hook names the board's folder", %{user: u} do
      Application.put_env(:phoenix_kit_boards, :attachments_folder_name, {Hooks, :name})
      board = board!(u, "Plan")
      assert {:ok, %{name: "Hooked Plan"}} = MediaFolders.ensure_folder(board, u.uuid)
    end
  end

  describe "ensure_folder/2" do
    test "is idempotent, even from a stale struct", %{user: u} do
      stale = board!(u, "Once")
      {:ok, first} = MediaFolders.ensure_folder(stale, u.uuid)

      # `stale` still says folder_uuid: nil — another session got there first.
      {:ok, second} = MediaFolders.ensure_folder(stale, u.uuid)
      assert first.uuid == second.uuid
      assert Repo.aggregate(from(f in Folder, where: f.name == "Once"), :count) == 1
    end

    test "two boards with the same name get separate folders", %{user: u} do
      one = board!(u, "Same", %{}, label: "P")
      two = board!(u, "Same", %{}, label: "P")

      {:ok, f1} = MediaFolders.ensure_folder(one, u.uuid)
      {:ok, f2} = MediaFolders.ensure_folder(two, u.uuid)

      refute f1.uuid == f2.uuid
      assert f1.name == "Same"
      assert f2.name == "board-" <> two.uuid
    end

    test "a folder renamed in the media browser is still the board's", %{user: u} do
      board = board!(u, "Before")
      {:ok, folder} = MediaFolders.ensure_folder(board, u.uuid)
      {:ok, _} = Storage.update_folder(folder, %{name: "After"})

      assert {:ok, %{uuid: same}} = MediaFolders.ensure_folder(board, u.uuid)
      assert same == folder.uuid
    end

    test "a parent trashed since creation falls back to the default layout", %{user: u} do
      board = board!(u, "Orphan", %{}, folder: {:path, ["Doomed"]})
      {:ok, _} = Storage.trash_folder(folder!(board.folder_parent_uuid))

      assert {:ok, folder} = MediaFolders.ensure_folder(board, u.uuid)
      assert folder.parent_uuid != board.folder_parent_uuid
      assert is_nil(folder!(folder.uuid).trashed_at)
    end

    test "a board from before V2 (no parent stored) gets the default layout", %{user: u} do
      board = board!(u, "Legacy", %{}, label: "Old place")

      Repo.update_all(from(b in PhoenixKitBoards.Board, where: b.uuid == ^board.uuid),
        set: [folder_parent_uuid: nil]
      )

      assert {:ok, folder} = MediaFolders.ensure_folder(Boards.get_board(board.uuid), u.uuid)
      assert folder!(folder.parent_uuid).name =~ "Old place"
    end

    test "a board that no longer exists is an error, not a raise", %{user: u} do
      board = board!(u, "Gone")
      {:ok, _} = Boards.delete_board(board)
      assert {:error, :not_found} = MediaFolders.ensure_folder(board, u.uuid)
    end

    test "names are made safe", %{user: u} do
      board = board!(u, "  a/b\\c\n  d  ")
      assert {:ok, %{name: "a b c d"}} = MediaFolders.ensure_folder(board, u.uuid)
    end
  end

  describe "deleting a board" do
    test "trashes its folder and leaves the place's alone", %{user: u} do
      board = board!(u, "Temp", %{}, label: "Keeps")
      {:ok, folder} = MediaFolders.ensure_folder(board, u.uuid)

      assert {:ok, _} = Boards.delete_board(Boards.get_board(board.uuid))

      assert folder!(folder.uuid).trashed_at
      assert is_nil(folder!(board.folder_parent_uuid).trashed_at)
    end

    test "a board that never uploaded deletes cleanly", %{user: u} do
      assert {:ok, _} = Boards.delete_board(board!(u, "Never"))
    end
  end
end
