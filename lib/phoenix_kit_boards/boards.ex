defmodule PhoenixKitBoards.Boards do
  @moduledoc """
  Context for collaborative infinite-canvas boards.

  Owns board CRUD (against the host repo via `PhoenixKit.RepoHelper`), canvas
  load/save into the `data` jsonb column, and the small helpers the LiveView +
  collaboration layer use to read/replace the etcher annotation list.
  """
  import Ecto.Query

  alias PhoenixKitBoards.{Board, MediaFolders}

  # Virtual extent of a blank board. Panning is infinite (the `infinite_canvas`
  # attr on `<Fresco.canvas>`); this just gives shapes a coordinate space and
  # etcher a non-zero canvas size to hydrate against.
  @blank_width 12_000
  @blank_height 8_000

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ── Board CRUD ────────────────────────────────────────────────────────────

  @doc "All boards, newest first."
  def list_boards do
    repo().all(from(b in Board, order_by: [desc: b.updated_at]))
  end

  @typedoc "A place boards belong to: `{scope_type, scope_id}`, or `nil` for the unscoped ones."
  @type scope :: {String.t(), String.t()} | nil

  @default_limit 50

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
  """
  @spec list_for_scope(scope(), String.t() | nil, keyword()) :: [Board.t()]
  def list_for_scope(scope, user_uuid, opts \\ []) do
    Board
    |> in_scope(scope)
    |> visible_query(user_uuid)
    |> archived_filter(Keyword.get(opts, :include_archived, false))
    |> search_filter(Keyword.get(opts, :search))
    |> order_by([b], desc_nulls_last: b.pinned_at, desc: b.updated_at, desc: b.uuid)
    |> limit(^Keyword.get(opts, :limit, @default_limit))
    |> repo().all()
  end

  @doc "How many boards `list_for_scope/3` would find without a limit."
  @spec count_for_scope(scope(), String.t() | nil, keyword()) :: non_neg_integer()
  def count_for_scope(scope, user_uuid, opts \\ []) do
    Board
    |> in_scope(scope)
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

  @doc "Fetch a board by id, or `nil`."
  def get_board(id) do
    repo().get(Board, id)
  rescue
    Ecto.Query.CastError -> nil
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

    repo().insert(changeset)
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
      board |> Board.visibility_changeset(visibility) |> repo().update()
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
      do: board |> changeset_fun.() |> repo().update(),
      else: {:error, :forbidden}
  end

  defp creator_only(board, user_uuid, changeset_fun) do
    if creator?(board, user_uuid),
      do: board |> changeset_fun.() |> repo().update(),
      else: {:error, :forbidden}
  end

  defp creator?(%Board{created_by: creator}, user_uuid),
    do: is_binary(user_uuid) and creator == user_uuid

  @doc "Rename a board."
  def rename_board(%Board{} = board, name) do
    board
    |> Board.changeset(%{"name" => name})
    |> repo().update()
  end

  @doc """
  Delete a board and move its media folder to the trash. The folder is
  trashed after the row is gone and best effort: a failure is logged, never
  returned, because the board is deleted either way. Files are not deleted.
  """
  def delete_board(%Board{} = board) do
    with {:ok, deleted} <- repo().delete(board) do
      case MediaFolders.trash_folder(board) do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("[boards] could not trash a deleted board's folder: #{inspect(reason)}")
      end

      {:ok, deleted}
    end
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

    board
    |> Board.data_changeset(canvas_to_map(canvas))
    |> repo().update()
    |> case do
      {:ok, board} -> {:ok, canvas, board}
      {:error, reason} -> {:error, reason}
    end
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
