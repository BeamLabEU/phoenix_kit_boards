# Two levels:
#
#   * unit — always run, no database.
#   * integration — tagged `:integration` via `PhoenixKitBoards.DataCase`,
#     excluded automatically when PostgreSQL is unavailable.
#
# The schema is built by `PhoenixKit.Migration.ensure_current/2` first (core's
# users/storage/settings tables), then this module's own chain on top.

alias PhoenixKitBoards.Test.Repo, as: TestRepo

db_name = Application.get_env(:phoenix_kit_boards, TestRepo)[:database]

repo_available =
  try do
    {:ok, _} = TestRepo.start_link()
    # Connections are lazy; only this probe may exclude integration tests.
    TestRepo.query!("SELECT 1")
    true
  rescue
    e in [DBConnection.ConnectionError, Postgrex.Error] ->
      IO.puts("""

        Integration tests excluded — could not reach "#{db_name}".
        Set PGHOST/PGUSER/PGPASSWORD/PGDATABASE, or: createdb #{db_name}

        (#{Exception.message(e)})
      """)

      false
  end

if repo_available do
  {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: PhoenixKit.PubSub)

  # Settings reads go through core's cache and announce changes on its internal
  # PubSub; without them every setting access logs two warnings.
  {:ok, _} = PhoenixKit.Cache.Registry.start_link()
  {:ok, _} = PhoenixKit.PubSub.Manager.start_link([])
  {:ok, _} = PhoenixKit.Cache.start_link(name: :settings)

  # Cleared BEFORE core's chain runs: a leftover row with a later version
  # makes Ecto warn about every core migration that sorts before it.
  boards_version = 9_000_000_000_000_001

  if TestRepo.query!("SELECT to_regclass('schema_migrations')").rows != [[nil]] do
    TestRepo.query!("DELETE FROM schema_migrations WHERE version = $1", [boards_version])
  end

  PhoenixKit.Migration.ensure_current(TestRepo, log: false)

  # Re-run every time (the row is cleared first): `up/1` is idempotent through
  # its own version stamp, and a tracked `:already_up` would never pick up a
  # newer version of the chain. The version sorts after core's timestamps.
  Ecto.Migrator.up(TestRepo, boards_version, PhoenixKitBoards.Test.MigrateBoards, log: false)

  {:ok, _} = PhoenixKitBoards.Test.Endpoint.start_link()

  Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)

  ExUnit.start()
else
  ExUnit.start(exclude: [:integration])
end
