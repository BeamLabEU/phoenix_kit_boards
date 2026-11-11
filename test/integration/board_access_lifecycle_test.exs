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

  defmodule EditDuringMount do
    def can?(:view, user, scope) do
      unless Process.get(__MODULE__) do
        Process.put(__MODULE__, :saved)

        Task.async(fn ->
          [board] = Boards.list_for_scope(scope, user.uuid)
          base = Boards.annotations(Boards.load_canvas(board))

          {:ok, _, _, _, delta} =
            Boards.apply_edit(board, base, base ++ [Quick.note_shape("Saved during mount")])

          Phoenix.PubSub.broadcast(
            PhoenixKit.PubSubHelper.pubsub(),
            "phoenix_kit_boards:#{board.uuid}",
            {:board_delta, delta, self()}
          )
        end)
        |> Task.await()
      end

      true
    end
  end

  setup do
    owner = user_fixture()
    other = user_fixture()
    {:ok, board} = Quick.create_note({"project", "access"}, owner.uuid, "Original")

    # The test database's bucket writes under a RELATIVE path, i.e. into this
    # repository. Point it at a temp directory for the length of the test (the
    # update is rolled back with the sandbox).
    root =
      Path.join(System.tmp_dir!(), "boards_access_media_#{System.unique_integer([:positive])}")

    Repo.update_all("phoenix_kit_buckets", set: [endpoint: root])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_boards, :authorize)
      File.rm_rf(root)
    end)

    %{owner: owner, other: other, board: board}
  end

  defp open(board, user) do
    live_isolated(build_conn(), BoardHostLive,
      session: %{"user_uuid" => user.uuid, "board_uuid" => board.uuid}
    )
  end

  # The avatar title and cursor label every other viewer gets. Since the user
  # route, those viewers are not all admins — and it was the email address.
  test "peers are shown a display name, never the email address", ctx do
    Phoenix.PubSub.subscribe(
      PhoenixKit.PubSubHelper.pubsub(),
      "phoenix_kit_boards:#{ctx.board.uuid}"
    )

    {:ok, _lv, html} = open(ctx.board, ctx.other)
    [local, _domain] = String.split(ctx.other.email, "@")

    assert_receive {:board_join, %{name: name}, _from}
    assert name == local
    refute html =~ ctx.other.email
    assert html =~ "#{local} (you)"
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
    send(lv.pid, {:board_delta, %{"created" => [Quick.note_shape("Secret")]}, self()})
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

  test "an edit saved during mount reaches the new viewer", ctx do
    Application.put_env(:phoenix_kit_boards, :authorize, {EditDuringMount, :can?})

    # Use a noncanonical spelling to exercise the topic's UUID normalization.
    {:ok, lv, _} = open(%{ctx.board | uuid: String.upcase(ctx.board.uuid)}, ctx.owner)

    [_, added] =
      ctx.board.uuid |> Boards.get_board() |> Boards.load_canvas() |> Boards.annotations()

    render_hook(lv, "board:ready", %{"source" => "cursors"})
    assert_push_event(lv, "board:channel", %{})
    refute_push_event(lv, "board:apply", %{})

    render_hook(lv, "board:ready", %{})
    assert_push_event(lv, "board:apply", %{"created" => [^added]})

    render_hook(lv, "board:ready", %{})
    refute_push_event(lv, "board:apply", %{})
  end

  test "delayed peer messages cannot roll a viewer back from the committed board", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.owner)
    render_hook(lv, "board:ready", %{})
    base = Boards.annotations(Boards.load_canvas(ctx.board))
    first = put_in(hd(base), ["metadata", "title"], "First edit")
    last = put_in(first, ["metadata", "title"], "Latest edit")
    {:ok, _, _, _, early} = Boards.apply_edit(ctx.board, base, [first])
    {:ok, _, _, _, late} = Boards.apply_edit(ctx.board, [first], [last])

    send(lv.pid, {:board_delta, late, self()})
    assert_push_event(lv, "board:apply", %{"updated" => [^last]})
    send(lv.pid, {:board_delta, early, self()})
    render(lv)
    refute_push_event(lv, "board:apply", %{"updated" => [^first]})

    # Sending the up-to-date browser state must remain a no-op, rather than
    # writing a spurious correction after a delayed message regressed the LV.
    PhoenixKit.PubSubHelper.subscribe("phoenix_kit_boards:#{ctx.board.uuid}")
    render_hook(lv, "etcher:annotations-changed", %{"annotations" => [last]})
    refute_receive {:board_delta, _, _}, 100
  end

  test "a late create does not resurrect a shape already deleted in storage", ctx do
    {:ok, lv, _} = open(ctx.board, ctx.owner)
    render_hook(lv, "board:ready", %{})
    base = Boards.annotations(Boards.load_canvas(ctx.board))
    peer = Quick.note_shape("Already deleted")
    {:ok, _, _, _, created} = Boards.apply_edit(ctx.board, base, base ++ [peer])
    {:ok, _, _, _, deleted} = Boards.apply_edit(ctx.board, base ++ [peer], base)

    send(lv.pid, {:board_delta, deleted, self()})
    send(lv.pid, {:board_delta, created, self()})
    render(lv)
    refute_push_event(lv, "board:apply", %{"created" => [^peer]})
  end

  # A reconnect mounts a NEW process from the stored board, while the page still
  # holds the board from before its line dropped plus work done offline.
  test "a reconnecting page keeps its offline work and catches up on peers'", ctx do
    [note] = Boards.annotations(Boards.load_canvas(ctx.board))
    x = Quick.note_shape("Peer deletes, page edits")
    y = Quick.note_shape("Page deletes")
    {:ok, _, _, _, _} = Boards.apply_edit(ctx.board, [note], [note, x, y])

    # While the page is away: a peer retitles the note, deletes x, adds p.
    peer_note = put_in(note, ["metadata", "title"], "Peer title")
    p = Quick.note_shape("Peer added")
    {:ok, _, _, _, _} = Boards.apply_edit(ctx.board, [note, x, y], [peer_note, y, p])

    # Meanwhile, offline, the page edited x, deleted y and added m.
    local_x = put_in(x, ["metadata", "title"], "Edited offline")
    m = Quick.note_shape("Made offline")
    held = [note, local_x, m]

    PhoenixKit.PubSubHelper.subscribe("phoenix_kit_boards:#{ctx.board.uuid}")
    {:ok, lv, _} = open(ctx.board, ctx.owner)

    render_hook(lv, "board:ready", %{
      "resync" => %{
        "annotations" => held,
        "created" => [m["uuid"]],
        "updated" => [x["uuid"]],
        "deleted" => [y["uuid"]]
      }
    })

    # The offline work is stored on top of the peers' — the peer's delete of x
    # beats the offline edit of it, as it would have online.
    stored = ctx.board.uuid |> Boards.get_board() |> Boards.load_canvas() |> Boards.annotations()
    assert stored == [peer_note, p, m]
    assert_receive {:board_delta, %{"created" => [^m], "deleted" => [y_uuid]}, _}
    assert y_uuid == y["uuid"]

    # And the page is told only what it lacks.
    assert_push_event(lv, "board:apply", %{
      "created" => [^p],
      "updated" => [^peer_note],
      "deleted" => [x_uuid]
    })

    assert x_uuid == x["uuid"]

    # Nothing it listed comes back as a peer's protected arrival: its next list,
    # without m, is a delete of m.
    render_hook(lv, "etcher:annotations-changed", %{"annotations" => [peer_note, p]})

    assert ctx.board.uuid |> Boards.get_board() |> Boards.load_canvas() |> Boards.annotations() ==
             [peer_note, p]
  end

  test "a reconnect with no offline work only brings the page up to date", ctx do
    [note] = Boards.annotations(Boards.load_canvas(ctx.board))
    p = Quick.note_shape("Peer added")
    {:ok, _, _, _, _} = Boards.apply_edit(ctx.board, [note], [note, p])
    PhoenixKit.PubSubHelper.subscribe("phoenix_kit_boards:#{ctx.board.uuid}")
    {:ok, lv, _} = open(ctx.board, ctx.owner)

    render_hook(lv, "board:ready", %{
      "resync" => %{"annotations" => [note], "created" => [], "updated" => [], "deleted" => []}
    })

    assert_push_event(lv, "board:apply", %{"created" => [^p], "updated" => [], "deleted" => []})
    refute_receive {:board_delta, _, _}, 100

    assert ctx.board.uuid |> Boards.get_board() |> Boards.load_canvas() |> Boards.annotations() ==
             [note, p]
  end

  describe "cursor:move over the LiveView fallback" do
    setup ctx do
      {:ok, lv, _} = open(ctx.board, ctx.owner)
      PhoenixKit.PubSubHelper.subscribe("phoenix_kit_boards:#{ctx.board.uuid}")
      %{lv: lv}
    end

    test "relays numeric coordinates to peers", %{lv: lv} do
      render_hook(lv, "cursor:move", %{"x" => 10, "y" => 20.5})
      assert_receive {:board_cursor, _id, 10, 20.5, _meta, _from}
    end

    test "drops coordinates that are not numbers", %{lv: lv} do
      render_hook(lv, "cursor:move", %{"x" => "<img onerror=1>", "y" => 5})
      render_hook(lv, "cursor:move", %{"x" => 5, "y" => nil})
      refute_receive {:board_cursor, _, _, _, _, _}, 100
    end
  end

  describe "board:unfurl" do
    test "answers later, as an event naming the ref, so the board is not held meanwhile", ctx do
      {:ok, lv, _} = open(ctx.board, ctx.owner)

      # A loopback address is refused by the fetch guard, so this needs no network.
      render_hook(lv, "board:unfurl", %{"url" => "http://127.0.0.1/", "ref" => "r1"})

      assert_push_event(lv, "board:unfurled", %{"ref" => "r1", "error" => _})
    end

    test "a client without a ref still gets its reply to the push", ctx do
      {:ok, lv, _} = open(ctx.board, ctx.owner)

      render_hook(lv, "board:unfurl", %{"url" => "http://127.0.0.1/"})
      assert_reply(lv, %{"error" => _})
    end

    test "something that is not a link is refused", ctx do
      {:ok, lv, _} = open(ctx.board, ctx.owner)

      render_hook(lv, "board:unfurl", %{"url" => 5})
      assert_reply(lv, %{"error" => "bad_request"})
    end
  end

  describe "who is online" do
    defp online(lv), do: lv |> render() |> then(&Regex.run(~r/(\d+)\s+online/, &1)) |> List.last()

    test "a viewer who leaves cleanly is dropped", ctx do
      {:ok, first, _} = open(ctx.board, ctx.owner)
      {:ok, second, _} = open(ctx.board, ctx.other)
      assert online(first) == "2"

      GenServer.stop(second.pid, :normal)
      assert eventually(fn -> online(first) == "1" end)
    end

    # Opens a viewer and returns the pid of the LiveView itself, learned from
    # the join it broadcasts. The test process traps exits so that killing the
    # viewer, which the test client is linked to, does not kill the test.
    defp open_watching(board, user) do
      Process.flag(:trap_exit, true)
      PhoenixKit.PubSubHelper.subscribe("phoenix_kit_boards:#{board.uuid}")
      {:ok, _lv, _} = open(board, user)
      assert_receive {:board_join, _me, channel_pid}, 5_000
      channel_pid
    end

    test "a viewer whose connection is killed is dropped too", ctx do
      {:ok, first, _} = open(ctx.board, ctx.owner)
      channel = open_watching(ctx.board, ctx.other)
      assert online(first) == "2"

      # No terminate/2, so no leave message: only watching the process can
      # notice this.
      Process.exit(channel, :kill)
      assert eventually(fn -> online(first) == "1" end)
    end

    test "a viewer who reloads shows once, not twice", ctx do
      {:ok, first, _} = open(ctx.board, ctx.owner)
      channel = open_watching(ctx.board, ctx.other)
      Process.exit(channel, :kill)
      {:ok, _again, _} = open(ctx.board, ctx.other)

      assert eventually(fn -> online(first) == "2" end)
    end

    defp eventually(fun, tries \\ 40) do
      cond do
        fun.() -> true
        tries == 0 -> false
        true -> Process.sleep(25) && eventually(fun, tries - 1)
      end
    end
  end

  describe "opening a board that still carries embedded images" do
    @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    test "tells the room, so nobody writes the embedded copy back", ctx do
      shape = %{
        "uuid" => "img1",
        "kind" => "image",
        "geometry" => %{"x" => 0, "y" => 0, "href" => "data:image/png;base64," <> @png}
      }

      {:ok, _, _, _, _} =
        Boards.apply_edit(ctx.board, Boards.annotations(Boards.load_canvas(ctx.board)), [shape])

      PhoenixKit.PubSubHelper.subscribe("phoenix_kit_boards:#{ctx.board.uuid}")

      {:ok, lv, _} = open(ctx.board, ctx.owner)

      assert_receive {:board_delta, %{"updated" => [%{"uuid" => "img1"} = moved]}, _from}, 5_000
      refute moved["geometry"]["href"] =~ "data:"

      # And what is stored agrees with what was said.
      stored =
        ctx.board.uuid |> Boards.get_board() |> Boards.load_canvas() |> Boards.annotations()

      assert [%{"geometry" => %{"href" => href}}] = stored
      assert href == moved["geometry"]["href"]
      assert render(lv) =~ "board-root"
    end

    test "says nothing when there is nothing to move", ctx do
      PhoenixKit.PubSubHelper.subscribe("phoenix_kit_boards:#{ctx.board.uuid}")
      {:ok, _lv, _} = open(ctx.board, ctx.owner)

      refute_receive {:board_delta, _, _}, 200
    end
  end
end
