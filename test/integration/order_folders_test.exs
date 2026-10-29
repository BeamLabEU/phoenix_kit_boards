defmodule PhoenixKitBoards.Integration.OrderFoldersTest do
  @moduledoc """
  A host with orders: each order has a folder, nested several levels deep and
  possibly in a storage library of its own, and every board made for an order
  needs a folder of its own inside it — so a folder holds exactly one board's
  files and never leaves anyone guessing which picture belongs to which board.
  """
  use PhoenixKitBoards.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, Folder, Libraries, ResourceFolders}
  alias PhoenixKitBoards.{Boards, MediaFolders, Uploads}

  setup do
    root =
      Path.join(System.tmp_dir!(), "boards_order_media_#{System.unique_integer([:positive])}")

    Repo.update_all("phoenix_kit_buckets", set: [endpoint: root])
    on_exit(fn -> Elixir.File.rm_rf(root) end)
    %{user: user_fixture(), tmp: root}
  end

  # A host's folders for an order: found when they exist, made when they do not
  # (`Orders` is shared by every order). In a library of its own the first folder
  # names that library.
  defp chain!(user, names, library_uuid \\ nil) do
    {uuid, folders} =
      Enum.reduce(names, {nil, []}, fn name, {parent, acc} ->
        folder =
          case ResourceFolders.find_under(name, parent) do
            %Folder{library_uuid: lib} = existing
            when is_nil(library_uuid) or lib == library_uuid ->
              existing

            _ ->
              make_folder!(user, name, parent, library_uuid)
          end

        {folder.uuid, [folder | acc]}
      end)

    {uuid, Enum.reverse(folders)}
  end

  defp make_folder!(user, name, parent, library_uuid) do
    attrs = %{name: name, user_uuid: user.uuid, parent_uuid: parent}

    attrs =
      if library_uuid && is_nil(parent),
        do: Map.put(attrs, :library_uuid, library_uuid),
        else: attrs

    {:ok, folder} = Storage.create_folder(attrs)
    folder
  end

  defp board!(user, order, name, folder_opt) do
    {:ok, board} =
      Boards.create_board(
        %{
          "name" => name,
          "created_by" => user.uuid,
          "scope_type" => "order",
          "scope_id" => order
        },
        folder: folder_opt,
        label: "Order #{order}"
      )

    board
  end

  # A real upload: bytes on disk, stored through the same path the editor uses.
  defp upload!(board, user, content) do
    path = Path.join(System.tmp_dir!(), "boards_up_#{System.unique_integer([:positive])}.png")
    Elixir.File.write!(path, content)
    on_exit(fn -> Elixir.File.rm(path) end)
    {:ok, checksum} = Uploads.file_checksum(path)

    entry = %{
      client_name: "pic-#{System.unique_integer([:positive])}.png",
      client_type: "image/png"
    }

    {:ok, file} = Uploads.store(path, user.uuid, checksum, entry, board)
    Repo.get!(File, file.uuid)
  end

  defp names_in(folder_uuid),
    do: folder_uuid |> ResourceFolders.list_files() |> Enum.map(& &1.original_file_name)

  describe "boards of an order, in the order's own folder (several levels deep)" do
    test "each board gets a folder of its own inside it, and files never mix", %{user: u} do
      {items, _folders} = chain!(u, ["Orders", "Order 1001", "Items"])

      one = board!(u, "1001", "Front design", {:under, items})
      two = board!(u, "1001", "Back design", {:under, items})

      f1 = upload!(one, u, "front bytes")
      f2 = upload!(two, u, "back bytes")

      b1 = MediaFolders.board_folder(Boards.get_board(one.uuid))
      b2 = MediaFolders.board_folder(Boards.get_board(two.uuid))

      assert b1.parent_uuid == items and b2.parent_uuid == items
      assert {b1.name, b2.name} == {"Front design", "Back design"}
      refute b1.uuid == b2.uuid

      assert names_in(b1.uuid) == [f1.original_file_name]
      assert names_in(b2.uuid) == [f2.original_file_name]
      assert f1.folder_uuid == b1.uuid and f2.folder_uuid == b2.uuid
    end

    test "two orders never share: each board's folder is inside its own order's", %{user: u} do
      {a, _} = chain!(u, ["Orders", "A-1", "Boards"])
      {b, _} = chain!(u, ["Orders", "B-2", "Boards"])

      board_a = board!(u, "A-1", "Notes", {:under, a})
      board_b = board!(u, "B-2", "Notes", {:under, b})

      upload!(board_a, u, "aaa")
      upload!(board_b, u, "bbb")

      fa = MediaFolders.board_folder(Boards.get_board(board_a.uuid))
      fb = MediaFolders.board_folder(Boards.get_board(board_b.uuid))

      # Same name, different places: neither takes the other's folder.
      assert fa.name == "Notes" and fb.name == "Notes"
      assert fa.parent_uuid == a and fb.parent_uuid == b
      refute fa.uuid == fb.uuid
    end

    test "a function can resolve the order's folder when the board is made", %{user: u} do
      {items, _} = chain!(u, ["Orders", "Order 7", "Items"])
      me = self()

      resolver = fn scope, actor ->
        send(me, {:resolved, scope, actor})
        {:ok, items}
      end

      board = board!(u, "7", "Via function", resolver)
      assert_received {:resolved, {"order", "7"}, actor} when actor == u.uuid
      assert board.folder_parent_uuid == items
    end

    test "the host can make the board's folder exist at once, to link to it", %{user: u} do
      {items, _} = chain!(u, ["Orders", "Order 8", "Items"])
      board = board!(u, "8", "Eager", {:under, items})

      assert board.folder_uuid == nil
      assert {:ok, folder} = MediaFolders.ensure_folder(board, u.uuid)
      assert folder.parent_uuid == items
      assert Boards.get_board(board.uuid).folder_uuid == folder.uuid
    end

    test "a function that fails does not drop the board in the media root", %{user: u} do
      board = board!(u, "9", "Failing", fn _scope, _actor -> {:error, :order_has_no_folder} end)

      # The default layout, not the root: a missing order folder must not
      # scatter files where nobody will look for them.
      {:ok, folder} = MediaFolders.ensure_folder(board, u.uuid)
      refute is_nil(folder.parent_uuid)
    end
  end

  describe "an order folder in a storage library of its own" do
    setup %{user: u} do
      {:ok, library} =
        Libraries.create_system_library(%{
          "name" => "Orders library #{System.unique_integer([:positive])}"
        })

      {order, _} = chain!(u, ["Order 2002"], library.uuid)
      %{library: library, order: order}
    end

    test "the board's folder is in that library, and so is the file inside it", %{
      user: u,
      library: library,
      order: order
    } do
      board = board!(u, "2002", "Sketch", {:under, order})
      file = upload!(board, u, "library bytes")

      folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
      assert folder, "the board's folder must be found even outside Media"
      assert to_string(folder.library_uuid) == to_string(library.uuid)
      assert folder.parent_uuid == order

      assert to_string(file.library_uuid) == to_string(library.uuid)
      assert file.folder_uuid == folder.uuid
      assert names_in(folder.uuid) == [file.original_file_name]
    end

    test "deleting the board trashes its folder there too", %{user: u, order: order} do
      board = board!(u, "2002", "Gone soon", {:under, order})
      upload!(board, u, "bytes")
      folder = MediaFolders.board_folder(Boards.get_board(board.uuid))

      {:ok, _} = Boards.delete_board(Boards.get_board(board.uuid))
      assert Repo.get!(Folder, folder.uuid).trashed_at
      assert is_nil(Repo.get!(Folder, order).trashed_at)
    end

    test "a second upload reuses the folder", %{user: u, order: order} do
      board = board!(u, "2002", "Twice", {:under, order})
      upload!(board, u, "one")
      upload!(board, u, "two")

      folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
      assert length(ResourceFolders.list_files(folder.uuid)) == 2

      assert Repo.aggregate(
               from(f in Folder, where: f.parent_uuid == ^order and f.name == "Twice"),
               :count
             ) == 1
    end
  end

  describe "a board's folder follows its name" do
    test "renaming the board renames the folder it was named after", %{user: u} do
      {items, _} = chain!(u, ["Orders", "Order 3", "Items"])
      board = board!(u, "3", "Draft", {:under, items})
      upload!(board, u, "bytes")

      {:ok, _} = Boards.rename_board(Boards.get_board(board.uuid), "Final artwork")

      folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
      assert folder.name == "Final artwork"
    end

    test "a folder that was renamed by hand is left alone", %{user: u} do
      {items, _} = chain!(u, ["Orders", "Order 4", "Items"])
      board = board!(u, "4", "Draft", {:under, items})
      upload!(board, u, "bytes")
      folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
      {:ok, _} = Storage.update_folder(folder, %{name: "Approved by client"})

      {:ok, _} = Boards.rename_board(Boards.get_board(board.uuid), "Something else")

      assert MediaFolders.board_folder(Boards.get_board(board.uuid)).name == "Approved by client"
    end

    test "a rename into a name already taken beside it does not fail the rename", %{user: u} do
      {items, _} = chain!(u, ["Orders", "Order 5", "Items"])
      one = board!(u, "5", "One", {:under, items})
      two = board!(u, "5", "Two", {:under, items})
      upload!(one, u, "1")
      upload!(two, u, "2")

      assert {:ok, %{name: "One"}} = Boards.rename_board(Boards.get_board(two.uuid), "One")
      assert MediaFolders.board_folder(Boards.get_board(two.uuid)).name == "Two"
    end
  end

  test "a scope can be any strings — long, unicode, with colons and slashes", %{user: u} do
    id = "/orders/№ 12:34/ünïcode " <> String.duplicate("x", 150)

    {:ok, board} =
      Boards.create_board(%{
        "name" => "Odd",
        "created_by" => u.uuid,
        "scope_type" => "order",
        "scope_id" => id
      })

    assert Boards.scope_of(board) == {"order", id}
    assert [%{uuid: uuid}] = Boards.list_for_scope({"order", id}, u.uuid)
    assert uuid == board.uuid
    assert Boards.scope_topic({"order", id}) =~ id
  end
end
