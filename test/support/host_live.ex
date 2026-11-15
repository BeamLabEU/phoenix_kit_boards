defmodule PhoenixKitBoards.Test.HostLive do
  @moduledoc """
  A page that embeds the panel the way a host app would, taking everything it
  needs from the test's session: the signed-in user's uuid and the panel's
  options.
  """
  use Phoenix.LiveView

  alias PhoenixKitBoards.Test.Repo

  @impl true
  def mount(_params, session, socket) do
    user =
      case session["user_uuid"] do
        nil -> nil
        uuid -> Repo.get(PhoenixKit.Users.Auth.User, uuid)
      end

    {:ok, assign(socket, user: user, opts: session["opts"] || [])}
  end

  # The host moving the widget to another place (or changing any option)
  # while it stays mounted, as a page navigating within its LiveView would.
  @impl true
  def handle_info({:set_opts, opts}, socket),
    do: {:noreply, assign(socket, :opts, Keyword.merge(socket.assigns.opts, opts))}

  # Anything else (e.g. `:host_rerender`) is a re-render and nothing more.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <PhoenixKitBoards.Web.Components.boards_panel
        id="panel"
        current_user={@user}
        {Map.new(@opts)}
      />
    </main>
    """
  end
end
