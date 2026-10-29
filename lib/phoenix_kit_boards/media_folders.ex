defmodule PhoenixKitBoards.MediaFolders do
  @moduledoc """
  One media folder per board, so the files a board collects stay together
  and boards in different places never mix their uploads in the media root.
  Built on core's per-record convention
  (`PhoenixKit.Modules.Storage.ResourceFolders`).

  ## Where a board's folder goes

  A board's own folder is created lazily, on its first upload — an empty board
  leaves nothing behind. *Where* it goes is decided earlier, when the board is
  created, and remembered in `folder_parent_uuid`, because the page that knows
  (the one embedding the panel) is not the page the upload happens on. The
  parent comes from, in order:

    1. the `folder` given when the board is created (the panel's `folder`
       attribute):

         * `{:under, folder_uuid}` — inside that folder
         * `{:path, ["Clients", "Acme"]}` — that chain of folders from the media
           root, created as needed
         * `:root` — the media root itself
         * a `fun(scope, actor_uuid)` answering `{:ok, folder_uuid}`,
           `{:ok, nil}` (the root) or `nil`

    2. the host's hook, when configured:

           config :phoenix_kit_boards,
             attachments_parent_folder: {MyApp.Media, :board_parent},
             attachments_folder_name: {MyApp.Media, :board_name}

       The parent hook is called as `fun(:board, actor_uuid, subject)` where
       `subject` is `%{scope: {type, id} | nil, label: String.t() | nil}`, and
       answers `{:ok, folder_uuid}`, or `nil` for the root. The name hook is
       called as `fun(board, actor_uuid)` and answers `{:ok, name}` or `nil`.

    3. the default: `Boards / <place>`, where `Boards` sits at the root of the
       media library (remembered by uuid in the `boards_media_folder_uuid`
       setting, so it can be renamed or moved) and `<place>` is a folder per
       scope named after its label (also remembered by uuid, so renaming the
       project later keeps its files). Boards with no place go directly under
       `Boards`.

  A failing hook, an unusable `{:under, _}` or any other trouble resolving
  the parent falls back to the default, and then to the media root: **an upload
  never fails on folders.**

  ## The board's folder

  Named by the name hook, else the board's name; a name that another board's
  folder already has — or that core refuses — falls back to `board-<uuid>`,
  which cannot collide. The folder's uuid is kept in the board's `folder_uuid`,
  so a folder renamed or moved in the media browser is still the board's.

  Deleting a board trashes its folder (`trash_folder/1`). Files are never
  deleted outright: core re-homes any file another folder still links.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Folder, Libraries, ResourceFolders}
  alias PhoenixKit.Settings
  alias PhoenixKitBoards.{Board, Boards}

  @app :phoenix_kit_boards
  @pointer {:column, :folder_uuid}
  @prefix "board-"
  @module_folder_name "Boards"
  @module_folder_setting "boards_media_folder_uuid"
  @scope_setting_prefix "boards_scope_folder_"
  # Core caps a folder name; stay well inside it so a long label does not make
  # core refuse the name and push every board onto the fallback.
  @max_name 100

  # `folder_parent_uuid` NULL means "never resolved" (every board from before V2),
  # which the default layout answers. A board that was *told* the media root —
  # `folder: :root`, or a hook that answered `nil` — stores this instead, so the
  # two are not confused.
  @root_marker "00000000-0000-0000-0000-000000000000"

  @typedoc "How the developer says where a place's boards go (see the moduledoc)."
  @type folder_spec ::
          {:under, String.t()}
          | {:path, [String.t()]}
          | :root
          | (Boards.scope(), String.t() | nil -> {:ok, String.t() | nil} | String.t() | nil)
          | nil

  @doc "The OTP app whose hooks decide where board folders go."
  @spec app() :: atom()
  def app, do: @app

  @doc "Where a board keeps its folder uuid (`t:ResourceFolders.pointer/0`)."
  @spec pointer() :: ResourceFolders.pointer()
  def pointer, do: @pointer

  @doc """
  What to store in a board's `folder_parent_uuid` for a parent
  `resolve_parent/4` answered: the uuid, or the root marker for the media root.
  """
  @spec to_stored_parent(String.t() | nil) :: String.t()
  def to_stored_parent(nil), do: @root_marker
  def to_stored_parent(uuid) when is_binary(uuid), do: uuid

  @doc "A board folder's fallback name: `board-<uuid>`."
  @spec deterministic_name(Board.t()) :: String.t()
  def deterministic_name(%Board{uuid: uuid}), do: @prefix <> uuid

  # ── Resolving the parent (at board creation) ───────────────────────

  @doc """
  The folder uuid a new board's own folder will be created in, or `nil` for the
  media root. Never raises and never fails: see the moduledoc for the order.

  `scope` is the board's `{type, id}` (or `nil`), `label` the human name of
  that place, `spec` the `folder` given by the developer.
  """
  @spec resolve_parent(folder_spec(), Boards.scope(), String.t() | nil, String.t() | nil) ::
          String.t() | nil
  def resolve_parent(spec, scope, label, actor_uuid) do
    case explicit_parent(spec, scope, actor_uuid) do
      {:ok, parent} -> parent
      :none -> hook_or_default(scope, label, actor_uuid)
    end
  rescue
    error ->
      Logger.warning("[boards] resolving a board's folder failed: #{inspect(error.__struct__)}")
      nil
  catch
    :exit, reason ->
      Logger.warning(
        "[boards] resolving a board's folder exited: #{ResourceFolders.describe_failure({:exit, reason})}"
      )

      nil
  end

  defp explicit_parent(nil, _scope, _actor), do: :none
  defp explicit_parent(:root, _scope, _actor), do: {:ok, nil}

  defp explicit_parent({:under, uuid}, _scope, _actor) do
    case ResourceFolders.live_folder(uuid) do
      %Folder{uuid: live} ->
        {:ok, live}

      nil ->
        Logger.warning(
          "[boards] the `folder: {:under, _}` is not a live folder; using the default"
        )

        :none
    end
  end

  defp explicit_parent({:path, names}, _scope, actor) when is_list(names) do
    case ensure_path(names, actor) do
      {:ok, parent} -> {:ok, parent}
      :error -> :none
    end
  end

  defp explicit_parent(fun, scope, actor) when is_function(fun, 2) do
    case fun.(scope, actor) do
      {:ok, uuid} -> {:ok, live_uuid(uuid)}
      uuid when is_binary(uuid) -> {:ok, live_uuid(uuid)}
      _ -> {:ok, nil}
    end
  end

  defp explicit_parent(other, _scope, _actor) do
    Logger.warning("[boards] unknown `folder` option #{inspect(other)}; using the default")
    :none
  end

  defp live_uuid(nil), do: nil

  defp live_uuid(uuid) do
    case ResourceFolders.live_folder(uuid) do
      %Folder{uuid: live} -> live
      nil -> nil
    end
  end

  defp ensure_path(names, actor) do
    names = names |> Enum.map(&clean_name/1) |> Enum.reject(&(&1 == ""))

    Enum.reduce_while(names, {:ok, nil}, fn name, {:ok, parent} ->
      case ResourceFolders.ensure(name, parent, actor) do
        {:ok, %Folder{uuid: uuid}} -> {:cont, {:ok, uuid}}
        {:error, _} -> {:halt, :error}
      end
    end)
  end

  defp hook_or_default(scope, label, actor) do
    if ResourceFolders.hook_configured?(@app) do
      ResourceFolders.parent_uuid(@app, :board, actor, %{scope: scope, label: label})
    else
      default_parent(scope, label, actor)
    end
  end

  # ── The default layout: Boards / <place> ───────────────────────────

  defp default_parent(scope, label, actor) do
    with {:ok, boards_uuid} <- module_folder(actor) do
      case scope do
        nil -> boards_uuid
        {type, id} -> scope_folder(type, id, label, boards_uuid, actor)
      end
    else
      _ -> nil
    end
  end

  @doc """
  The `Boards` folder at the root of the media library, created on first use
  and remembered by uuid (so it may be renamed or moved).
  """
  @spec module_folder(String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def module_folder(actor_uuid) do
    case media_folder(Settings.get_setting(@module_folder_setting)) do
      %Folder{uuid: uuid} ->
        {:ok, uuid}

      nil ->
        with {:ok, %Folder{uuid: uuid}} <-
               ResourceFolders.ensure(@module_folder_name, nil, actor_uuid,
                 lookup: &media_root_module_folder/0
               ) do
          remember(@module_folder_setting, uuid)
          {:ok, uuid}
        end
    end
  end

  # Core's by-name lookups do not look at the library, so a person's private
  # library could hold a `Boards` folder that gets adopted. Look in Media only.
  defp media_root_module_folder do
    from(f in Folder,
      where: f.name == ^@module_folder_name and is_nil(f.parent_uuid) and is_nil(f.trashed_at),
      where: f.library_uuid == ^Libraries.media_uuid(),
      order_by: [asc: f.inserted_at, asc: f.uuid],
      limit: 1
    )
    |> repo().one()
  end

  # One folder per place, remembered by uuid under a key derived from the
  # place, so two places with the same label never share a folder and a
  # renamed place keeps its files. Created under a lock so two first boards
  # in a place made at once end up with one folder.
  defp scope_folder(type, id, label, boards_uuid, actor) do
    key = @scope_setting_prefix <> scope_digest(type, id)
    name = place_name(label, type, id)

    case media_folder(Settings.get_setting(key)) do
      %Folder{uuid: uuid} ->
        uuid

      nil ->
        locked(boards_uuid, name, fn ->
          case media_folder(Settings.get_setting(key)) do
            %Folder{uuid: uuid} -> uuid
            nil -> create_scope_folder(key, name, type, id, boards_uuid, actor)
          end
        end)
    end
  end

  defp create_scope_folder(key, name, type, id, boards_uuid, actor) do
    fallback = name_with_suffix(name, scope_digest(type, id))

    # `lookup: fn -> nil end`: a same-named folder under `Boards` that no
    # setting points at is another place's, not this one's. `ensure/4` then
    # creates, and falls back to the suffixed name when the plain one is taken.
    case ResourceFolders.ensure(name, boards_uuid, actor,
           lookup: fn -> nil end,
           fallback_name: fallback
         ) do
      {:ok, %Folder{uuid: uuid}} ->
        remember(key, uuid)
        uuid

      {:error, _reason} ->
        boards_uuid
    end
  end

  defp locked(parent_uuid, name, fun) do
    case repo().transaction(fn ->
           ResourceFolders.lock_name(parent_uuid, name)
           fun.()
         end) do
      {:ok, result} -> result
      {:error, _} -> parent_uuid
    end
  end

  defp place_name(label, type, id) do
    case clean_name(label) do
      "" -> clean_name("#{type} #{id}")
      name -> name
    end
  end

  defp name_with_suffix(name, digest) do
    suffix = " · " <> String.slice(digest, 0, 6)
    String.slice(name, 0, @max_name - String.length(suffix)) <> suffix
  end

  defp scope_digest(type, id),
    do:
      :crypto.hash(:sha256, type <> "\0" <> id)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

  # ── The board's own folder (at first upload) ───────────────────────

  @doc """
  The board's live media folder, or `nil` when it has none yet.
  """
  @spec board_folder(Board.t()) :: Folder.t() | nil
  def board_folder(%Board{folder_uuid: uuid}), do: media_folder(uuid)

  @doc """
  The board's folder, found or created — **lazily**, so call it when there is a
  file to put in. Safe to call from two places at once: both end up with the
  same folder. `{:error, reason}` rather than a raise; the caller stores the
  file anyway (see the moduledoc).
  """
  @spec ensure_folder(Board.t(), String.t() | nil) :: {:ok, Folder.t()} | {:error, term()}
  def ensure_folder(%Board{uuid: uuid}, actor_uuid) do
    # Always the stored row: the struct a LiveView holds can predate another
    # session's first upload, and acting on its stale `folder_uuid` would create
    # a second folder.
    case repo().get(Board, uuid) do
      nil -> {:error, :not_found}
      %Board{} = board -> do_ensure(board, actor_uuid)
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp do_ensure(board, actor_uuid) do
    case board_folder(board) do
      %Folder{} = folder -> {:ok, folder}
      nil -> create_board_folder(board, actor_uuid)
    end
  end

  defp create_board_folder(board, actor_uuid) do
    parent = usable_parent(board, actor_uuid)
    deterministic = deterministic_name(board)

    name =
      case ResourceFolders.host_name(@app, board, actor_uuid) || board.name do
        host when is_binary(host) -> clean_name(host)
        _ -> ""
      end

    name = if name == "", do: deterministic, else: name

    ResourceFolders.ensure(name, parent, actor_uuid,
      lookup: fn -> find_board_folder(board, name, deterministic, parent) end,
      fallback_name: deterministic,
      claim: &ResourceFolders.write_pointer(Board, board.uuid, @pointer, &1.uuid)
    )
  end

  # Where it goes: the parent chosen at creation if it is still there, else
  # (trashed since, or never chosen) the default layout for the board's place.
  defp usable_parent(%Board{folder_parent_uuid: @root_marker}, _actor_uuid), do: nil

  defp usable_parent(%Board{folder_parent_uuid: parent} = board, actor_uuid) do
    case ResourceFolders.live_folder(parent) do
      %Folder{uuid: uuid} -> uuid
      nil -> resolve_parent(nil, Boards.scope_of(board), nil, actor_uuid)
    end
  end

  # core's order, in Media only: a folder named after the board under the
  # parent unless another board points at it, then the deterministic name.
  defp find_board_folder(board, name, deterministic, parent) do
    ResourceFolders.resolve(
      parent: parent,
      host_name: name,
      name: deterministic,
      anywhere: true,
      claimed?: &claimed_by_other?(&1, board)
    )
  end

  defp claimed_by_other?(%Folder{uuid: folder_uuid}, %Board{uuid: own}),
    do: ResourceFolders.claimed?(folder_uuid, own, [{Board, @pointer}])

  # ── Removing ───────────────────────────────────────────────────────

  @doc """
  Moves the board's folder to the media trash (restorable). Files are never
  deleted. `:ok` when the board has no folder.
  """
  @spec trash_folder(Board.t()) :: :ok | {:error, term()}
  def trash_folder(%Board{} = board) do
    case board_folder(board) do
      nil ->
        :ok

      %Folder{} = folder ->
        case Storage.trash_folder(folder) do
          {:ok, _} -> :ok
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    error -> {:error, error}
  end

  # ── Helpers ────────────────────────────────────────────────────────

  # Only folders of the site's media library are ever adopted or reported.
  defp media_folder(uuid) do
    case ResourceFolders.live_folder(uuid) do
      %Folder{library_uuid: library} = folder -> if Libraries.media?(library), do: folder
      nil -> nil
    end
  end

  defp remember(key, uuid) do
    case Settings.update_setting(key, uuid) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[boards] could not remember a media folder: #{ResourceFolders.describe_failure(reason)}"
        )
    end
  end

  # A folder name: trimmed, no path separators or control characters, and a
  # length core will accept.
  defp clean_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[\/\\\x00-\x1f]/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @max_name)
    |> String.trim()
  end

  defp clean_name(_), do: ""

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
