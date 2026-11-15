defmodule PhoenixKitBoards.Test.AdminHostLive do
  @moduledoc """
  The two admin pages (`/admin/boards`, `/admin/boards/:id`) as the host's
  router would mount them: with the session's `Scope` assigned, which is all
  they have to go on. `session["page"]` is `"index"` or `"show"`.
  """
  use Phoenix.LiveView

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBoards.Test.Repo
  alias PhoenixKitBoards.Web.{BoardLive, IndexLive}

  @impl true
  def mount(_params, session, socket) do
    user = Repo.get!(PhoenixKit.Users.Auth.User, session["user_uuid"])

    socket =
      assign(socket,
        phoenix_kit_current_user: user,
        phoenix_kit_current_scope: Scope.for_user(user),
        page: session["page"]
      )

    case session["page"] do
      "index" ->
        IndexLive.mount(%{}, session, assign(socket, :live_action, :index))

      "show" ->
        BoardLive.mount(
          %{"id" => session["board_uuid"]},
          session,
          assign(socket, :live_action, :show)
        )
    end
  end

  @impl true
  def render(%{page: "index"} = assigns), do: IndexLive.render(assigns)
  def render(assigns), do: BoardLive.render(assigns)

  @impl true
  def handle_event(event, params, %{assigns: %{page: "index"}} = socket),
    do: IndexLive.handle_event(event, params, socket)

  def handle_event(event, params, socket), do: BoardLive.handle_event(event, params, socket)

  # What core's scope hook does when roles change: rebuild the snapshot, then
  # call `phoenix_kit_scope_changed/1` on the page. This host is the LiveView
  # in tests, so it makes that call itself. `{:replace_scope, user}` only
  # rebuilds the assign, which is how a test reaches the event hook without
  # the callback having already left the page.
  @impl true
  def handle_info({:phoenix_kit_scope_roles_updated, _uuid}, socket) do
    {:noreply, refresh_scope(socket, true)}
  end

  def handle_info({:replace_scope, user}, socket) do
    {:noreply, refresh_scope(assign(socket, :phoenix_kit_current_user, user), false)}
  end

  def handle_info(message, socket), do: BoardLive.handle_info(message, socket)

  defp refresh_scope(socket, callback?) do
    user = socket.assigns.phoenix_kit_current_user
    socket = assign(socket, :phoenix_kit_current_scope, Scope.for_user(user))

    if callback? do
      case socket.assigns.page do
        "index" -> IndexLive.phoenix_kit_scope_changed(socket)
        "show" -> BoardLive.phoenix_kit_scope_changed(socket)
        _ -> socket
      end
    else
      socket
    end
  end

  @impl true
  def terminate(reason, socket), do: BoardLive.terminate(reason, socket)
end
