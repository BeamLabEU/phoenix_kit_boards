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

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKitBoards.{Board, MediaFolders}

  @typedoc "What `Storage.store_file_in_buckets/6` answers."
  @type stored :: {:ok, StorageFile.t()} | {:ok, StorageFile.t(), :duplicate} | {:error, term()}

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
