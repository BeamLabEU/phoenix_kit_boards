defmodule PhoenixKitBoards.DataCase do
  @moduledoc """
  Test case for tests that hit the database.

  Tests using this case are tagged `:integration` and are excluded
  automatically when PostgreSQL is unavailable, so `mix test` still runs the
  unit half on a machine with no database.

      defmodule PhoenixKitBoards.Integration.SomethingTest do
        use PhoenixKitBoards.DataCase, async: true
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import Ecto.Query
      import PhoenixKitBoards.DataCase

      alias PhoenixKitBoards.Test.Repo
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBoards.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "A persisted, confirmed user (inserted directly: registration needs the rate limiter)."
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    %PhoenixKit.Users.Auth.User{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          email: "boards-#{n}@example.com",
          hashed_password: Bcrypt.hash_pwd_salt("ValidPassword123!"),
          confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          is_active: true
        },
        attrs
      )
    )
    |> TestRepo.insert!()
  end
end
