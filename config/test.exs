import Config

# Silence noisy logs during tests.
config :logger, level: :warning

# Integration tests run against a real PostgreSQL database. `PGDATABASE` points
# the suite at a database the test role may not CREATE (a shared instance);
# otherwise it falls back to `phoenix_kit_boards_test`.
config :phoenix_kit_boards, ecto_repos: [PhoenixKitBoards.Test.Repo]

pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_boards_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_boards, PhoenixKitBoards.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool

# `PhoenixKit.RepoHelper` resolves this; without it every context call raises.
config :phoenix_kit, repo: PhoenixKitBoards.Test.Repo
