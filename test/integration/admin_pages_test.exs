defmodule PhoenixKitBoards.Integration.AdminPagesTest do
  # `/admin/boards` and `/admin/boards/:id` cannot be tied to `boards.manage`
  # by core, so the pages refuse for themselves.
  use PhoenixKitBoards.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixKitBoards.{Boards, Quick}
  alias PhoenixKitBoards.Test.AdminHostLive

  @endpoint PhoenixKitBoards.Test.Endpoint
  @admin_home PhoenixKitBoards.Paths.admin()

  setup do
    owner = board_user_fixture()
    {:ok, board} = Quick.create_note({"project", "admin-pages"}, owner.uuid, "Plan")

    root =
      Path.join(System.tmp_dir!(), "boards_admin_media_#{System.unique_integer([:positive])}")

    Repo.update_all("phoenix_kit_buckets", set: [endpoint: root])
    on_exit(fn -> File.rm_rf(root) end)

    %{owner: owner, board: board}
  end

  defp open(page, user, board \\ nil) do
    live_isolated(build_conn(), AdminHostLive,
      session: %{"user_uuid" => user.uuid, "page" => page, "board_uuid" => board && board.uuid}
    )
  end

  describe "the boards list" do
    test "the base key without manage is sent away", %{owner: owner} do
      assert {:error, {:live_redirect, %{to: @admin_home, flash: %{"error" => _}}}} =
               open("index", owner)
    end

    test "a user without any boards key is sent away" do
      assert {:error, {:live_redirect, %{to: @admin_home, flash: %{"error" => _}}}} =
               open("index", user_fixture())
    end

    test "boards.manage opens it, and it lists the boards", %{board: board} do
      {:ok, _lv, html} = open("index", board_admin_fixture())
      assert html =~ board.name
    end

    test "a refused visit lists nothing and creates nothing", %{owner: owner} do
      before = length(Boards.list_boards(include_data: false))
      assert {:error, {:live_redirect, _}} = open("index", owner)
      assert length(Boards.list_boards(include_data: false)) == before
    end
  end

  # Core rebuilds the scope in the page's assigns when roles change; the page
  # asks it again, so an open page does not outlive the key.
  describe "boards.manage taken away from an open page" do
    defp refresh_scope(lv, user),
      do: send(lv.pid, {:phoenix_kit_scope_roles_updated, user.uuid})

    test "the list stops answering events" do
      admin = board_admin_fixture()
      {:ok, lv, _} = open("index", admin)
      before = length(Boards.list_boards(include_data: false))

      revoke_boards(admin, ["boards.manage"])
      refresh_scope(lv, admin)

      assert {:error, {:live_redirect, %{to: @admin_home}}} = render_hook(lv, "create", %{})
      assert length(Boards.list_boards(include_data: false)) == before
    end

    test "the list still answers while the key is held" do
      {:ok, lv, _} = open("index", board_admin_fixture())
      render_hook(lv, "create", %{})
      assert length(Boards.list_boards(include_data: false)) >= 2
    end

    test "a board page is left on the next check", %{board: board} do
      admin = board_admin_fixture()
      {:ok, lv, _} = open("show", admin, board)

      revoke_boards(admin, ["boards.manage"])
      refresh_scope(lv, admin)
      send(lv.pid, :board_access_check)

      assert_redirect(lv, @admin_home)
    end

    test "a board page is left on its next event, before the timer", %{board: board} do
      admin = board_admin_fixture()
      {:ok, lv, _} = open("show", admin, board)

      revoke_boards(admin, ["boards.manage"])
      refresh_scope(lv, admin)

      assert {:error, {:live_redirect, %{to: @admin_home}}} =
               render_hook(lv, "etcher:annotations-changed", %{"annotations" => []})

      assert Boards.get_board(board.uuid).data == board.data
    end
  end

  describe "a board page" do
    test "the base key without manage is sent away, even for a board of the user's own",
         %{owner: owner, board: board} do
      assert {:error, {:live_redirect, %{to: @admin_home, flash: %{"error" => _}}}} =
               open("show", owner, board)
    end

    test "a user without any boards key is sent away", %{board: board} do
      assert {:error, {:live_redirect, %{to: @admin_home, flash: %{"error" => _}}}} =
               open("show", user_fixture(), board)
    end

    test "boards.manage opens it", %{board: board} do
      {:ok, _lv, html} = open("show", board_admin_fixture(), board)
      assert html =~ "board-root"
    end

    test "boards.manage opens a private board of somebody else", %{owner: owner} do
      {:ok, board} =
        Quick.create_note({"project", "admin-pages"}, owner.uuid, "Mine", visibility: "private")

      {:ok, _lv, html} = open("show", board_admin_fixture(), board)
      assert html =~ "board-root"
    end
  end
end
