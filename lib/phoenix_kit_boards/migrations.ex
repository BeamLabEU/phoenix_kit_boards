defmodule PhoenixKitBoards.Migrations do
  @moduledoc """
  Versioned migration coordinator for `phoenix_kit_boards` — the module
  returned from `PhoenixKitBoards.migration_module/0`.

  `mix phoenix_kit.update` discovers this, compares `migrated_version_runtime/1`
  (what's installed) with `current_version/0` (what the code needs), and — when
  behind — generates a host migration whose `up/0` calls `up/1` here. So the
  host installs/updates the `phoenix_kit_boards` table with no hand-written
  migration, and it honors the host's `--prefix` (named-schema installs).

  Version is tracked via a `COMMENT ON TABLE` on `phoenix_kit_boards` itself
  (mirroring core's own `PhoenixKit.Migrations.Postgres` and the pattern
  documented in `phoenix_kit_hello_world`'s README "Versioned migrations"
  section) — not just a boolean "does the table exist", so a future V2 can
  tell "not installed" apart from "installed at V1".

  Versions:

    * `0` — table absent (not installed)
    * `1` — `phoenix_kit_boards` table present, UUIDv7 primary key
  """

  use Ecto.Migration

  alias PhoenixKit.Migrations.Postgres.Helpers

  @initial_version 1
  @current_version 1
  @default_prefix "public"
  @version_table "phoenix_kit_boards"

  @doc "The version this code expects the schema to be at."
  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "Run migrations up to (and including) the target version. Migration-context only."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 -> change(@initial_version..opts.version, :up, opts)
      initial < opts.version -> change((initial + 1)..opts.version, :up, opts)
      true -> :ok
    end

    :ok
  end

  @doc "Roll back. Migration-context only."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)
    current = migrated_version(opts)
    target = Map.get(opts, :version, 0)

    if current > target, do: change(current..(target + 1)//-1, :down, opts)

    :ok
  end

  @doc """
  The version currently installed in the database (0 if the table is absent).
  Migration-context only — reads via `Ecto.Migration.repo/0`.
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(repo(), opts.escaped_prefix)
  end

  @doc """
  Runtime-safe version of `migrated_version/1` — uses PhoenixKit's configured
  repo instead of the `Ecto.Migration` `repo()` helper, so it can be called
  from Mix tasks and other non-migration contexts (`mix phoenix_kit.update`).
  """
  @spec migrated_version_runtime(keyword()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    read_version(PhoenixKit.RepoHelper.repo(), opts.escaped_prefix)
  rescue
    _ -> 0
  end

  # ── v1 ────────────────────────────────────────────────────────────────────

  defp up_v1(prefix) do
    create_if_not_exists table(:phoenix_kit_boards, primary_key: false, prefix: prefix) do
      add(:uuid, :uuid,
        primary_key: true,
        null: false,
        default: fragment(Helpers.uuid_v7_call(prefix))
      )

      add(:name, :string, null: false)
      add(:data, :map, null: false)
      add(:created_by, :binary_id)

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp down_v1(prefix) do
    drop_if_exists(table(:phoenix_kit_boards, prefix: prefix))
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp change(range, direction, opts) do
    Enum.each(range, fn
      1 -> apply_step(direction, opts.prefix)
    end)

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, max(Enum.min(range) - 1, 0))
    end
  end

  defp apply_step(:up, prefix), do: up_v1(prefix)
  defp apply_step(:down, prefix), do: down_v1(prefix)

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute("COMMENT ON TABLE #{Helpers.qualify_table(@version_table, prefix)} IS '#{version}'")
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    opts
    |> Map.put(:quoted_prefix, inspect(opts.prefix))
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
  end

  defp read_version(repo, escaped_prefix) do
    table_exists_query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{@version_table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    case repo.query(table_exists_query, [], log: false) do
      {:ok, %{rows: [[true]]}} ->
        version_query = """
        SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
        FROM pg_class
        LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
        WHERE pg_class.relname = '#{@version_table}'
        AND pg_namespace.nspname = '#{escaped_prefix}'
        """

        case repo.query(version_query, [], log: false) do
          {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
          _ -> 1
        end

      _ ->
        0
    end
  end
end
