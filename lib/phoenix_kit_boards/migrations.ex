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

    case read_version(repo(), opts.escaped_prefix) do
      # Refuse rather than stamp a version onto a table we don't recognise.
      # `create_if_not_exists` cannot reshape it, so continuing would report
      # success and leave the app to crash on the first query instead.
      :incompatible ->
        raise incompatible_table_error(opts.prefix)

      0 ->
        change(@initial_version..opts.version, :up, opts)

      initial when initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      initial ->
        # Already stamped at or beyond the target. Re-stamp anyway: an
        # unstamped table that matched a known shape resolved to a version by
        # inspection, and this writes that conclusion down so the next read
        # doesn't have to infer it again.
        #
        # `max/2`, not `opts.version`: the table can be *ahead* of the target
        # (`up(version: 1)` against a V2 install runs no steps), and stamping
        # the target there would label a V2 table "1" — the same "a version
        # this table does not have" lie the `:incompatible` clause refuses.
        record_version(opts, max(initial, opts.version))
    end

    :ok
  end

  @doc "Roll back. Migration-context only."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    opts = with_defaults(opts, 0)
    target = Map.get(opts, :version, 0)

    # An unrecognised table still has to be droppable — refusing here would
    # leave no way back out of the very state `up/1` rejects.
    current =
      case read_version(repo(), opts.escaped_prefix) do
        :incompatible -> @current_version
        version -> version
      end

    if current > target, do: change(current..(target + 1)//-1, :down, opts)

    :ok
  end

  @doc """
  The version currently installed in the database — 0 if the table is absent,
  and also 0 if it exists but matches no version this module knows how to
  produce. `up/1` raises with the details for that second case rather than
  migrating an unrecognised table blindly.
  Migration-context only — reads via `Ecto.Migration.repo/0`.
  """
  @spec migrated_version(keyword()) :: non_neg_integer()
  def migrated_version(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    normalize_version(read_version(repo(), opts.escaped_prefix))
  end

  @doc """
  Runtime-safe version of `migrated_version/1` — uses PhoenixKit's configured
  repo instead of the `Ecto.Migration` `repo()` helper, so it can be called
  from Mix tasks and other non-migration contexts (`mix phoenix_kit.update`).
  """
  @spec migrated_version_runtime(keyword()) :: non_neg_integer()
  def migrated_version_runtime(opts \\ []) do
    opts = with_defaults(opts, @initial_version)
    normalize_version(read_version(PhoenixKit.RepoHelper.repo(), opts.escaped_prefix))
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

  # `:incompatible` reported to callers that must return a plain integer.
  # Reporting 0 ("not installed") is right for them: `mix phoenix_kit.update`
  # then generates a migration, and running it surfaces the real problem
  # through `up/1`'s raise, with instructions.
  defp normalize_version(:incompatible), do: 0
  defp normalize_version(version) when is_integer(version), do: version

  # The installed version, or `:incompatible` when the table exists but
  # matches no version this module knows how to produce.
  #
  # The `COMMENT ON TABLE` marker is the source of truth, but it can be
  # missing: a table created before stamping existed, or restored by a dump
  # that dropped comments. That case used to fall back to a hardcoded `1`,
  # which asserted "already current" about a table nobody had checked —
  # `mix phoenix_kit.update` then generated nothing, `create_if_not_exists`
  # made a forced re-run a no-op, and the mismatch only surfaced at runtime
  # as `column p0.uuid does not exist`, with no upgrade path out of it.
  #
  # An unstamped table is now resolved by looking at its actual columns, so
  # the answer is derived rather than assumed. Note that guessing `0` instead
  # would be its own bug: `up/1` would run V1, `create_if_not_exists` would
  # skip the existing table, and the stamp would go on regardless — marking a
  # wrong-shaped table as correct.
  defp read_version(repo, escaped_prefix) do
    if table_exists?(repo, escaped_prefix) do
      case stamped_version(repo, escaped_prefix) do
        {:ok, version} -> version
        :unstamped -> infer_version(repo, escaped_prefix)
      end
    else
      0
    end
  end

  defp table_exists?(repo, escaped_prefix) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.tables
      WHERE table_name = '#{@version_table}'
      AND table_schema = '#{escaped_prefix}'
    )
    """

    match?({:ok, %{rows: [[true]]}}, repo.query(query, [], log: false))
  end

  defp stamped_version(repo, escaped_prefix) do
    query = """
    SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
    FROM pg_class
    LEFT JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
    WHERE pg_class.relname = '#{@version_table}'
    AND pg_namespace.nspname = '#{escaped_prefix}'
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[comment]]}} -> parse_version_comment(comment)
      _ -> :unstamped
    end
  end

  @doc false
  # A comment that isn't a bare integer is somebody else's annotation, not our
  # marker — treated as unstamped rather than crashing on `String.to_integer/1`.
  def parse_version_comment(comment) when is_binary(comment) do
    case Integer.parse(String.trim(comment)) do
      {version, ""} when version >= 0 -> {:ok, version}
      _ -> :unstamped
    end
  end

  def parse_version_comment(_), do: :unstamped

  # Match the table against the shape of each known version, newest first.
  # V1 is identified by its UUIDv7 primary key — the column the pre-release
  # `bigserial :id` schema lacks.
  defp infer_version(repo, escaped_prefix) do
    if column_exists?(repo, escaped_prefix, "uuid"), do: 1, else: :incompatible
  end

  defp column_exists?(repo, escaped_prefix, column) do
    query = """
    SELECT EXISTS (
      SELECT FROM information_schema.columns
      WHERE table_name = '#{@version_table}'
      AND table_schema = '#{escaped_prefix}'
      AND column_name = '#{column}'
    )
    """

    match?({:ok, %{rows: [[true]]}}, repo.query(query, [], log: false))
  end

  defp incompatible_table_error(prefix) do
    """
    #{@version_table} exists in schema "#{prefix}" but does not match any \
    known version of this module's schema, and carries no version comment.

    This is the pre-release table with a bigserial `id` primary key; the \
    current schema uses a UUIDv7 `uuid` primary key. Migrating in place is not \
    attempted because the table may hold data only you can judge.

    To resolve, either drop it and re-run the migration:

        DROP TABLE #{prefix}.#{@version_table};

    or, to keep existing rows, copy them across afterwards:

        CREATE TABLE #{@version_table}_backup AS SELECT * FROM #{prefix}.#{@version_table};
        DROP TABLE #{prefix}.#{@version_table};
        -- re-run the migration, then:
        INSERT INTO #{prefix}.#{@version_table} (uuid, name, data, created_by, inserted_at, updated_at)
        SELECT uuid_generate_v7(), name, data, created_by, inserted_at, updated_at
        FROM #{@version_table}_backup;
    """
  end
end
