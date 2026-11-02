defmodule PhoenixKitBoards.Quick do
  @moduledoc """
  Quick capture: a board made in one step from a note or an image, so a thought
  or a screenshot can be saved to a place without opening the editor.

  The result is an ordinary board (`kind: "quick"`) with the item already on
  it, centred. Opening it gives the full canvas; nothing about a quick board
  is special once it exists.

  Shapes are built here with the structure the editor itself writes, sized for
  the canvas a board starts with (12 000 × 8 000 units, shown fitted to the
  screen) — a note at editor-default size would be a speck.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitBoards.{Boards, Uploads}

  @max_note_chars 2_000
  @max_note_lines 40
  @wrap_at 40
  @font_size 300
  @line_height 1.35
  # Average glyph width as a fraction of the font size: a point-text box wider
  # than its text just means a bigger selection frame.
  @glyph_width 0.58
  @note_color "#1f2937"

  # The largest an image is drawn: a third of the canvas wide. The shape keeps
  # the picture's own proportions.
  @image_box {4_000, 3_000}
  @name_max 60

  @doc """
  Makes an empty quick board — a blank canvas to open and write on. Named after
  the moment it was made, since there is nothing else to name it by; renaming
  is one click in the panel.

  Takes the same options as `create_note/4`.
  """
  @spec create_empty(Boards.scope(), String.t(), keyword()) ::
          {:ok, PhoenixKitBoards.Board.t()} | {:error, term()}
  def create_empty(scope, user_uuid, opts \\ []),
    do: create(scope, user_uuid, dated("Board"), opts)

  @doc """
  Makes a board holding `text`. `{:error, :empty}` for a note with nothing in it.

  ## Options

  Everything `PhoenixKitBoards.Boards.create_board/2` takes (`:folder`,
  `:label`), plus `:visibility` (`"shared"` by default).
  """
  @spec create_note(Boards.scope(), String.t(), String.t(), keyword()) ::
          {:ok, PhoenixKitBoards.Board.t()} | {:error, :empty | term()}
  def create_note(scope, user_uuid, text, opts \\ []) when is_binary(text) do
    text = normalize_note(text)

    if text == "" do
      {:error, :empty}
    else
      with {:ok, board} <- create(scope, user_uuid, note_name(text), opts),
           {:ok, _canvas, board} <- put_shapes(board, [note_shape(text)]) do
        {:ok, board}
      end
    end
  end

  @doc """
  Makes a board holding the image at `path` (a finished upload's temp file).
  `entry` is what the browser said about it (`client_name`, `client_type`).

  The file is stored and filed into the new board's own folder like any other
  upload. If it cannot be stored the half-made board is removed rather than
  left empty in the list.
  """
  @spec create_image(Boards.scope(), String.t(), String.t(), map(), keyword()) ::
          {:ok, PhoenixKitBoards.Board.t()} | {:error, term()}
  def create_image(scope, user_uuid, path, entry, opts \\ []) do
    with {:ok, board} <- create(scope, user_uuid, image_name(entry), opts) do
      case fill_with_image(board, path, user_uuid, entry) do
        {:ok, board} -> {:ok, board}
        {:error, _} = error -> discard(board, error)
      end
    end
  end

  @doc """
  Makes ONE board out of everything that was pasted or dropped together: any
  number of images (`files`, each `{path, entry}`) and an optional note.

  A lone note or a lone image is exactly `create_note/4` / `create_image/5`.
  Anything else lays the pieces out on the canvas: the note across the top and
  the pictures in a grid under it, each as large as its cell allows. As with a
  single image, if any file cannot be stored the half-made board is removed.

  `{:error, :empty}` when there is neither.
  """
  @spec create_collection(
          Boards.scope(),
          String.t(),
          [{String.t(), map()}],
          String.t() | nil,
          keyword()
        ) :: {:ok, PhoenixKitBoards.Board.t()} | {:error, term()}
  def create_collection(scope, user_uuid, files, text, opts \\ []) do
    note = normalize_note(text || "")

    case {files, note} do
      {[], ""} -> {:error, :empty}
      {[], note} -> create_note(scope, user_uuid, note, opts)
      {[{path, entry}], ""} -> create_image(scope, user_uuid, path, entry, opts)
      _ -> create_many(scope, user_uuid, files, note, opts)
    end
  end

  defp create_many(scope, user_uuid, files, note, opts) do
    name = if note == "", do: image_name(elem(hd(files), 1)), else: note_name(note)

    with {:ok, board} <- create(scope, user_uuid, name, opts) do
      fill_collection(board, files, user_uuid, note)
    end
  end

  defp fill_collection(board, files, user_uuid, note) do
    with {:ok, stored} <- store_all(files, user_uuid, board),
         {:ok, _canvas, board} <- put_shapes(board, layout(stored, note)) do
      {:ok, board}
    else
      {:error, _} = error -> discard(board, error)
    end
  end

  defp store_all(files, user_uuid, board) do
    Enum.reduce_while(files, {:ok, []}, fn {path, entry}, {:ok, acc} ->
      with {:ok, checksum} <- Uploads.file_checksum(path),
           {:ok, file} <- Uploads.store(path, user_uuid, checksum, entry, board),
           url when is_binary(url) <- Storage.get_public_url(file) do
        {:cont, {:ok, [{file, url} | acc]}}
      else
        nil -> {:halt, {:error, :no_url_for_stored_file}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # The room on the canvas for a collection, with a margin all round.
  @margin 500
  @gap 400

  @doc false
  # `stored` is `[{file, url}]`; `note` is already normalised ("" for none).
  # Public so the arrangement can be tested without storage or a database.
  def layout(stored, note) do
    {canvas_w, canvas_h} = Boards.canvas_size()

    {note_shapes, top} =
      case note do
        "" ->
          {[], @margin}

        text ->
          shape = fit_note(note_shape(text), {canvas_w - 2 * @margin, canvas_h * 0.45 - @margin})
          %{"w" => w, "h" => h} = shape["geometry"]
          placed = put_geometry(shape, round((canvas_w - w) / 2), @margin)
          {[placed], @margin + h + @gap}
      end

    count = length(stored)
    cols = columns(count)
    rows = div(count + cols - 1, cols)
    cell_w = (canvas_w - 2 * @margin) / cols
    cell_h = (canvas_h - top - @margin) / rows
    box = {cell_w - @gap, cell_h - @gap}

    pictures =
      stored
      |> Enum.with_index()
      |> Enum.map(fn {{file, url}, index} ->
        shape = image_shape(file, url, box)
        %{"w" => w, "h" => h} = shape["geometry"]
        col = rem(index, cols)
        row = div(index, cols)

        put_geometry(
          shape,
          round(@margin + col * cell_w + (cell_w - w) / 2),
          round(top + row * cell_h + (cell_h - h) / 2)
        )
      end)

    note_shapes ++ pictures
  end

  # Shrink the text and its box together. Clamping only the picture grid's
  # start leaves the long note drawn through the pictures and off the canvas.
  defp fit_note(%{"geometry" => %{"w" => w, "h" => h}} = shape, {max_w, max_h}) do
    font_size = max(1, floor(@font_size * min(1, min(max_w / w, max_h / h))))
    scale = font_size / @font_size

    shape
    |> put_in(["style", "font_size"], font_size)
    |> put_in(["geometry", "w"], round(w * scale))
    |> put_in(["geometry", "h"], round(h * scale))
  end

  defp columns(count) when count <= 3, do: count
  defp columns(4), do: 2
  defp columns(_), do: 3

  defp put_geometry(shape, x, y),
    do: update_in(shape, ["geometry"], &Map.merge(&1, %{"x" => x, "y" => y}))

  defp fill_with_image(board, path, user_uuid, entry) do
    with {:ok, shape} <- store_and_place(path, user_uuid, entry, board),
         {:ok, _canvas, board} <- put_shapes(board, [shape]) do
      {:ok, board}
    end
  end

  defp create(scope, user_uuid, name, opts) do
    {type, id} = scope || {nil, nil}

    attrs = %{
      "name" => name,
      "created_by" => user_uuid,
      "kind" => "quick",
      "visibility" => Keyword.get(opts, :visibility, "shared"),
      "scope_type" => type,
      "scope_id" => id
    }

    Boards.create_board(attrs, Keyword.take(opts, [:folder, :label]))
  end

  defp put_shapes(board, shapes) do
    Boards.save_annotations(board, Boards.load_canvas(board), shapes)
  end

  defp store_and_place(path, user_uuid, entry, board) do
    with {:ok, checksum} <- Uploads.file_checksum(path),
         {:ok, file} <- Uploads.store(path, user_uuid, checksum, entry, board),
         url when is_binary(url) <- Storage.get_public_url(file) do
      {:ok, image_shape(file, url)}
    else
      nil -> {:error, :no_url_for_stored_file}
      {:error, _} = error -> error
    end
  end

  defp discard(board, error) do
    case Boards.delete_board(board) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("[boards] could not remove a half-made quick board: #{inspect(other)}")
    end

    error
  end

  # ── Shapes ────────────────────────────────────────────────────────

  @doc false
  def note_shape(text) do
    lines = wrap(text)
    {canvas_w, canvas_h} = Boards.canvas_size()

    width =
      lines
      |> Enum.map(&String.length/1)
      |> Enum.max(fn -> 1 end)
      |> Kernel.*(@font_size * @glyph_width)

    height = length(lines) * @font_size * @line_height

    %{
      "kind" => "text",
      "uuid" => UUIDv7.generate(),
      "style" => %{"color" => @note_color, "font_size" => @font_size},
      "geometry" => %{
        "x" => round((canvas_w - width) / 2),
        "y" => round((canvas_h - height) / 2),
        "w" => round(width),
        "h" => round(height)
      },
      "metadata" => %{"title" => Enum.join(lines, "\n")}
    }
  end

  @doc false
  def image_shape(file, url, box \\ @image_box) do
    {canvas_w, canvas_h} = Boards.canvas_size()
    {w, h} = fit(file, box)

    %{
      "kind" => "image",
      "uuid" => UUIDv7.generate(),
      "style" => %{"font_size" => 192, "title_point" => true},
      "geometry" => %{
        "x" => round((canvas_w - w) / 2),
        "y" => round((canvas_h - h) / 2),
        "w" => w,
        "h" => h,
        "href" => url
      }
    }
  end

  # The picture's own proportions inside the box. A file whose size storage
  # has not worked out yet (it is measured after upload) is drawn 4:3 rather
  # than refused.
  defp fit(%{width: w, height: h}, {box_w, box_h})
       when is_integer(w) and is_integer(h) and w > 0 and h > 0 do
    scale = min(box_w / w, box_h / h)
    {max(round(w * scale), 1), max(round(h * scale), 1)}
  end

  defp fit(_file, {box_w, box_h}), do: {round(box_w), round(box_h)}

  # Hard-wrapped: point text does not wrap, so a pasted paragraph would run off
  # the canvas as one line.
  defp wrap(text) do
    text
    |> String.split(~r/\R/)
    |> Enum.flat_map(&wrap_line/1)
    |> Enum.take(@max_note_lines)
  end

  defp wrap_line(""), do: [""]

  defp wrap_line(line) do
    line
    |> String.split(" ", trim: true)
    |> Enum.flat_map(&break_long_word/1)
    |> Enum.reduce([], fn word, acc ->
      case acc do
        [current | rest] when byte_size(current) + 1 + byte_size(word) <= @wrap_at ->
          [current <> " " <> word | rest]

        _ ->
          [word | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp break_long_word(word) when byte_size(word) <= @wrap_at, do: [word]

  defp break_long_word(word) do
    word |> String.graphemes() |> Enum.chunk_every(@wrap_at) |> Enum.map(&Enum.join/1)
  end

  defp normalize_note(text) do
    text
    |> String.replace(~r/[^\P{C}\n\t]/u, "")
    |> String.trim()
    |> String.slice(0, @max_note_chars)
  end

  # ── Names ─────────────────────────────────────────────────────────

  defp note_name(text) do
    case text |> String.split(~r/\R/, trim: true) |> List.first() |> clip() do
      "" -> dated("Note")
      name -> name
    end
  end

  defp image_name(%{client_name: name}) when is_binary(name) do
    case name |> Path.basename() |> Path.rootname() |> clip() do
      "" -> dated("Image")
      clean -> clean
    end
  end

  defp image_name(_), do: dated("Image")

  defp clip(nil), do: ""

  defp clip(text) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()

    if String.length(text) > @name_max,
      do: String.slice(text, 0, @name_max - 1) <> "…",
      else: text
  end

  defp dated(what), do: "#{what} · #{Calendar.strftime(DateTime.utc_now(), "%b %-d, %H:%M")}"
end
