defmodule PhoenixKitBoards.AssetControllerTest do
  @moduledoc """
  Serving the collaboration hook bundle.

  Exercised as the plug it is, so the checks are about the response rather
  than about the admin pipeline in front of it.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [put_req_header: 3, get_resp_header: 2]

  alias PhoenixKitBoards.Web.AssetController

  defp get(headers \\ []) do
    Enum.reduce(headers, conn(:get, "/admin/boards/assets/hooks.js", %{}), fn {k, v}, conn ->
      put_req_header(conn, k, v)
    end)
    |> AssetController.call(:js)
  end

  test "serves the bundle" do
    conn = get()

    assert conn.status == 200
    # The hooks the board's elements name. Serving anything without these is
    # the silent half-working state this whole route exists to prevent.
    assert conn.resp_body =~ "PhoenixKitBoardsHooks"
    assert conn.resp_body =~ "BoardSync"
    assert conn.resp_body =~ "BoardCursors"
  end

  test "as javascript" do
    # A wrong content type here is fatal and quiet: browsers refuse to execute
    # a script served as text/html or text/plain.
    assert get() |> get_resp_header("content-type") == ["text/javascript; charset=utf-8"]
  end

  test "cacheable forever, because the digest is in the URL" do
    conn = get()

    assert get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]

    assert [etag] = get_resp_header(conn, "etag")
    assert etag == ~s("#{AssetController.digest()}")
  end

  test "answers 304 to a matching etag" do
    etag = ~s("#{AssetController.digest()}")
    conn = get([{"if-none-match", etag}])

    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "answers 304 to a wildcard" do
    assert get([{"if-none-match", "*"}]).status == 304
  end

  test "finds its etag among several" do
    etag = ~s("#{AssetController.digest()}")
    assert get([{"if-none-match", ~s("stale-one", #{etag})}]).status == 304
  end

  test "serves the body again when the etag no longer matches" do
    # What makes an upgrade take effect for someone holding the old file.
    assert get([{"if-none-match", ~s("something-else")}]).status == 200
  end

  test "the served bytes are the bundle the module ships" do
    on_disk =
      :phoenix_kit_boards
      |> :code.priv_dir()
      |> Path.join("static/assets/phoenix_kit_boards.js")
      |> File.read!()

    assert get().resp_body == on_disk
  end
end
