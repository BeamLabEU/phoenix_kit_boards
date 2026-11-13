defmodule PhoenixKitBoards.Integration.AccessTest do
  use PhoenixKitBoards.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBoards.{Access, Boards}

  # Named hooks the config points at.
  defmodule Hooks do
    def allow_alpha(_action, _user, {"project", "alpha"}), do: true
    def allow_alpha(_action, _user, _scope), do: false
    def boom(_action, _user, _scope), do: raise("secret detail")
    def exits(_action, _user, _scope), do: exit(:nope)
    def throws(_action, _user, _scope), do: throw(:nope)
    def not_a_boolean(_action, _user, _scope), do: :yes
    def deny(_action, _user, _scope), do: false

    # Tells the test that it was asked.
    def spy(action, _user, scope) do
      send(Process.get(:spy), {:asked, action, scope})
      true
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_boards, :authorize) end)
    :ok
  end

  defp configure(fun), do: Application.put_env(:phoenix_kit_boards, :authorize, {Hooks, fun})

  test "with no hook, a signed-in user holding the base key may view and create; nobody else" do
    u = board_user_fixture()
    assert Access.can?(:view, u, {"project", "alpha"})
    assert Access.can?(:create, u, nil)
    refute Access.can?(:view, nil, {"project", "alpha"})
  end

  test "a configured hook decides per place" do
    u = board_user_fixture()
    configure(:allow_alpha)
    assert Access.can?(:view, u, {"project", "alpha"})
    refute Access.can?(:view, u, {"project", "beta"})
  end

  for fun <- [:boom, :exits, :throws, :not_a_boolean, :missing] do
    test "a hook that fails (#{fun}) denies and logs without leaking arguments" do
      u = board_user_fixture()
      configure(unquote(fun))

      log = capture_log(fn -> refute Access.can?(:view, u, {"project", "alpha"}) end)

      assert log =~ "refused by default"
      refute log =~ "secret detail"
      refute log =~ u.email
      refute log =~ "alpha"
    end
  end

  test "a malformed config denies" do
    u = board_user_fixture()
    Application.put_env(:phoenix_kit_boards, :authorize, "nope")
    capture_log(fn -> refute Access.can?(:view, u, nil) end)
  end

  describe "the base key (`boards`) and the admin key (`boards.manage`)" do
    @place {"project", "alpha"}

    setup do
      Process.put(:spy, self())
      configure(:spy)
      %{user: board_user_fixture(), admin: board_admin_fixture(), keyless: user_fixture()}
    end

    test "without the base key nothing is allowed and the hook is not asked", ctx do
      refute Access.can?(:view, ctx.keyless, @place)
      refute Access.can?(:create, ctx.keyless, @place)
      refute Access.can_list?(ctx.keyless, @place)
      refute Access.can_list?(ctx.keyless, nil)
      refute_received {:asked, _, _}
    end

    test "with the base key the hook still decides the place", ctx do
      assert Access.can?(:view, ctx.user, @place)
      assert_received {:asked, :view, @place}

      configure(:deny)
      refute Access.can?(:view, ctx.user, @place)
      refute Access.can_list?(ctx.user, @place)
    end

    test "the base key alone is not the admin key", ctx do
      configure(:deny)
      refute Access.admin?(Scope.for_user(ctx.user))
      refute Access.can_list?(ctx.user, nil)
    end

    test "the admin key passes in any place and the hook is not asked", ctx do
      configure(:deny)
      assert Access.can?(:view, ctx.admin, @place)
      assert Access.can?(:create, ctx.admin, {"project", "beta"})
      assert Access.can?(:create, ctx.admin, nil)
      assert Access.can_list?(ctx.admin, @place)
      assert Access.can_list?(ctx.admin, nil)

      configure(:boom)
      assert capture_log(fn -> assert Access.can?(:view, ctx.admin, @place) end) == ""

      configure(:spy)
      assert Access.can?(:view, ctx.admin, @place)
      refute_received {:asked, _, _}
    end

    test "the admin key is granted along with the base key", ctx do
      assert Access.admin?(Scope.for_user(ctx.admin))

      assert Scope.can?(
               Scope.for_user(ctx.admin),
               "boards"
             )
    end

    test "a scope handed in is used instead of building one from the user", ctx do
      scope = Scope.for_user(ctx.admin)
      configure(:deny)

      # The user holds nothing; the scope is what the session carries.
      assert Access.can?(:view, ctx.keyless, @place, scope)
      assert Access.can_list?(ctx.keyless, nil, scope)
    end

    test "a user that is not a persisted user holds nothing", _ctx do
      refute Access.can?(:view, %{uuid: Ecto.UUID.generate()}, @place)
      refute Access.can_list?(%{uuid: Ecto.UUID.generate()}, @place)
      refute Access.can_list?(%{uuid: Ecto.UUID.generate()}, nil)
      refute_received {:asked, _, _}
    end

    test "a disabled module closes the base key too", ctx do
      {:ok, _} = PhoenixKitBoards.disable_system()
      on_exit(fn -> PhoenixKitBoards.enable_system() end)

      refute Access.can?(:view, ctx.user, @place)
      refute Access.can?(:view, ctx.admin, @place)
    end
  end

  describe "can_open?/3" do
    setup do
      owner = board_user_fixture()
      other = board_user_fixture()

      mk = fn attrs ->
        {:ok, board} =
          Boards.create_board(
            Map.merge(
              %{
                "name" => "b",
                "created_by" => owner.uuid,
                "scope_type" => "project",
                "scope_id" => "alpha"
              },
              attrs
            )
          )

        board
      end

      %{owner: owner, other: other, mk: mk}
    end

    test "shared: anyone the host lets in; private: the creator only", ctx do
      shared = ctx.mk.(%{})
      private = ctx.mk.(%{"visibility" => "private"})

      assert Access.can_open?(shared, ctx.other)
      refute Access.can_open?(private, ctx.other)
      assert Access.can_open?(private, ctx.owner)
    end

    test "the host's refusal beats a shared board", ctx do
      configure(:allow_alpha)
      shared_beta = ctx.mk.(%{"scope_id" => "beta"})
      refute Access.can_open?(shared_beta, ctx.other)
    end

    test "the host cannot widen a private board", ctx do
      configure(:allow_alpha)
      refute Access.can_open?(ctx.mk.(%{"visibility" => "private"}), ctx.other)
    end

    test "a board with no place is for admins only", ctx do
      {:ok, unscoped} = Boards.create_board(%{"name" => "global", "created_by" => ctx.owner.uuid})
      refute Access.can_open?(unscoped, ctx.owner)
      refute Access.can_open?(unscoped, ctx.owner, nil)
    end

    # The list must not show what the board page will not open: an unscoped
    # panel used to list the admin boards' names and previews to anyone.
    test "the boards with no place are listed for admins only, too", ctx do
      refute Access.can_list?(ctx.owner, nil)
      refute Access.can_list?(nil, nil)
      assert Access.can_list?(ctx.owner, {"project", "alpha"})

      configure(:allow_alpha)
      refute Access.can_list?(ctx.owner, {"project", "beta"})
    end

    test "without the base key even a shared board in an allowed place does not open", ctx do
      shared = ctx.mk.(%{})
      refute Access.can_open?(shared, user_fixture())
      assert Access.can_open?(shared, ctx.other)
    end

    test "the admin key opens anything: private, unscoped, refused by the host", ctx do
      configure(:deny)
      admin = board_admin_fixture()
      {:ok, unscoped} = Boards.create_board(%{"name" => "global", "created_by" => ctx.owner.uuid})

      assert Access.can_open?(ctx.mk.(%{"visibility" => "private"}), admin)
      assert Access.can_open?(ctx.mk.(%{}), admin)
      assert Access.can_open?(unscoped, admin)
    end

    test "the session's scope is used when given", ctx do
      scope = Scope.for_user(board_admin_fixture())
      private = ctx.mk.(%{"visibility" => "private"})

      assert Access.can_open?(private, ctx.other, scope)
      refute Access.can_open?(private, ctx.other)
    end

    test "nobody signed in opens nothing private", ctx do
      refute Access.can_open?(ctx.mk.(%{"visibility" => "private"}), nil)
    end
  end
end
