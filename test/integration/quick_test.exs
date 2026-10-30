defmodule PhoenixKitBoards.Integration.QuickTest do
  use PhoenixKitBoards.DataCase, async: false

  alias PhoenixKitBoards.{Boards, Quick}

  @scope {"project", "quick"}

  setup do
    %{user: user_fixture()}
  end

  defp annotations(board), do: board |> Boards.load_canvas() |> Boards.annotations()

  describe "create_note/4" do
    test "makes a quick board with the note centred on it", %{user: u} do
      assert {:ok, board} = Quick.create_note(@scope, u.uuid, "Buy milk\nand eggs")

      assert board.kind == "quick"
      assert board.name == "Buy milk"
      assert board.created_by == u.uuid
      assert Boards.scope_of(board) == @scope
      assert board.visibility == "shared"

      assert [%{"kind" => "text", "metadata" => %{"title" => "Buy milk\nand eggs"}} = shape] =
               annotations(Boards.get_board(board.uuid))

      %{"x" => x, "y" => y, "w" => w, "h" => h} = shape["geometry"]
      {cw, ch} = Boards.canvas_size()
      assert_in_delta x + w / 2, cw / 2, 2
      assert_in_delta y + h / 2, ch / 2, 2
      assert is_binary(shape["uuid"])
    end

    test "can be private", %{user: u} do
      {:ok, board} = Quick.create_note(@scope, u.uuid, "secret", visibility: "private")
      assert board.visibility == "private"
    end

    test "an empty note is refused and makes nothing", %{user: u} do
      assert {:error, :empty} = Quick.create_note(@scope, u.uuid, "  \n\t ")
      assert Boards.count_for_scope(@scope, u.uuid) == 0
    end

    test "the name is the first line, clipped", %{user: u} do
      {:ok, board} = Quick.create_note(@scope, u.uuid, String.duplicate("word ", 40))
      assert String.length(board.name) <= 60
      assert String.ends_with?(board.name, "…")
    end

    test "long lines are wrapped so they stay on the canvas", %{user: u} do
      text = String.duplicate("lorem ipsum ", 60)
      {:ok, board} = Quick.create_note(@scope, u.uuid, text)

      [%{"metadata" => %{"title" => title}, "geometry" => %{"x" => x, "w" => w}}] =
        annotations(board)

      assert title |> String.split("\n") |> Enum.all?(&(String.length(&1) <= 40))
      {cw, _} = Boards.canvas_size()
      assert x >= 0 and x + w <= cw
    end

    test "a word longer than a line is broken", %{user: u} do
      {:ok, board} = Quick.create_note(@scope, u.uuid, String.duplicate("x", 200))
      [%{"metadata" => %{"title" => title}}] = annotations(board)
      assert title |> String.split("\n") |> Enum.all?(&(String.length(&1) <= 40))
    end

    test "an enormous note is capped", %{user: u} do
      {:ok, board} = Quick.create_note(@scope, u.uuid, String.duplicate("line\n", 5_000))
      [%{"metadata" => %{"title" => title}}] = annotations(board)
      assert length(String.split(title, "\n")) <= 40
    end

    test "control characters are stripped", %{user: u} do
      {:ok, board} = Quick.create_note(@scope, u.uuid, "a\u0000b\u0007c")
      [%{"metadata" => %{"title" => "abc"}}] = annotations(board)
    end

    test "takes a folder like any board", %{user: u} do
      {:ok, board} =
        Quick.create_note(@scope, u.uuid, "x", folder: {:path, ["QuickTest"]}, label: "L")

      assert board.folder_parent_uuid != nil
    end
  end

  describe "create_image/5" do
    test "a file that cannot be stored leaves no empty board behind", %{user: u} do
      entry = %{client_name: "gone.png", client_type: "image/png"}

      assert {:error, _} = Quick.create_image(@scope, u.uuid, "/nonexistent/gone.png", entry)
      assert Boards.count_for_scope(@scope, u.uuid) == 0
    end
  end

  describe "image_shape/2" do
    test "keeps the picture's proportions inside the box, centred" do
      shape = Quick.image_shape(%{width: 1600, height: 900}, "/file/x")
      %{"w" => w, "h" => h, "x" => x, "y" => y, "href" => "/file/x"} = shape["geometry"]

      assert {w, h} == {4000, 2250}
      {cw, ch} = Boards.canvas_size()
      assert {x, y} == {round((cw - w) / 2), round((ch - h) / 2)}
      assert shape["kind"] == "image"
    end

    test "a tall picture is limited by height" do
      %{"geometry" => %{"w" => w, "h" => h}} =
        Quick.image_shape(%{width: 900, height: 1600}, "/f")

      assert h == 3000 and w == 1688
    end

    test "unknown size falls back to the box" do
      %{"geometry" => %{"w" => 4000, "h" => 3000}} =
        Quick.image_shape(%{width: nil, height: nil}, "/f")
    end
  end

  describe "previews" do
    test "preview_from/1 reads the first text, first real image and the count" do
      shapes = [
        %{"kind" => "marker"},
        %{"kind" => "image", "geometry" => %{"href" => "data:image/png;base64,AAAA"}},
        %{"kind" => "text", "metadata" => %{"title" => "   "}},
        %{"kind" => "text", "metadata" => %{"title" => "Hello"}},
        %{"kind" => "image", "geometry" => %{"href" => "/file/abc"}},
        %{"kind" => "text", "metadata" => %{"title" => "later"}}
      ]

      assert Boards.preview_from(shapes) == %{
               "text" => "Hello",
               "image_url" => "/file/abc",
               "count" => 6
             }

      assert Boards.preview_from([]) == %{"text" => nil, "image_url" => nil, "count" => 0}
    end

    test "the text is clipped" do
      shapes = [%{"kind" => "text", "metadata" => %{"title" => String.duplicate("a", 500)}}]
      assert String.length(Boards.preview_from(shapes)["text"]) == 140
    end

    test "saving a board stores its preview", %{user: u} do
      {:ok, board} = Quick.create_note(@scope, u.uuid, "Hello there")
      assert %{"text" => "Hello there", "count" => 1} = Boards.get_board(board.uuid).preview
    end
  end

  describe "announcements" do
    setup %{user: u} do
      Boards.subscribe_scope(@scope)
      %{u: u}
    end

    defp board!(u, attrs \\ %{}) do
      {:ok, board} =
        Boards.create_board(
          Map.merge(
            %{
              "name" => "B",
              "created_by" => u.uuid,
              "scope_type" => "project",
              "scope_id" => "quick"
            },
            attrs
          )
        )

      board
    end

    test "creating, renaming, pinning, archiving and deleting each announce", %{u: u} do
      board = board!(u)
      uuid = board.uuid
      assert_receive {:boards_scope_changed, ^uuid}

      {:ok, board} = Boards.rename_board(board, "New name")
      assert_receive {:boards_scope_changed, ^uuid}

      {:ok, board} = Boards.pin(board, u.uuid)
      assert_receive {:boards_scope_changed, ^uuid}

      {:ok, board} = Boards.set_visibility(board, "private", u.uuid)
      assert_receive {:boards_scope_changed, ^uuid}

      {:ok, board} = Boards.archive(board, u.uuid)
      assert_receive {:boards_scope_changed, ^uuid}

      {:ok, _} = Boards.delete_board(board)
      assert_receive {:boards_scope_changed, ^uuid}
    end

    test "the message carries no name, so a private board does not leak", %{u: u} do
      board = board!(u, %{"name" => "Secret plans", "visibility" => "private"})
      uuid = board.uuid
      assert_receive {:boards_scope_changed, ^uuid} = msg
      refute inspect(msg) =~ "Secret"
    end

    test "other places hear nothing", %{u: u} do
      board!(u, %{"scope_id" => "elsewhere"})
      refute_receive {:boards_scope_changed, _}, 100
    end

    test "an edit announces only when what a list shows changes", %{u: u} do
      board = board!(u)
      assert_receive {:boards_scope_changed, _}

      canvas = Boards.load_canvas(board)

      text = %{
        "kind" => "text",
        "uuid" => "t1",
        "metadata" => %{"title" => "Hi"},
        "geometry" => %{"x" => 0}
      }

      {:ok, canvas, board} = Boards.save_annotations(board, canvas, [text])
      assert_receive {:boards_scope_changed, _}

      # Moving the same shape changes nothing a list shows.
      moved = put_in(text, ["geometry", "x"], 500)
      {:ok, _canvas, _board} = Boards.save_annotations(board, canvas, [moved])
      refute_receive {:boards_scope_changed, _}, 100
    end
  end
end
