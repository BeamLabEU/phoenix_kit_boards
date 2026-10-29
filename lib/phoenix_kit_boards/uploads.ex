defmodule PhoenixKitBoards.Uploads do
  @moduledoc """
  Files an uploaded file into its board's media folder.

  Storage has already stored the bytes (`Storage.store_file_in_buckets/6`);
  this puts the result where the board's files belong
  (`PhoenixKitBoards.MediaFolders`) by core's rules
  (`ResourceFolders.place_stored/2`): a file with no home is adopted by the
  folder, a file homed elsewhere is *linked* (it keeps its home), a content
  duplicate already in the folder is left alone, and a trashed duplicate is
  restored — the person is uploading it again.

  **Filing never fails an upload.** If the folder cannot be made or the file
  cannot be placed, the file is still stored and still returned; only its
  folder is missing, and the reason is logged. A board that cannot find its
  folder must still be able to take a picture.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKitBoards.{Board, MediaFolders}

  @typedoc "What `Storage.store_file_in_buckets/6` answers."
  @type stored :: {:ok, StorageFile.t()} | {:ok, StorageFile.t(), :duplicate} | {:error, term()}

  @doc """
  Stores the file at `path` for `user_uuid` and files it into `board`'s folder.
  `entry` carries what the browser said about it (`client_name`, `client_type`).
  """
  @spec store(String.t(), String.t(), String.t(), map(), Board.t()) ::
          {:ok, StorageFile.t()} | {:error, term()}
  def store(path, user_uuid, checksum, entry, board) do
    path
    |> Storage.store_file_in_buckets(
      file_type_for(entry),
      user_uuid,
      checksum,
      ext_for(entry),
      entry.client_name
    )
    |> file(board, user_uuid)
  end

  # The extension decides how the stored object is named and served, and the
  # filename is the unreliable half of an entry — a clipboard paste is not
  # guaranteed to carry a usable one, which is why `@image_accept` lists MIME
  # types too. Fall back to the type when the name has nothing to give.
  defp ext_for(entry) do
    case entry.client_name |> Path.extname() |> String.replace_leading(".", "") do
      "" -> entry.client_type |> to_string() |> MIME.extensions() |> List.first() || "bin"
      ext -> ext
    end
  end

  # Core's media browser hashes with SHA256 (`Auth.calculate_file_hash/1`).
  # `store_file_in_buckets/6` dedupes on `user_uuid + file_checksum`, so an
  # MD5 here meant the same bytes pasted onto a board and later uploaded
  # through the media page minted two rows. Streamed: `@image_accept`
  # invites video up to 256 MB, and `File.read/1` would hold all of it.
  @doc false
  def file_checksum(path) do
    case File.open(path, [:read, :raw, :binary], &sha256_io/1) do
      {:ok, digest} -> {:ok, digest}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in File.Error -> {:error, e.reason}
  end

  defp sha256_io(io) do
    io
    |> hash_io(:crypto.hash_init(:sha256))
    |> Base.encode16(case: :lower)
  end

  defp hash_io(io, acc) do
    case IO.binread(io, 65_536) do
      :eof ->
        :crypto.hash_final(acc)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: ""

      data when is_binary(data) ->
        hash_io(io, :crypto.hash_update(acc, data))
    end
  end

  # Public so the classifier can be tested without a LiveView or a bucket —
  # hardcoding `"image"` again would be silent, and the suite has no database.
  @doc false
  def file_type_for(%{client_type: type, client_name: name}),
    do: Storage.determine_file_type(type, name)

  def file_type_for(_), do: Storage.determine_file_type(nil, nil)

  @doc """
  Files `stored` into the folder of `board` (made on the way if this is its
  first file) and answers `{:ok, file}` — or the storage error unchanged.
  """
  @spec file(stored(), Board.t(), String.t() | nil) :: {:ok, StorageFile.t()} | {:error, term()}
  def file({:error, _reason} = error, _board, _user_uuid), do: error

  def file(stored, %Board{} = board, user_uuid) do
    case MediaFolders.ensure_folder(board, user_uuid) do
      {:ok, folder} ->
        place(stored, folder.uuid)

      {:error, reason} ->
        unfiled(stored, "no folder (#{ResourceFolders.describe_failure(reason)})")
    end
  end

  defp place(stored, folder_uuid) do
    case ResourceFolders.place_stored(stored, folder_uuid) do
      {:ok, file} ->
        {:ok, file}

      # The same bytes were already in this board's folder: same file, same URL.
      {:already_attached, file} ->
        {:ok, file}

      {:error, reason} ->
        unfiled(stored, "not placed (#{ResourceFolders.describe_failure(reason)})")
    end
  end

  defp unfiled(stored, why) do
    Logger.warning("[boards] stored a file but did not file it in the board's folder: #{why}")
    flatten(stored)
  end

  # `store_file_in_buckets/6` answers `{:ok, file, :duplicate}` when it
  # recognises the bytes. Same file either way, so flatten to `{:ok, file}`
  # rather than let the 3-tuple read as a failure.
  defp flatten({:ok, file, _dedupe}), do: {:ok, file}
  defp flatten(other), do: other
end
