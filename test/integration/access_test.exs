defmodule PhoenixKitBoards.Integration.AccessTest do
  use PhoenixKitBoards.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitBoards.{Access, Boards}

  # Named hooks the config points at.
  defmodule Hooks do
    def allow_alpha(_action, _user, {"project", "alpha"}), do: true
    def allow_alpha(_action, _user, _scope), do: false
    def boom(_action, _user, _scope), do: raise("secret detail")
    def exits(_action, _user, _scope), do: exit(:nope)
    def throws(_action, _user, _scope), do: throw(:nope)
    def not_a_boolean(_action, _user, _scope), do: :yes
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_boards, :authorize) end)
    :ok
  end

  defp configure(fun), do: Application.put_env(:phoenix_kit_boards, :authorize, {Hooks, fun})

  test "with no hook, any signed-in user may view and create; nobody else" do
    u = user_fixture()
    assert Access.can?(:view, u, {"project", "alpha"})
    assert Access.can?(:create, u, nil)
    refute Access.can?(:view, nil, {"project", "alpha"})
  end

  test "a configured hook decides per place" do
    u = user_fixture()
    configure(:allow_alpha)
    assert Access.can?(:view, u, {"project", "alpha"})
    refute Access.can?(:view, u, {"project", "beta"})
  end

  for fun <- [:boom, :exits, :throws, :not_a_boolean, :missing] do
    test "a hook that fails (#{fun}) denies and logs without leaking arguments" do
      u = user_fixture()
      configure(unquote(fun))

      log = capture_log(fn -> refute Access.can?(:view, u, {"project", "alpha"}) end)

      assert log =~ "refused by default"
      refute log =~ "secret detail"
      refute log =~ u.email
      refute log =~ "alpha"
    end
  end

  test "a malformed config denies" do
    u = user_fixture()
    Application.put_env(:phoenix_kit_boards, :authorize, "nope")
    capture_log(fn -> refute Access.can?(:view, u, nil) end)
  end

  describe "can_open?/3" do
    setup do
      owner = user_fixture()
      other = user_fixture()

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

    test "nobody signed in opens nothing private", ctx do
      refute Access.can_open?(ctx.mk.(%{"visibility" => "private"}), nil)
    end
  end
end
