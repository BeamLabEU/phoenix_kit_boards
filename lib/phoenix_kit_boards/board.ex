defmodule PhoenixKitBoards.Board do
  @moduledoc """
  A collaborative infinite-canvas board.

  The canvas document is a `Fresco.Canvas` (images + `extensions.etcher`
  shapes) serialized into the `data` jsonb column — one board = one row in
  `phoenix_kit_boards`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "phoenix_kit_boards" do
    field(:name, :string)
    field(:data, :map, default: %{})
    field(:created_by, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for creating/renaming a board."
  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :data, :created_by])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
  end

  @doc "Changeset that only replaces the persisted canvas document."
  def data_changeset(board, data) when is_map(data) do
    change(board, data: data)
  end
end
