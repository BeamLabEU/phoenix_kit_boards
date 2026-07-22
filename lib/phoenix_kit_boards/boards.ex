defmodule PhoenixKitBoards.Boards do
  @moduledoc """
  Context for collaborative infinite-canvas boards.

  Owns board CRUD (against the host repo via `PhoenixKit.RepoHelper`), canvas
  load/save into the `data` jsonb column, and the small helpers the LiveView +
  collaboration layer use to read/replace the etcher annotation list.
  """
  import Ecto.Query

  alias PhoenixKitBoards.Board

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

  @doc "Fetch a board by id, or `nil`."
  def get_board(id) do
    repo().get(Board, id)
  rescue
    Ecto.Query.CastError -> nil
  end

  @doc "Create a board with a fresh blank canvas persisted into `data`."
  def create_board(attrs \\ %{}) do
    data = canvas_to_map(blank_canvas())

    %Board{}
    |> Board.changeset(Map.put(normalize(attrs), "data", data))
    |> repo().insert()
  end

  @doc "Rename a board."
  def rename_board(%Board{} = board, name) do
    board
    |> Board.changeset(%{"name" => name})
    |> repo().update()
  end

  @doc "Delete a board."
  def delete_board(%Board{} = board), do: repo().delete(board)

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
