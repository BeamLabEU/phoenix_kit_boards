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
  def image_shape(file, url) do
    {canvas_w, canvas_h} = Boards.canvas_size()
    {w, h} = fit(file, @image_box)

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

  defp fit(_file, {box_w, box_h}), do: {box_w, box_h}

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
