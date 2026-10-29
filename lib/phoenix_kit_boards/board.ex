defmodule PhoenixKitBoards.Board do
  @moduledoc """
  A collaborative infinite-canvas board.

  The canvas document is a `Fresco.Canvas` (images + `extensions.etcher`
  shapes) serialized into the `data` jsonb column — one board = one row in
  `phoenix_kit_boards`.

  A board optionally **belongs to a place** — a *scope*, the pair
  `{scope_type, scope_id}` (`{"project", uuid}`, `{"page", "/docs/setup"}`) —
  and is either `"shared"` (everyone the host lets see that place) or
  `"private"` (its creator only). Boards with no scope are the global ones the
  admin list has always shown.

  `kind` is `"canvas"` for a board made in the editor and `"quick"` for one made
  by the panel's quick capture; it only changes how the list shows it.

  `folder_uuid` is the board's own media folder, created on the first upload.
  `folder_parent_uuid` is where that folder goes, decided when the board is
  created so a later upload needs no knowledge of the page that made it.
  """
  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_boards" do
    field(:name, :string)
    field(:data, :map, default: %{})
    field(:created_by, :binary_id)
    field(:scope_type, :string)
    field(:scope_id, :string)
    field(:visibility, :string, default: "shared")
    field(:kind, :string, default: "canvas")
    field(:folder_uuid, :binary_id)
    field(:folder_parent_uuid, :binary_id)
    field(:preview, :map)
    field(:pinned_at, :utc_datetime)
    field(:archived_at, :utc_datetime)

    timestamps(type: :utc_datetime_usec)
  end

  @visibilities ~w(private shared)
  @kinds ~w(canvas quick)

  @doc "The values `visibility` can take."
  def visibilities, do: @visibilities

  @doc "The values `kind` can take."
  def kinds, do: @kinds

  @doc "Changeset for creating/renaming a board."
  def changeset(board, attrs) do
    board
    |> cast(attrs, [
      :name,
      :data,
      :created_by,
      :scope_type,
      :scope_id,
      :visibility,
      :kind,
      :folder_parent_uuid
    ])
    |> validate_required([:name, :visibility, :kind])
    |> validate_length(:name, min: 1, max: 200)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_inclusion(:kind, @kinds)
    |> validate_scope()
  end

  # A scope is both halves or neither: a type with no id (or the reverse)
  # names no place, and would list nowhere.
  defp validate_scope(changeset) do
    type = get_field(changeset, :scope_type)
    id = get_field(changeset, :scope_id)

    changeset
    |> validate_length(:scope_type, max: 64)
    |> validate_length(:scope_id, max: 255)
    |> validate_format(:scope_type, ~r/^[a-z][a-z0-9_]*$/)
    |> check_scope_pair(type, id)
  end

  defp check_scope_pair(changeset, nil, nil), do: changeset

  defp check_scope_pair(changeset, type, id) when is_binary(type) and is_binary(id) and id != "",
    do: changeset

  defp check_scope_pair(changeset, _type, _id),
    do: add_error(changeset, :scope_id, "must be set together with the scope type")

  @doc "Changeset for the list-card preview and nothing else."
  def preview_changeset(board, preview) when is_map(preview) or is_nil(preview),
    do: change(board, preview: preview)

  @doc "Changeset for the board's own media folder."
  def folder_changeset(board, folder_uuid), do: change(board, folder_uuid: folder_uuid)

  @doc "Changeset for visibility alone."
  def visibility_changeset(board, visibility) do
    board
    |> change(visibility: visibility)
    |> validate_inclusion(:visibility, @visibilities)
  end

  @doc "Changeset for pinning (`true`) or unpinning (`false`)."
  def pin_changeset(board, true), do: change(board, pinned_at: now())
  def pin_changeset(board, false), do: change(board, pinned_at: nil)

  @doc "Changeset for archiving (`true`) or restoring (`false`)."
  def archive_changeset(board, true), do: change(board, archived_at: now())
  def archive_changeset(board, false), do: change(board, archived_at: nil)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "Changeset that only replaces the persisted canvas document."
  def data_changeset(board, data) when is_map(data) do
    change(board, data: data)
  end
end
