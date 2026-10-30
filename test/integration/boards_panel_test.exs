defmodule PhoenixKitBoards.Integration.BoardsPanelTest do
  use PhoenixKitBoards.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias PhoenixKit.Modules.Storage.{Folder, ResourceFolders}
  alias PhoenixKitBoards.{Boards, MediaFolders, Quick}
  alias PhoenixKitBoards.Test.HostLive
  alias PhoenixKitBoards.Web.BoardsPanel

  @endpoint PhoenixKitBoards.Test.Endpoint
  @scope {"project", "panel"}

  setup do
    # The test database's bucket writes under a RELATIVE path, i.e. into this
    # repository. Point it at a temp directory for the length of the test (the
    # update is rolled back with the sandbox).
    root =
      Path.join(System.tmp_dir!(), "boards_panel_media_#{System.unique_integer([:positive])}")

    Repo.update_all("phoenix_kit_buckets", set: [endpoint: root])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_boards, :authorize)
      File.rm_rf(root)
    end)

    %{conn: build_conn(), me: user_fixture(), other: user_fixture()}
  end

  defp mount_panel(conn, user, opts \\ []) do
    opts = Keyword.merge([scope: @scope, label: "Panel Co", poll: 0], opts)
    live_isolated(conn, HostLive, session: %{"user_uuid" => user && user.uuid, "opts" => opts})
  end

  # An event as the browser could send it, to the panel (not the host page).
  defp fire(lv, event, params), do: lv |> with_target("#panel") |> render_click(event, params)

  defmodule Spy do
    def can?(action, _user, scope) do
      if pid = Process.get(:spy), do: send(pid, {:asked, action, scope})
      true
    end
  end

  defp board!(user, name, attrs \\ %{}) do
    base = %{
      "name" => name,
      "created_by" => user.uuid,
      "scope_type" => "project",
      "scope_id" => "panel"
    }

    {:ok, board} = Boards.create_board(Map.merge(base, attrs), label: "Panel Co")
    board
  end

  describe "listing" do
    test "shows the place's boards, with the visibility rule", %{conn: conn, me: me, other: other} do
      board!(me, "Mine shared")
      board!(me, "Mine private", %{"visibility" => "private"})
      board!(other, "Theirs shared")
      board!(other, "Theirs private", %{"visibility" => "private"})
      board!(me, "Elsewhere", %{"scope_id" => "other-place"})

      {:ok, _lv, html} = mount_panel(conn, me)

      assert html =~ "Mine shared"
      assert html =~ "Mine private"
      assert html =~ "Theirs shared"
      refute html =~ "Theirs private"
      refute html =~ "Elsewhere"
    end

    test "the heading is the label and the count is shown", %{conn: conn, me: me} do
      board!(me, "One")
      board!(me, "Two")
      {:ok, _lv, html} = mount_panel(conn, me)
      assert html =~ "Panel Co"
      assert html =~ ~r/Panel Co\s*<span[^>]*>\s*2\s*</
    end

    test "show_label: false keeps the label for the folder but does not draw it", %{
      conn: conn,
      me: me
    } do
      board!(me, "One")
      {:ok, _lv, html} = mount_panel(conn, me, show_label: false)
      refute html =~ "Panel Co"
    end

    test "an empty place is just the new-board tile, with its three ways in", %{
      conn: conn,
      me: me
    } do
      {:ok, lv, html} = mount_panel(conn, me)

      assert has_element?(lv, "#panel-new button[phx-click=create_empty]")
      assert has_element?(lv, "#panel-new button[phx-click=text_open]")
      assert has_element?(lv, "#panel-image input[type=file]")
      assert rows(html) == []
    end

    test "with boards, the new-board tile comes after them", %{conn: conn, me: me} do
      board!(me, "First")
      {:ok, _lv, html} = mount_panel(conn, me)
      assert :binary.match(html, "First") < :binary.match(html, ~s(id="panel-new"))
    end

    test "private and quick boards are marked", %{conn: conn, me: me} do
      board!(me, "Hidden", %{"visibility" => "private"})
      {:ok, _lv, html} = mount_panel(conn, me)
      assert html =~ "hero-lock-closed"
    end

    test "pinned boards come first", %{conn: conn, me: me} do
      board!(me, "AAA first made")
      zzz = board!(me, "ZZZ pinned")
      {:ok, _} = Boards.pin(zzz, me.uuid)

      {:ok, _lv, html} = mount_panel(conn, me)
      assert :binary.match(html, "ZZZ pinned") < :binary.match(html, "AAA first made")
    end

    test "without a user it only asks to sign in", %{conn: conn} do
      {:ok, _lv, html} = mount_panel(conn, nil)
      assert html =~ "Sign in"
      refute html =~ "panel-new"
    end

    test "only `limit` boards show, with a way to show them all", %{conn: conn, me: me} do
      for n <- 1..5, do: board!(me, "Board #{n}")
      {:ok, lv, html} = mount_panel(conn, me, limit: 3)

      assert html =~ "Show all 5"
      assert length(rows(html)) == 3

      html = lv |> element("button", "Show all 5") |> render_click()
      assert length(rows(html)) == 5
    end
  end

  describe "a place named the way the host has it" do
    test "an integer id works end to end", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me, scope: {"order", 1001}, open: :new_tab)
      lv |> element("button[phx-click=create_empty]") |> render_click()

      assert [%{scope_type: "order", scope_id: "1001"}] =
               Boards.list_for_scope({"order", "1001"}, me.uuid)

      assert Boards.list_for_scope({"order", 1001}, me.uuid) ==
               Boards.list_for_scope({"order", "1001"}, me.uuid)
    end

    test "atoms work too, as type or id", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me, scope: {:project, :alpha}, open: :new_tab)
      lv |> element("button[phx-click=create_empty]") |> render_click()

      assert [%{scope_type: "project", scope_id: "alpha"}] =
               Boards.list_for_scope({"project", "alpha"}, me.uuid)
    end

    test "the host's hook is given the normalized place", %{conn: conn, me: me} do
      me_pid = self()

      Application.put_env(:phoenix_kit_boards, :authorize, {__MODULE__.Spy, :can?})
      Process.put(:spy, me_pid)
      {:ok, _lv, _html} = mount_panel(conn, me, scope: {"order", 1001})

      assert_received {:asked, :view, {"order", "1001"}}
    end

    test "a place with no id shows nothing — not the boards that belong nowhere", %{
      conn: conn,
      me: me
    } do
      {:ok, _} = Boards.create_board(%{"name" => "Belongs nowhere", "created_by" => me.uuid})

      {:ok, lv, html} = mount_panel(conn, me, scope: {"order", nil})
      refute html =~ "Belongs nowhere"
      refute has_element?(lv, "#panel-new")

      # And a forged event is refused as well.
      fire(lv, "create_empty", %{})
      assert Boards.count_for_scope(nil, me.uuid) == 1
    end

    test "garbage in place of a place shows nothing", %{conn: conn, me: me} do
      for bad <- [{"order"}, "order", 5, {1, 2, 3}, {"", "x"}, {"order", ""}, {"order", %{}}] do
        {:ok, _lv, html} = mount_panel(conn, me, scope: bad)
        refute html =~ "panel-new", "showed something for #{inspect(bad)}"
      end
    end

    test "two widgets on one page, for two places, each its own", %{conn: conn, me: me} do
      board!(me, "Alpha only", %{"scope_id" => "alpha"})
      board!(me, "Beta only", %{"scope_id" => "beta"})

      {:ok, _lv, html} = mount_panel(conn, me, scope: {"project", "alpha"})
      assert html =~ "Alpha only"
      refute html =~ "Beta only"
    end
  end

  describe "the host decides who sees the place" do
    defmodule Deny do
      def can?(_action, _user, _scope), do: false
    end

    defmodule ViewOnly do
      def can?(:view, _user, _scope), do: true
      def can?(:create, _user, _scope), do: false
    end

    test "a refused place renders nothing — not even the heading", %{conn: conn, me: me} do
      board!(me, "Secret place board")
      Application.put_env(:phoenix_kit_boards, :authorize, {Deny, :can?})

      {:ok, _lv, html} = mount_panel(conn, me)
      refute html =~ "Secret place board"
      refute html =~ "Panel Co"
      refute html =~ "panel-new"
    end

    test "view-only users see boards but cannot add any", %{conn: conn, me: me} do
      board!(me, "Visible")
      Application.put_env(:phoenix_kit_boards, :authorize, {ViewOnly, :can?})

      {:ok, lv, html} = mount_panel(conn, me)
      assert html =~ "Visible"
      refute html =~ "panel-new"

      # Not just hidden: a forged event is refused too.
      html = fire(lv, "create_empty", %{})
      assert html =~ "cannot add boards"
      assert Boards.count_for_scope(@scope, me.uuid) == 1
    end
  end

  describe "creating" do
    test "the big + makes an empty quick board in the place and opens it", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me, return_to: "/projects/panel")
      lv |> element("button[phx-click=create_empty]") |> render_click()

      [board] = Boards.list_for_scope(@scope, me.uuid)
      assert board.kind == "quick"
      assert board.name =~ ~r/^Board · /
      assert board.visibility == "shared"
      assert board.created_by == me.uuid
      assert board |> Boards.load_canvas() |> Boards.annotations() == []

      {path, _flash} = assert_redirect(lv)
      assert path =~ "/dashboard/boards/#{board.uuid}"
      assert path =~ "return_to=%2Fprojects%2Fpanel"
    end

    test "open: :new_tab stays on the page and links open in a new tab", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me, open: :new_tab)
      html = lv |> element("button[phx-click=create_empty]") |> render_click()

      assert length(rows(html)) == 1
      assert html =~ ~s(target="_blank")
    end

    test "visibility_options limits the choice, and a forged value is ignored", %{
      conn: conn,
      me: me
    } do
      {:ok, lv, html} =
        mount_panel(conn, me,
          visibility_options: [:private],
          default_visibility: :private,
          open: :new_tab
        )

      refute html =~ "Everyone here"
      refute has_element?(lv, "select[name=visibility]")

      fire(lv, "set_visibility", %{"visibility" => "shared"})
      fire(lv, "create_empty", %{})
      assert [%{visibility: "private"}] = Boards.list_for_scope(@scope, me.uuid)
    end

    test "with both options the person chooses, and the choice applies to what they make", %{
      conn: conn,
      me: me
    } do
      {:ok, lv, _} = mount_panel(conn, me, open: :new_tab)

      lv |> form("#panel-visibility", %{"visibility" => "private"}) |> render_change()
      lv |> element("button[phx-click=create_empty]") |> render_click()

      assert [%{visibility: "private"}] = Boards.list_for_scope(@scope, me.uuid)
    end

    test "the board's folder follows the `folder` option", %{conn: conn, me: me} do
      {:ok, lv, _} =
        mount_panel(conn, me, open: :new_tab, folder: {:path, ["PanelTest", "Files"]})

      fire(lv, "create_empty", %{})
      [board] = Boards.list_for_scope(@scope, me.uuid)
      assert Repo.get!(Folder, board.folder_parent_uuid).name == "Files"
    end

    test "`actions` limits the ways to start a board", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me, actions: [:text])

      assert has_element?(lv, "button[phx-click=text_open]")
      refute has_element?(lv, "button[phx-click=create_empty]")
      refute has_element?(lv, "#panel-image")
    end
  end

  describe "quick capture" do
    test "Text opens a note in the tile; saving makes a board without leaving the page", %{
      conn: conn,
      me: me
    } do
      {:ok, lv, _} = mount_panel(conn, me)

      lv |> element("button[phx-click=text_open]") |> render_click()
      assert has_element?(lv, "#panel-note textarea")

      html = lv |> form("#panel-note", %{"note" => "Remember the milk"}) |> render_submit()

      assert html =~ "Remember the milk"
      refute has_element?(lv, "#panel-note")
      [board] = Boards.list_for_scope(@scope, me.uuid)
      assert board.kind == "quick"
      assert board.preview["text"] == "Remember the milk"
    end

    test "cancelling the note makes nothing", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      lv |> element("button[phx-click=text_open]") |> render_click()
      lv |> element("button[phx-click=text_cancel]") |> render_click()

      refute has_element?(lv, "#panel-note")
      assert Boards.count_for_scope(@scope, me.uuid) == 0
    end

    test "an empty note is refused with a message", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      lv |> element("button[phx-click=text_open]") |> render_click()
      html = lv |> form("#panel-note", %{"note" => "   "}) |> render_submit()
      assert html =~ "Write something first"
      assert Boards.count_for_scope(@scope, me.uuid) == 0
    end

    test "a dropped image becomes a quick board, and its file lands in the board's folder",
         %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)

      # A real (1x1) PNG, so storage has something it can classify.
      png =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        )

      input =
        file_input(lv, "#panel-image", :quick_image, [
          %{name: "My Screenshot.png", content: png, type: "image/png"}
        ])

      render_upload(input, "My Screenshot.png")

      assert [board] = Boards.list_for_scope(@scope, me.uuid)
      assert board.kind == "quick"
      assert board.name == "My Screenshot"
      assert board.preview["image_url"] =~ "/file/"
      assert board.preview["count"] == 1

      # The file is in the board's own folder, under the place's, not loose.
      folder = MediaFolders.board_folder(board)
      assert folder.name == "My Screenshot"
      assert [file] = ResourceFolders.list_files(folder.uuid)
      assert file.folder_uuid == folder.uuid

      assert Repo.get!(
               Folder,
               folder.parent_uuid
             ).name == "Panel Co"

      assert render(lv) =~ "My Screenshot"
    end

    test "a failed quick image reports it and leaves nothing behind", %{conn: conn, me: me} do
      # A bucket that cannot be written to (rolled back with the sandbox); the
      # half-made board must go.
      Repo.update_all("phoenix_kit_buckets", set: [endpoint: "/proc/1/no-such-dir"])
      {:ok, lv, _} = mount_panel(conn, me)

      input =
        file_input(lv, "#panel-image", :quick_image, [
          %{name: "doomed.png", content: "bytes", type: "image/png"}
        ])

      render_upload(input, "doomed.png")

      assert Boards.count_for_scope(@scope, me.uuid) == 0
      assert render(lv) =~ "Could not save the image"
    end

    test "only images are accepted", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)

      input =
        file_input(lv, "#panel-image", :quick_image, [
          %{name: "evil.exe", content: "MZ", type: "application/octet-stream"}
        ])

      assert {:error, [[_, :not_accepted]]} = render_upload(input, "evil.exe")
    end
  end

  describe "row actions" do
    test "rename", %{conn: conn, me: me} do
      board = board!(me, "Old name")
      {:ok, lv, _} = mount_panel(conn, me)

      lv
      |> element(~s(button[phx-click=rename_start][phx-value-id="#{board.uuid}"]))
      |> render_click()

      html =
        lv |> form("form[phx-submit=rename_save]", %{"name" => "New name"}) |> render_submit()

      assert html =~ "New name"
      assert Boards.get_board(board.uuid).name == "New name"
    end

    test "pin and unpin", %{conn: conn, me: me} do
      board = board!(me, "Pin me")
      {:ok, lv, _} = mount_panel(conn, me)

      lv |> element(~s(button[phx-click=pin][phx-value-id="#{board.uuid}"])) |> render_click()
      assert Boards.get_board(board.uuid).pinned_at

      lv |> element(~s(button[phx-click=unpin][phx-value-id="#{board.uuid}"])) |> render_click()
      refute Boards.get_board(board.uuid).pinned_at
    end

    test "the creator can make a board private and shared again", %{conn: conn, me: me} do
      board = board!(me, "Toggle")
      {:ok, lv, _} = mount_panel(conn, me)

      lv
      |> element(~s(button[phx-click=board_visibility][phx-value-to=private]))
      |> render_click()

      assert Boards.get_board(board.uuid).visibility == "private"

      lv |> element(~s(button[phx-click=board_visibility][phx-value-to=shared])) |> render_click()
      assert Boards.get_board(board.uuid).visibility == "shared"
    end

    test "archive hides the board", %{conn: conn, me: me} do
      board = board!(me, "Archive me")
      {:ok, lv, _} = mount_panel(conn, me)
      html = lv |> element(~s(button[phx-click=archive])) |> render_click()

      refute html =~ "Archive me"
      assert Boards.get_board(board.uuid).archived_at
    end

    test "delete removes the board", %{conn: conn, me: me} do
      board = board!(me, "Delete me")
      {:ok, lv, _} = mount_panel(conn, me)
      html = lv |> element(~s(button[phx-click=delete])) |> render_click()

      refute html =~ "Delete me"
      assert Boards.get_board(board.uuid) == nil
    end

    test "someone else's shared board offers pin, but not rename, share, archive or delete",
         %{conn: conn, me: me, other: other} do
      board!(other, "Not mine")
      {:ok, lv, _} = mount_panel(conn, me)

      assert has_element?(lv, "button[phx-click=pin]")
      refute has_element?(lv, "button[phx-click=rename_start]")
      refute has_element?(lv, "button[phx-click=board_visibility]")
      refute has_element?(lv, "button[phx-click=archive]")
      refute has_element?(lv, "button[phx-click=delete]")
    end
  end

  describe "forged events" do
    test "acting on someone else's board is refused", %{conn: conn, me: me, other: other} do
      theirs = board!(other, "Theirs")
      {:ok, lv, _} = mount_panel(conn, me)

      for {event, params} <- [
            {"rename_save", %{"board_id" => theirs.uuid, "name" => "Hijacked"}},
            {"delete", %{"id" => theirs.uuid}},
            {"archive", %{"id" => theirs.uuid}},
            {"board_visibility", %{"id" => theirs.uuid, "to" => "private"}}
          ] do
        html = fire(lv, event, params)
        assert html =~ "Only the board&#39;s creator", "#{event} was not refused"
      end

      board = Boards.get_board(theirs.uuid)
      assert board.name == "Theirs"
      assert board.visibility == "shared"
      refute board.archived_at
    end

    test "a board from another place cannot be touched through this panel",
         %{conn: conn, me: me} do
      elsewhere = board!(me, "Elsewhere", %{"scope_id" => "another"})
      {:ok, lv, _} = mount_panel(conn, me)

      html = fire(lv, "delete", %{"id" => elsewhere.uuid})
      assert html =~ "no longer available"
      assert Boards.get_board(elsewhere.uuid)
    end

    test "someone else's private board does not exist for this panel", %{
      conn: conn,
      me: me,
      other: other
    } do
      secret = board!(other, "Secret", %{"visibility" => "private"})
      {:ok, lv, _} = mount_panel(conn, me)

      html = fire(lv, "pin", %{"id" => secret.uuid})
      assert html =~ "no longer available"
      refute Boards.get_board(secret.uuid).pinned_at
    end

    test "garbage ids are survivable", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me)
      assert fire(lv, "delete", %{"id" => "not-a-uuid"}) =~ "no longer available"
    end
  end

  describe "staying current" do
    test "refresh/1 re-reads the list", %{conn: conn, me: me, other: other} do
      {:ok, lv, html} = mount_panel(conn, me)
      refute html =~ "Appears later"

      board!(other, "Appears later")
      BoardsPanel.refresh("panel", lv.pid)
      assert render(lv) =~ "Appears later"
    end

    test "the timer picks up other people's boards on its own", %{
      conn: conn,
      me: me,
      other: other
    } do
      {:ok, lv, _} = mount_panel(conn, me, poll: 50)
      board!(other, "Found by polling")

      assert eventually(fn -> render(lv) =~ "Found by polling" end)
    end

    test "a board someone makes private disappears from the others' lists",
         %{conn: conn, me: me, other: other} do
      theirs = board!(other, "Going dark")
      {:ok, lv, html} = mount_panel(conn, me, poll: 50)
      assert html =~ "Going dark"

      {:ok, _} = Boards.set_visibility(theirs, "private", other.uuid)
      assert eventually(fn -> not (render(lv) =~ "Going dark") end)
    end

    test "re-renders by the host do not start more timers", %{conn: conn, me: me} do
      {:ok, lv, _} = mount_panel(conn, me, poll: 50)
      for _ <- 1..5, do: send(lv.pid, :host_rerender)
      Process.sleep(200)
      assert Process.alive?(lv.pid)
    end
  end

  test "a quick board made elsewhere shows with its note as the preview", %{conn: conn, me: me} do
    {:ok, _} = Quick.create_note(@scope, me.uuid, "Preview me please")
    {:ok, _lv, html} = mount_panel(conn, me)
    assert html =~ "Preview me please"
  end

  # One match per board row (names also turn up in aria-labels).
  defp rows(html), do: Regex.scan(~r/<li id="panel-[0-9a-f-]{36}"/, html)

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end
end
