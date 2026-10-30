defmodule PhoenixKitBoards.Integration.UploadsTest do
  use PhoenixKitBoards.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Folder, ResourceFolders}
  alias PhoenixKitBoards.{Boards, MediaFolders, Uploads}

  setup do
    user = user_fixture()

    {:ok, board} =
      Boards.create_board(
        %{
          "name" => "Pics",
          "created_by" => user.uuid,
          "scope_type" => "project",
          "scope_id" => "alpha"
        },
        label: "Alpha Co"
      )

    %{user: user, board: board}
  end

  # A stored file as `Storage.store_file_in_buckets/6` would have left it.
  defp stored_file!(user, name \\ "shot.png") do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: name,
        file_name: Ecto.UUID.generate() <> ".png",
        file_path: "test/" <> name,
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 1,
        status: "active",
        user_uuid: user.uuid
      })

    file
  end

  defp in_folder?(folder_uuid, file),
    do: Enum.any?(ResourceFolders.list_files(folder_uuid), &(&1.uuid == file.uuid))

  test "the first upload makes the board's folder and files into it", %{user: u, board: board} do
    file = stored_file!(u)

    assert {:ok, %{uuid: uuid}} = Uploads.file({:ok, file}, board, u.uuid)
    assert uuid == file.uuid

    folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
    assert %Folder{name: "Pics"} = folder
    assert in_folder?(folder.uuid, file)
    # And it is NOT loose in the media root.
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == folder.uuid
  end

  test "later uploads go to the same folder", %{user: u, board: board} do
    one = stored_file!(u, "a.png")
    two = stored_file!(u, "b.png")

    {:ok, _} = Uploads.file({:ok, one}, board, u.uuid)
    {:ok, _} = Uploads.file({:ok, two}, board, u.uuid)

    folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
    assert in_folder?(folder.uuid, one) and in_folder?(folder.uuid, two)
  end

  test "a duplicate answer is flattened to the same file", %{user: u, board: board} do
    file = stored_file!(u)
    assert {:ok, %{uuid: same}} = Uploads.file({:ok, file, :duplicate}, board, u.uuid)
    assert same == file.uuid
  end

  test "the same bytes uploaded to the same board twice are one file in one folder",
       %{user: u, board: board} do
    file = stored_file!(u)
    {:ok, _} = Uploads.file({:ok, file}, board, u.uuid)
    assert {:ok, %{uuid: same}} = Uploads.file({:ok, file, :duplicate}, board, u.uuid)
    assert same == file.uuid

    folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
    assert Enum.count(ResourceFolders.list_files(folder.uuid), &(&1.uuid == file.uuid)) == 1
  end

  test "a file already homed elsewhere is linked into the board, not moved", %{
    user: u,
    board: board
  } do
    {:ok, other} = Storage.create_folder(%{name: "Elsewhere", user_uuid: u.uuid})
    file = stored_file!(u)
    {:ok, _} = Storage.attach_file_to_folder(file, other.uuid)

    {:ok, _} = Uploads.file({:ok, file, :duplicate}, board, u.uuid)

    folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
    assert in_folder?(folder.uuid, file)
    assert Repo.get!(Storage.File, file.uuid).folder_uuid == other.uuid
  end

  test "a trashed duplicate is restored into the board's folder", %{user: u, board: board} do
    file = stored_file!(u)
    {:ok, trashed} = Storage.trash_file(file)

    assert {:ok, restored} = Uploads.file({:ok, trashed, :duplicate}, board, u.uuid)
    assert Repo.get!(Storage.File, restored.uuid).status != "trashed"

    folder = MediaFolders.board_folder(Boards.get_board(board.uuid))
    assert in_folder?(folder.uuid, restored)
  end

  test "a storage error passes through untouched and makes no folder", %{user: u, board: board} do
    assert {:error, :bucket_down} = Uploads.file({:error, :bucket_down}, board, u.uuid)
    assert MediaFolders.board_folder(Boards.get_board(board.uuid)) == nil
  end

  test "the upload still succeeds when the board's folder cannot be made",
       %{user: u, board: board} do
    {:ok, _} = Boards.delete_board(board)
    file = stored_file!(u)

    # The board is gone, so there is no folder to make.
    import ExUnit.CaptureLog

    log =
      capture_log(fn ->
        assert {:ok, %{uuid: same}} = Uploads.file({:ok, file}, board, u.uuid)
        assert same == file.uuid
      end)

    assert log =~ "did not file it"
  end
end
