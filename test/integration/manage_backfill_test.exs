defmodule PhoenixKitBoards.Integration.ManageBackfillTest do
  # `boards.manage` is granted once to every role that held `boards` before the
  # key was split, and `boards_manage_backfilled` records that it happened. The
  # name of that setting is a contract: a host reads it.
  use PhoenixKitBoards.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Permissions, Roles}

  @flag "boards_manage_backfilled"

  setup do
    n = System.unique_integer([:positive])
    {:ok, with_boards} = Roles.create_role(%{name: "with-boards-#{n}"})
    {:ok, without_boards} = Roles.create_role(%{name: "without-boards-#{n}"})
    {:ok, _} = Permissions.grant_permission(with_boards.uuid, "boards", nil)
    {:ok, _} = Permissions.grant_permission(without_boards.uuid, "media", nil)

    # Whatever an earlier test, or the database's own history, left behind.
    Repo.delete_all(from(s in PhoenixKit.Settings.Setting, where: s.key == ^@flag))

    %{with_boards: with_boards, without_boards: without_boards}
  end

  defp keys(role) do
    Repo.all(
      from(rp in PhoenixKit.Users.RolePermission,
        where: rp.role_uuid == ^role.uuid,
        select: rp.module_key
      )
    )
    |> Enum.sort()
  end

  test "the flag is stored the way a host's own migration will read it" do
    assert :ok = PhoenixKitBoards.migrate_legacy()

    assert %{value: "true", module: "boards"} =
             Repo.one!(from(s in PhoenixKit.Settings.Setting, where: s.key == ^@flag))

    assert Settings.get_setting(@flag) == "true"
  end

  test "a role holding boards gets boards.manage; a role without it gets nothing", ctx do
    assert :ok = PhoenixKitBoards.migrate_legacy()

    assert keys(ctx.with_boards) == ["boards", "boards.manage"]
    assert keys(ctx.without_boards) == ["media"]
  end

  test "it is idempotent: a second boot changes nothing", ctx do
    assert :ok = PhoenixKitBoards.migrate_legacy()
    before = Repo.aggregate(PhoenixKit.Users.RolePermission, :count)

    assert :ok = PhoenixKitBoards.migrate_legacy()
    assert Repo.aggregate(PhoenixKit.Users.RolePermission, :count) == before
    assert keys(ctx.with_boards) == ["boards", "boards.manage"]
  end

  test "once the flag is set a revoke sticks and a later `boards` stays narrow", ctx do
    assert :ok = PhoenixKitBoards.migrate_legacy()
    :ok = Permissions.revoke_permission(ctx.with_boards.uuid, "boards.manage")

    {:ok, later} = Roles.create_role(%{name: "later-#{System.unique_integer([:positive])}"})
    {:ok, _} = Permissions.grant_permission(later.uuid, "boards", nil)

    assert :ok = PhoenixKitBoards.migrate_legacy()

    assert keys(ctx.with_boards) == ["boards"]
    assert keys(later) == ["boards"]
  end

  test "a failed grant leaves the flag unset and the next boot finishes the job", ctx do
    failing = fn _role, _key, _by -> {:error, :boom} end

    log =
      capture_log(fn ->
        assert {:error, {:manage_backfill_incomplete, [_ | _]}} =
                 PhoenixKitBoards.backfill_manage_permission(grant: failing)
      end)

    assert log =~ "will retry next boot"
    assert Settings.get_setting(@flag) == nil
    assert keys(ctx.with_boards) == ["boards"]

    assert :ok = PhoenixKitBoards.migrate_legacy()
    assert keys(ctx.with_boards) == ["boards", "boards.manage"]
    assert Settings.get_setting(@flag) == "true"
  end

  test "a failed lookup of the roles raises (`migrate_legacy` rescues it) and leaves the flag unset" do
    boom = fn -> raise "database gone" end

    assert_raise RuntimeError, fn ->
      PhoenixKitBoards.backfill_manage_permission(role_grants: boom)
    end

    assert Settings.get_setting(@flag) == nil
  end

  test "a set flag means nothing is granted, even to a role that holds boards", ctx do
    {:ok, _} = Settings.update_setting_with_module(@flag, "true", "boards")

    assert :ok = PhoenixKitBoards.migrate_legacy()
    assert keys(ctx.with_boards) == ["boards"]
  end
end
