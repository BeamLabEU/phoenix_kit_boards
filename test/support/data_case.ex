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
  alias PhoenixKit.Users.{Permissions, Roles}
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

  @doc """
  Gives `user` a role holding `keys` (default: the base `"boards"` key alone,
  which is what an ordinary signed-in user of a host needs) and returns the
  user. `"boards.manage"` brings the base key with it.
  """
  def grant_boards(user, keys \\ ["boards"]) do
    n = System.unique_integer([:positive])
    {:ok, role} = Roles.create_role(%{name: "boards-test-#{n}"})
    {:ok, _} = Roles.assign_role(user, role.name)

    for key <- keys do
      {:ok, _} = Permissions.grant_permission(role.uuid, key, nil)
    end

    user
  end

  @doc "A user with the base `\"boards\"` key: the ordinary signed-in user of a host."
  def board_user_fixture(attrs \\ %{}), do: attrs |> user_fixture() |> grant_boards()

  @doc "A user holding `\"boards.manage\"`: the admin."
  def board_admin_fixture(attrs \\ %{}),
    do: attrs |> user_fixture() |> grant_boards(["boards.manage"])
end
