defmodule PhoenixKitBoards.Migrations do
  @moduledoc """
  Versioned migration coordinator for `phoenix_kit_boards` — the module
  returned from `PhoenixKitBoards.migration_module/0`.

  `mix phoenix_kit.update` discovers this, compares `migrated_version_runtime/1`
  (what's installed) with `current_version/0` (what the code needs), and — when
  behind — generates a host migration whose `up/0` calls `up/1` here. So the
  host installs/updates the `phoenix_kit_boards` table with no hand-written
  migration, and it honors the host's `--prefix` (named-schema installs).

  Versions:

    * `0` — table absent (not installed)
    * `1` — `phoenix_kit_boards` table present
  """

  @current_version 1

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc """
  The version currently installed in the database (0 if the table is absent).
  Queried directly via the host repo — runs OUTSIDE a migration.
  """
  @spec migrated_version_runtime(keyword()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")

    if table_exists?(prefix), do: 1, else: 0
  rescue
    _ -> 0
  end

  @doc "Run migrations up to (and including) the target version. Migration-context only."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    if version(opts) >= 1, do: up_v1(prefix)
    :ok
  end

  @doc "Roll back. Migration-context only."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "public")
    # Rolling back below v1 drops the table.
    if version(opts) < 1, do: down_v1(prefix)
    :ok
  end

  # ── v1 ────────────────────────────────────────────────────────────────────

  defp up_v1(prefix) do
    import Ecto.Migration

    create_if_not_exists table(:phoenix_kit_boards, prefix: prefix) do
      add(:name, :string, null: false)
      add(:data, :map, null: false)
      add(:created_by, :binary_id)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp down_v1(prefix) do
    import Ecto.Migration
    drop_if_exists(table(:phoenix_kit_boards, prefix: prefix))
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  # `version` is the target the generated migration passes; default current.
  defp version(opts), do: Keyword.get(opts, :version, @current_version)

  defp table_exists?(prefix) do
    query = """
    SELECT EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = $1 AND table_name = 'phoenix_kit_boards'
    )
    """

    case PhoenixKit.RepoHelper.repo().query(query, [prefix]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end
end
