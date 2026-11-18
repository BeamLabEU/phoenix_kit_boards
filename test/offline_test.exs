defmodule PhoenixKitBoards.OfflineTest do
  @moduledoc """
  Offline boards (`config :phoenix_kit, offline_annotations: true`): the
  switch, the service worker this module serves for Etcher, and the markers
  the page carries so Etcher can rebuild it with no connection.
  """
  # Global application env — not async.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Plug.Test, only: [conn: 3]
  import Plug.Conn, only: [get_resp_header: 2]

  alias PhoenixKitBoards.Web.{AssetController, BoardLive}

  setup do
    previous = Application.fetch_env(:phoenix_kit, :offline_annotations)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:phoenix_kit, :offline_annotations, value)
        :error -> Application.delete_env(:phoenix_kit, :offline_annotations)
      end
    end)
  end

  test "offline is off unless the host turns it on, and only a literal true does" do
    Application.delete_env(:phoenix_kit, :offline_annotations)
    refute BoardLive.offline?()

    Application.put_env(:phoenix_kit, :offline_annotations, "true")
    refute BoardLive.offline?()

    Application.put_env(:phoenix_kit, :offline_annotations, true)
    assert BoardLive.offline?()
  end

  describe "the service worker" do
    test "is Etcher's, served so the browser keeps it current and may widen its scope" do
      conn =
        conn(:get, "/admin/boards/assets/offline-sw.js", %{})
        |> AssetController.call(:offline_worker)

      assert conn.status == 200
      assert conn.resp_body == Etcher.offline_worker()
      assert conn.resp_body =~ "etcher-offline:keep"
      assert get_resp_header(conn, "content-type") == ["text/javascript; charset=utf-8"]
      # A cached worker would pin an old version.
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      # Registered for the whole site from a URL deep in the admin area.
      assert get_resp_header(conn, "service-worker-allowed") == ["/"]
    end

    test "its URL sits beside the hook bundle" do
      assert BoardLive.offline_worker_url() =~ ~r{/admin/boards/assets/offline-sw\.js$}
    end
  end

  defp render_spinner do
    rendered_to_string(BoardLive.render(%{__changed__: nil, board: nil, gone?: false, embedded?: false}))
  end

  describe "the disconnected render (all the browser has offline)" do
    test "marks where the board is rebuilt only with offline on" do
      Application.put_env(:phoenix_kit, :offline_annotations, true)
      html = render_spinner()
      assert html =~ ~s(data-offline-slot="board")

      Application.delete_env(:phoenix_kit, :offline_annotations)
      html = render_spinner()
      refute html =~ "data-offline-slot"
    end
  end
end
