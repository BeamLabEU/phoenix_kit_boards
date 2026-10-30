defmodule PhoenixKitBoards.Boards do
  @moduledoc """
  Context for collaborative infinite-canvas boards.

  Owns board CRUD (against the host repo via `PhoenixKit.RepoHelper`), canvas
  load/save into the `data` jsonb column, and the small helpers the LiveView +
  collaboration layer use to read/replace the etcher annotation list.
  """
  import Ecto.Query

  alias Phoenix.PubSub
  alias PhoenixKit.PubSubHelper
  alias PhoenixKitBoards.{Board, MediaFolders}

  # Virtual extent of a blank board. Panning is infinite (the `infinite_canvas`
  # attr on `<Fresco.canvas>`); this just gives shapes a coordinate space and
  # etcher a non-zero canvas size to hydrate against.
  @blank_width 12_000
  @blank_height 8_000

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "The width and height of a blank board's canvas, in canvas units."
  @spec canvas_size() :: {pos_integer(), pos_integer()}
  def canvas_size, do: {@blank_width, @blank_height}

  # ── Telling a place's lists that something changed ───────────────────────

  @doc """
  The PubSub topic a place's boards announce changes on. Anything that shows a
  list of a place's boards (`PhoenixKitBoards.Web.BoardsPanel`) subscribes to it
  and re-reads the list when a `{:boards_scope_changed, board_uuid}` arrives.
  """
  @spec scope_topic(scope()) :: String.t()
  def scope_topic(scope) do
    case scope!(scope) do
      nil -> "phoenix_kit_boards:scope:unscoped"
      {type, id} -> "phoenix_kit_boards:scope:#{type}:#{id}"
    end
  end

  @doc "Subscribe the calling process to a place's change announcements."
  @spec subscribe_scope(scope()) :: :ok | {:error, term()}
  def subscribe_scope(scope), do: PubSubHelper.subscribe(scope_topic(scope))

  # The message says *that* something changed, never what: a private board's
  # name must not travel to people who may not see it. Receivers re-read the
  # list through `list_for_scope/3`, which applies visibility.
  #
  # Best effort: a missing PubSub server must not turn a saved board into an
  # error.
  defp announce(%Board{} = board) do
    PubSub.broadcast(
      PubSubHelper.pubsub(),
      scope_topic(scope_of(board)),
      {:boards_scope_changed, board.uuid}
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp announced({:ok, %Board{} = board} = result) do
    announce(board)
    result
  end

  defp announced(other), do: other

  # ── Board CRUD ────────────────────────────────────────────────────────────

  @doc "All boards, newest first."
  def list_boards do
    repo().all(from(b in Board, order_by: [desc: b.updated_at]))
  end

  @typedoc "A place boards belong to: `{scope_type, scope_id}`, or `nil` for the unscoped ones."
  @type scope :: {String.t(), String.t()} | nil

  @default_limit 50

  @doc """
  A place as it is stored: `{type, id}` with both as strings.

  A host names a place with what it has — `{"order", 1001}`, `{:project, uuid}` —
  so a type or an id may be a string, an integer or an atom. `nil` is the
  unscoped boards. Anything else — a `nil` id above all — is `:error`: a place
  with no id must show **nothing**, never fall through to the boards that belong
  nowhere.
  """
  @spec normalize_scope(term()) :: {:ok, scope()} | :error
  def normalize_scope(nil), do: {:ok, nil}

  def normalize_scope({type, id}) do
    with {:ok, type} <- scope_part(type),
         {:ok, id} <- scope_part(id) do
      {:ok, {type, id}}
    end
  end

  def normalize_scope(_other), do: :error

  defp scope_part(part) when is_binary(part) and part != "", do: {:ok, part}
  defp scope_part(part) when is_integer(part), do: {:ok, Integer.to_string(part)}

  defp scope_part(part) when is_atom(part) and part not in [nil, true, false],
    do: {:ok, Atom.to_string(part)}

  defp scope_part(_), do: :error

  # The query functions take any place `normalize_scope/1` accepts; a bad one is
  # the caller's bug, said plainly.
  defp scope!(scope) do
    case normalize_scope(scope) do
      {:ok, normalized} -> normalized
      :error -> raise ArgumentError, "not a place: #{inspect(scope)} (expected {type, id} or nil)"
    end
  end

  @doc """
  The live boards of one place that `user_uuid` may see: every shared board
  there, plus the user's own private ones. Pinned first, then most recently
  changed.

  `scope` is `{type, id}`, or `nil` for the unscoped boards. This is the
  *module's* visibility rule only; whether the user may look at the place at
  all is the host's call (`PhoenixKitBoards.Access`).

  ## Options

    * `:limit` — at most this many (default #{@default_limit})
    * `:search` — only names containing this text, case-insensitively
    * `:include_archived` — archived boards too (default `false`)
    * `:include_data` — load the canvas document too (default `true`); set to
      `false` for lists that only need the preview and board metadata
  """
  @spec list_for_scope(scope(), String.t() | nil, keyword()) :: [Board.t()]
  def list_for_scope(scope, user_uuid, opts \\ []) do
    Board
    |> in_scope(scope!(scope))
    |> visible_query(user_uuid)
    |> archived_filter(Keyword.get(opts, :include_archived, false))
    |> search_filter(Keyword.get(opts, :search))
    |> order_by([b], desc_nulls_last: b.pinned_at, desc: b.updated_at, desc: b.uuid)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> select_data(opts)
    |> repo().all()
  end

  @doc "How many boards `list_for_scope/3` would find without a limit."
  @spec count_for_scope(scope(), String.t() | nil, keyword()) :: non_neg_integer()
  def count_for_scope(scope, user_uuid, opts \\ []) do
    Board
    |> in_scope(scope!(scope))
    |> visible_query(user_uuid)
    |> archived_filter(Keyword.get(opts, :include_archived, false))
    |> search_filter(Keyword.get(opts, :search))
    |> repo().aggregate(:count)
  end

  defp in_scope(query, nil), do: where(query, [b], is_nil(b.scope_type))

  defp in_scope(query, {type, id}) when is_binary(type) and is_binary(id),
    do: where(query, [b], b.scope_type == ^type and b.scope_id == ^id)

  defp visible_query(query, nil), do: where(query, [b], b.visibility == "shared")

  defp visible_query(query, user_uuid),
    do: where(query, [b], b.visibility == "shared" or b.created_by == ^user_uuid)

  defp archived_filter(query, true), do: query
  defp archived_filter(query, _), do: where(query, [b], is_nil(b.archived_at))

  defp search_filter(query, term) when is_binary(term) and term != "" do
    pattern = "%" <> escape_like(term) <> "%"
    where(query, [b], ilike(b.name, ^pattern))
  end

  defp search_filter(query, _), do: query

  defp escape_like(term), do: String.replace(term, ["\\", "%", "_"], &("\\" <> &1))

  @doc """
  Whether `user_uuid` may see `board` by the module's own rule: a shared board
  is visible, a private one only to its creator. (The host's say over the
  place is separate — see `PhoenixKitBoards.Access`.)
  """
  @spec visible_to?(Board.t(), String.t() | nil) :: boolean()
  def visible_to?(%Board{visibility: "shared"}, _user_uuid), do: true

  def visible_to?(%Board{visibility: "private", created_by: creator}, user_uuid),
    do: is_binary(user_uuid) and creator == user_uuid

  def visible_to?(%Board{}, _user_uuid), do: false

  @doc "The board's place as `{type, id}`, or `nil` when it has none."
  @spec scope_of(Board.t()) :: scope()
  def scope_of(%Board{scope_type: type, scope_id: id}) when is_binary(type) and is_binary(id),
    do: {type, id}

  def scope_of(%Board{}), do: nil

  @doc "Fetch a board by id, or `nil`. Pass `include_data: false` for metadata only."
  def get_board(id, opts \\ []) do
    repo().get(select_data(Board, opts), id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp select_data(query, opts) do
    if Keyword.get(opts, :include_data, true) do
      query
    else
      fields = Board.__schema__(:fields) -- [:data]
      select(query, [b], struct(b, ^fields))
    end
  end

  @doc """
  Create a board with a fresh blank canvas persisted into `data`.

  A board may be given a place (`"scope_type"` + `"scope_id"`), a `"visibility"`
  and a `"kind"`; see `PhoenixKitBoards.Board`.

  ## Options

    * `:folder` — where the board's own media folder will go, see
      `PhoenixKitBoards.MediaFolders` (`{:under, uuid}`, `{:path, names}`,
      `:root`, a function, or `nil` for the host's hook / the default layout)
    * `:label` — the human name of the board's place, used to name its folder

  The parent folder is decided here and remembered on the board; the board's
  own folder is only created by its first upload. Folder trouble never stops
  a board being created.
  """
  @spec create_board(map(), keyword()) :: {:ok, Board.t()} | {:error, Ecto.Changeset.t()}
  def create_board(attrs \\ %{}, opts \\ []) do
    data = canvas_to_map(blank_canvas())
    attrs = attrs |> normalize() |> Map.put("data", data)
    changeset = Board.changeset(%Board{}, attrs)

    changeset =
      if changeset.valid? do
        parent =
          MediaFolders.resolve_parent(
            Keyword.get(opts, :folder),
            scope_from(changeset),
            Keyword.get(opts, :label),
            Ecto.Changeset.get_field(changeset, :created_by)
          )

        Ecto.Changeset.put_change(
          changeset,
          :folder_parent_uuid,
          MediaFolders.to_stored_parent(parent)
        )
      else
        changeset
      end

    changeset |> repo().insert() |> announced()
  end

  defp scope_from(changeset) do
    case {Ecto.Changeset.get_field(changeset, :scope_type),
          Ecto.Changeset.get_field(changeset, :scope_id)} do
      {type, id} when is_binary(type) and is_binary(id) -> {type, id}
      _ -> nil
    end
  end

  @doc """
  Make a board `"private"` or `"shared"`. Only its creator may — anyone else
  gets `{:error, :forbidden}`.
  """
  @spec set_visibility(Board.t(), String.t(), String.t() | nil) ::
          {:ok, Board.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def set_visibility(%Board{} = board, visibility, user_uuid) do
    if creator?(board, user_uuid) do
      result = board |> Board.visibility_changeset(visibility) |> repo().update() |> announced()
      if match?({:ok, _}, result), do: access_changed(board)
      result
    else
      {:error, :forbidden}
    end
  end

  @doc "Pin a board to the top of its list. Anyone who can see it may."
  @spec pin(Board.t(), String.t() | nil) :: {:ok, Board.t()} | {:error, :forbidden}
  def pin(%Board{} = board, user_uuid),
    do: toggle(board, user_uuid, &Board.pin_changeset(&1, true))

  @doc "Undo `pin/2`."
  @spec unpin(Board.t(), String.t() | nil) :: {:ok, Board.t()} | {:error, :forbidden}
  def unpin(%Board{} = board, user_uuid),
    do: toggle(board, user_uuid, &Board.pin_changeset(&1, false))

  @doc "Hide a board from its list without deleting it. Creator only."
  @spec archive(Board.t(), String.t() | nil) :: {:ok, Board.t()} | {:error, :forbidden}
  def archive(%Board{} = board, user_uuid),
    do: creator_only(board, user_uuid, &Board.archive_changeset(&1, true))

  @doc "Undo `archive/2`. Creator only."
  @spec unarchive(Board.t(), String.t() | nil) :: {:ok, Board.t()} | {:error, :forbidden}
  def unarchive(%Board{} = board, user_uuid),
    do: creator_only(board, user_uuid, &Board.archive_changeset(&1, false))

  defp toggle(board, user_uuid, changeset_fun) do
    if visible_to?(board, user_uuid),
      do: board |> changeset_fun.() |> repo().update() |> announced(),
      else: {:error, :forbidden}
  end

  defp creator_only(board, user_uuid, changeset_fun) do
    if creator?(board, user_uuid),
      do: board |> changeset_fun.() |> repo().update() |> announced(),
      else: {:error, :forbidden}
  end

  defp creator?(%Board{created_by: creator}, user_uuid),
    do: is_binary(user_uuid) and creator == user_uuid

  @doc "Rename a board."
  def rename_board(%Board{} = board, name) do
    board
    |> Board.changeset(%{"name" => name})
    |> repo().update()
    |> renamed(board.name)
    |> announced()
  end

  # Its folder follows the name, where it still bears the old one.
  defp renamed({:ok, %Board{} = updated} = result, old_name) do
    MediaFolders.rename_folder(updated, old_name, updated.name)
    result
  end

  defp renamed(other, _old_name), do: other

  @doc """
  Delete a board and move its media folder to the trash. The folder is
  trashed after the row is gone and best effort: a failure is logged, never
  returned, because the board is deleted either way. Files are not deleted.
  """
  def delete_board(%Board{} = board) do
    # Uploads write the folder pointer independently of the editor's struct.
    # Read it under a row lock so deletion cannot miss a folder just created
    # by this or another session.
    result =
      repo().transaction(fn ->
        current = repo().one!(from(b in Board, where: b.uuid == ^board.uuid, lock: "FOR UPDATE"))

        case repo().delete(current) do
          {:ok, deleted} -> deleted
          {:error, reason} -> repo().rollback(reason)
        end
      end)

    with {:ok, deleted} <- result do
      case MediaFolders.trash_folder(deleted) do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("[boards] could not trash a deleted board's folder: #{inspect(reason)}")
      end

      announce(deleted)
      access_changed(deleted)
      {:ok, deleted}
    end
  end

  defp access_changed(board) do
    PubSub.broadcast(
      PubSubHelper.pubsub(),
      "phoenix_kit_boards:#{board.uuid}",
      :board_access_changed
    )
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ── Canvas load / save ────────────────────────────────────────────────────

  @doc "A fresh, empty infinite canvas with an initialized (empty) etcher layer."
  def blank_canvas do
    Fresco.Canvas.new(width: @blank_width, height: @blank_height, background: "#f8fafc")
    |> Fresco.Canvas.put_extension("etcher", %{"version" => "1", "annotations" => []})
  end

  @doc "Load a board's `Fresco.Canvas` from its `data` column."
  def load_canvas(%Board{data: data}) when is_map(data) and map_size(data) > 0 do
    Fresco.Canvas.from_json!(Jason.encode!(data))
  rescue
    _ -> blank_canvas()
  end

  def load_canvas(%Board{}), do: blank_canvas()

  @doc """
  Replace a board's etcher annotations and persist the canvas into `data`.

  Returns `{:ok, canvas, board}` with the updated canvas + row.
  """
  def save_annotations(%Board{} = board, %Fresco.Canvas{} = canvas, annotations)
      when is_list(annotations) do
    canvas = put_annotations(canvas, annotations)
    preview = preview_from(annotations)

    board
    |> Board.data_changeset(canvas_to_map(canvas))
    |> Ecto.Changeset.put_change(:preview, preview)
    |> repo().update()
    |> case do
      {:ok, saved} ->
        # Only a change to what a list shows is worth a message: every edit of
        # a busy board comes through here.
        if saved.preview != board.preview, do: announce(saved)
        {:ok, canvas, saved}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @preview_text 140

  @doc """
  What a list shows of a board without opening it: the first piece of text, the
  first image, and how many shapes it holds. Read off the annotation list a save
  already has — nothing is rendered and no rasteriser is involved.

  An image that is still embedded as a `data:` URL is skipped: it would put the
  whole picture in every list row.
  """
  @spec preview_from([map()]) :: map()
  def preview_from(annotations) when is_list(annotations) do
    %{
      "text" => first_text(annotations),
      "image_url" => first_image(annotations),
      "count" => length(annotations)
    }
  end

  defp first_text(annotations) do
    Enum.find_value(annotations, fn
      %{"kind" => "text", "metadata" => %{"title" => title}} when is_binary(title) ->
        case String.trim(title) do
          "" -> nil
          text -> String.slice(text, 0, @preview_text)
        end

      _ ->
        nil
    end)
  end

  defp first_image(annotations) do
    Enum.find_value(annotations, fn
      %{"kind" => "image", "geometry" => %{"href" => "data:" <> _}} -> nil
      %{"kind" => "image", "geometry" => %{"href" => href}} when is_binary(href) -> href
      _ -> nil
    end)
  end

  # ── Annotation helpers (the collab layer's mutable state) ─────────────────

  @doc "The board's current etcher annotation list (list of shape maps)."
  def annotations(%Fresco.Canvas{} = canvas) do
    case canvas.extensions["etcher"] do
      %{"annotations" => list} when is_list(list) -> list
      %{annotations: list} when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Return `canvas` with its etcher annotation list replaced by `list`."
  def put_annotations(%Fresco.Canvas{} = canvas, list) when is_list(list) do
    Fresco.Canvas.put_extension(canvas, "etcher", %{"version" => "1", "annotations" => list})
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp canvas_to_map(%Fresco.Canvas{} = canvas), do: Jason.decode!(Fresco.Canvas.to_json!(canvas))

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end
