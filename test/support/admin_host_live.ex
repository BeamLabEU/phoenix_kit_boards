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

  @impl true
  def handle_info(message, socket), do: BoardLive.handle_info(message, socket)

  @impl true
  def terminate(reason, socket), do: BoardLive.terminate(reason, socket)
end
