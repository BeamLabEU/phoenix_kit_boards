defmodule PhoenixKitBoards.Test.BoardHostLive do
  @moduledoc "Exercises the real board lifecycle with a host-authenticated test user."
  use Phoenix.LiveView

  alias PhoenixKitBoards.Test.Repo
  alias PhoenixKitBoards.Web.BoardLive

  @impl true
  def mount(_params, session, socket) do
    user = Repo.get!(PhoenixKit.Users.Auth.User, session["user_uuid"])

    socket =
      assign(socket,
        phoenix_kit_current_user: user,
        phoenix_kit_current_scope: nil,
        live_action: :user
      )

    BoardLive.mount(%{"id" => session["board_uuid"], "return_to" => "/projects"}, session, socket)
  end

  @impl true
  defdelegate render(assigns), to: BoardLive
  @impl true
  defdelegate handle_event(event, params, socket), to: BoardLive
  @impl true
  defdelegate handle_info(message, socket), to: BoardLive
  @impl true
  defdelegate terminate(reason, socket), to: BoardLive
end
