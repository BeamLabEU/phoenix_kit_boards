defmodule PhoenixKitBoards.BoardUnfurlTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.{Socket, Utils}
  alias PhoenixKitBoards.Web.BoardLive

  defp socket(unfurls) do
    %Socket{assigns: %{__changed__: %{}, unfurls: unfurls}, private: %{live_temp: %{}}}
  end

  test "reusing an in-flight ref cannot start more tasks under the same budget slot" do
    {:noreply, socket} =
      BoardLive.handle_event(
        "board:unfurl",
        %{"url" => "https://example.com", "ref" => "same"},
        socket(%{"same" => true})
      )

    assert [["board:unfurled", %{"ref" => "same", "error" => "busy"}]] =
             Utils.get_push_events(socket)

    assert socket.assigns.unfurls == %{"same" => true}
  end

  test "the per-viewer task budget refuses additional refs" do
    {:noreply, socket} =
      BoardLive.handle_event(
        "board:unfurl",
        %{"url" => "https://example.com", "ref" => "four"},
        socket(%{"one" => true, "two" => true, "three" => true})
      )

    assert [["board:unfurled", %{"ref" => "four", "error" => "busy"}]] =
             Utils.get_push_events(socket)
  end

  test "a malformed ref cannot fall through to the synchronous legacy fetch" do
    for ref <- ["", String.duplicate("x", 65), nil, 1] do
      assert {:reply, %{"error" => "bad_request"}, _socket} =
               BoardLive.handle_event(
                 "board:unfurl",
                 %{"url" => "http://127.0.0.1/", "ref" => ref},
                 socket(%{})
               )
    end
  end
end
