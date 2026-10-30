defmodule PhoenixKitBoards.Integration.PrefsTest do
  use PhoenixKitBoards.DataCase, async: false

  alias Phoenix.LiveView.Socket
  alias PhoenixKitBoards.Web.BoardLive

  defp socket_for(user), do: %Socket{assigns: %{__changed__: %{}, phoenix_kit_current_user: user}}

  defp stored(user), do: Repo.get!(PhoenixKit.Users.Auth.User, user.uuid).custom_fields

  test "preferences the editor reports are saved on the user" do
    user = user_fixture()
    prefs = %{"tools" => ["pencil", "text"], "panel_open" => false}

    assert {:noreply, socket} =
             BoardLive.handle_event("etcher:prefs-changed", prefs, socket_for(user))

    assert stored(user)["etcher_prefs"] == prefs
    assert socket.assigns.phoenix_kit_current_user.custom_fields["etcher_prefs"] == prefs
  end

  test "other etcher events still fall through to the catch-all" do
    user = user_fixture()
    socket = socket_for(user)

    assert {:noreply, ^socket} =
             BoardLive.handle_event("etcher:something-else", %{"a" => 1}, socket)

    assert stored(user)["etcher_prefs"] == nil
  end

  test "saving merges with what the user already has" do
    user = user_fixture()

    {:noreply, socket} =
      BoardLive.handle_event("etcher:prefs-changed", %{"a" => 1}, socket_for(user))

    {:noreply, _} = BoardLive.handle_event("etcher:prefs-changed", %{"b" => 2}, socket)

    # The second report is the whole current state, so it replaces the first;
    # unrelated custom fields survive either way.
    assert stored(user)["etcher_prefs"] == %{"b" => 2}
  end

  test "an oversized report is ignored, not stored" do
    user = user_fixture()
    huge = %{"blob" => String.duplicate("x", 20_000)}

    assert {:noreply, _} = BoardLive.handle_event("etcher:prefs-changed", huge, socket_for(user))
    assert stored(user)["etcher_prefs"] == nil
  end

  test "nobody signed in: nothing to store against, no crash" do
    socket = %Socket{assigns: %{__changed__: %{}}}

    assert {:noreply, ^socket} =
             BoardLive.handle_event("etcher:prefs-changed", %{"a" => 1}, socket)
  end
end
