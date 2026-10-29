defmodule PhoenixKitBoards.PathsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Paths

  describe "local_path/1" do
    test "keeps a path on this site, query and fragment included" do
      assert Paths.local_path("/projects/alpha") == "/projects/alpha"

      assert Paths.local_path("/projects/alpha?tab=boards#top") ==
               "/projects/alpha?tab=boards#top"

      assert Paths.local_path("/") == "/"
    end

    test "refuses anything that can leave the site" do
      for bad <- [
            "//evil.example",
            "//evil.example/path",
            "/\\evil.example",
            "https://evil.example",
            "javascript:alert(1)",
            "evil.example",
            "",
            nil,
            42,
            %{}
          ] do
        assert Paths.local_path(bad) == nil, "accepted #{inspect(bad)}"
      end
    end

    test "refuses control characters and a backslash anywhere" do
      for bad <- ["/ok\r\nLocation: https://evil.example", "/ok\u0000", "/a\\b", "/a\tb"] do
        assert Paths.local_path(bad) == nil, "accepted #{inspect(bad)}"
      end
    end

    test "refuses an absurdly long path" do
      assert Paths.local_path("/" <> String.duplicate("a", 2_000)) == nil
    end
  end

  describe "user_board/2" do
    test "links to the dashboard board page" do
      assert Paths.user_board("abc") =~ "/dashboard/boards/abc"
    end

    test "carries a local return_to, encoded, and drops a foreign one" do
      assert Paths.user_board("abc", "/projects/a?x=1") =~
               "?return_to=%2Fprojects%2Fa%3Fx%3D1"

      assert Paths.user_board("abc", "https://evil.example") == Paths.user_board("abc")
      assert Paths.user_board("abc", nil) == Paths.user_board("abc")
    end
  end
end
