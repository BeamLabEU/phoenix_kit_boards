defmodule PhoenixKitBoards.Integration.BoardAccessLifecycleTest do
  use PhoenixKitBoards.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixKitBoards.{Boards, Quick}
  alias PhoenixKitBoards.Test.BoardHostLive

  @endpoint PhoenixKitBoards.Test.Endpoint

  defmodule Deny do
    def can?(_action, _user, _scope), do: false
  end

  setup do
    owner = user_fixture()
    other = user_fixture()
    {:ok, board} = Quick.create_note({"project", "access"}, owner.uuid, "Original")
    on_exit(fn -> Application.delete_env(:phoenix_kit_boards, :authorize) end)
    %{owner: owner, other: other, board: board}
  end

  defp open(board, user) do
    live_isolated(build_conn(), BoardHostLive,
      session: %{"user_uuid" => user.uuid, "board_uuid" => board.uuid}
    )
  end

  test "making a shared board private disconnects an existing viewer", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.other)
    {:ok, _} = Boards.set_visibility(ctx.board, "private", ctx.owner.uuid)
    assert_redirect(lv, "/projects")
  end

  test "the creator stays connected after making their board private", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.owner)
    {:ok, _} = Boards.set_visibility(ctx.board, "private", ctx.owner.uuid)
    assert render(lv) =~ "board-root"
  end

  test "a revoked host permission blocks edits before the access timer", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.other)
    Application.put_env(:phoenix_kit_boards, :authorize, {Deny, :can?})

    assert {:error, {:redirect, %{to: "/projects"}}} =
             render_hook(lv, "etcher:annotations-changed", %{"annotations" => []})

    assert Boards.get_board(ctx.board.uuid).data == ctx.board.data
  end

  test "a revoked viewer receives no subsequent peer annotations", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.other)
    Application.put_env(:phoenix_kit_boards, :authorize, {Deny, :can?})
    send(lv.pid, {:board_annotations, [Quick.note_shape("Secret")], self()})
    assert_redirect(lv, "/projects")
  end

  test "the timer rechecks host access even on an idle board", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.other)
    Application.put_env(:phoenix_kit_boards, :authorize, {Deny, :can?})
    send(lv.pid, :board_access_check)
    assert_redirect(lv, "/projects")
  end

  test "deleting a board disconnects its existing viewers", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.other)
    {:ok, _} = Boards.delete_board(ctx.board)
    assert_redirect(lv, "/projects")
  end
end
