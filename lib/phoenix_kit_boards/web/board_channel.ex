defmodule PhoenixKitBoards.Web.BoardChannel do
  @moduledoc """
  Relays a board's ephemeral traffic between the people looking at it.

  Two kinds, both worthless a moment after they arrive:

    * `"cursor"` — where someone's pointer is, in canvas coordinates, so each
      viewer maps it through their own pan and zoom.
    * `"moving"` — where a shape is *while it is still being dragged*. Peers
      patch it into place and see the drag happen; the edit itself is stored
      and broadcast the usual way when the gesture ends.

  Deliberately does nothing else. No database, no diff, no persistence, and
  no state beyond who is on the topic — the point of moving this off the
  LiveView was to stop this traffic queueing behind that work.

  The sender is excluded from everything it sends (`broadcast_from`): it drew
  its own cursor and moved its own shape locally, and echoing would fight the
  gesture in progress.

  Nothing arriving here is trusted as identity. The peer is whatever the
  signed join token said, so a client can move its own cursor and nobody
  else's.
  """
  use Phoenix.Channel

  alias PhoenixKitBoards.Web.BoardSocket

  @impl true
  def join("board:" <> board_uuid, _params, socket) do
    peer = socket.assigns.peer

    # The token names the board it was minted for. Without this check any
    # valid token would open any board, which on a private board is the whole
    # of the access control.
    if peer.board == board_uuid do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket), do: {:error, %{reason: "unknown topic"}}

  # Cursor positions arrive tens of times a second per person. Read the
  # coordinates, attach the identity the token established, pass it on.
  @impl true
  def handle_in("cursor", %{"x" => x, "y" => y} = params, socket)
      when is_number(x) and is_number(y) do
    peer = socket.assigns.peer

    broadcast_from(socket, "cursor", %{
      "id" => peer.id,
      "name" => peer.name,
      "color" => peer.color,
      "x" => x,
      "y" => y,
      "pointer" => params["pointer"] == true
    })

    {:noreply, socket}
  end

  # A shape mid-drag. `shapes` is a list of `%{"uuid" => …, "geometry" => …}`
  # — geometry only, because that is all a drag changes and all a peer needs
  # to draw it moving.
  def handle_in("moving", %{"shapes" => shapes}, socket) when is_list(shapes) do
    case Enum.filter(shapes, &movable?/1) do
      [] ->
        {:noreply, socket}

      clean ->
        broadcast_from(socket, "moving", %{"id" => socket.assigns.peer.id, "shapes" => clean})
        {:noreply, socket}
    end
  end

  # A gesture ended. Peers drop their transient copy and wait for the real
  # edit, which arrives through the LiveView once it has been stored — so a
  # drag that is abandoned, or whose save fails, snaps back rather than
  # leaving everyone looking at a position that was never recorded.
  def handle_in("moved", _params, socket) do
    broadcast_from(socket, "moved", %{"id" => socket.assigns.peer.id})
    {:noreply, socket}
  end

  def handle_in(_event, _params, socket), do: {:noreply, socket}

  defp movable?(%{"uuid" => uuid, "geometry" => geometry})
       when is_binary(uuid) and is_map(geometry),
       do: true

  defp movable?(_), do: false

  @doc false
  # Re-exported so a caller that has the channel does not also need the socket
  # module just to mint a token.
  defdelegate sign(endpoint_or_socket, board_uuid, peer), to: BoardSocket
end
