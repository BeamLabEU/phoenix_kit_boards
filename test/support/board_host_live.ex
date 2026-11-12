defmodule PhoenixKitBoards.Test.BoardHostLive do
  @moduledoc "Exercises the real board lifecycle with a host-authenticated test user."
  use Phoenix.LiveView

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBoards.Test.Repo
  alias PhoenixKitBoards.Web.BoardLive

  @impl true
  def mount(_params, session, socket) do
    user = Repo.get!(PhoenixKit.Users.Auth.User, session["user_uuid"])

    socket =
      assign(socket,
        phoenix_kit_current_user: user,
        phoenix_kit_current_scope: session_scope(session, user),
        live_action: :user
      )

    BoardLive.mount(%{"id" => session["board_uuid"], "return_to" => "/projects"}, session, socket)
  end

  # `"snapshot"`: the page holds the scope core's on_mount would have built, as
  # in a host; without it the page holds none and `Access` builds one itself.
  defp session_scope(%{"snapshot" => true}, user), do: Scope.for_user(user)
  defp session_scope(_session, _user), do: nil

  @impl true
  defdelegate render(assigns), to: BoardLive
  @impl true
  defdelegate handle_event(event, params, socket), to: BoardLive
  # What core's scope hook does when roles change: the snapshot is rebuilt, and
  # the message goes no further. Only a page that holds a snapshot has the hook.
  @impl true
  def handle_info({:phoenix_kit_scope_roles_updated, _uuid}, socket) do
    case socket.assigns.phoenix_kit_current_scope do
      nil ->
        {:noreply, socket}

      _scope ->
        user = socket.assigns.phoenix_kit_current_user
        {:noreply, assign(socket, :phoenix_kit_current_scope, Scope.for_user(user))}
    end
  end

  def handle_info(message, socket), do: BoardLive.handle_info(message, socket)
  @impl true
  defdelegate handle_async(name, result, socket), to: BoardLive
  @impl true
  defdelegate terminate(reason, socket), to: BoardLive
end
