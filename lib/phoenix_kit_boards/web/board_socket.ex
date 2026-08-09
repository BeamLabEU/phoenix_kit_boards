defmodule PhoenixKitBoards.Web.BoardSocket do
  @moduledoc """
  Carries a board's *ephemeral* traffic — where people's cursors are, and
  where a shape is while it is still being dragged.

  Separate from the LiveView socket on purpose. Both kinds of traffic are
  high-rate and worthless a moment later, and putting them through a LiveView
  means every position pays for a render and a diff, queued behind that
  process's real work: saving edits, uploads, link previews. A channel is a
  message in and a message out.

  Nothing here is persisted or authoritative. The durable path is unchanged —
  the client still emits `etcher:annotations-changed` to its LiveView when an
  edit is finished, and that is what is stored and broadcast to peers. This
  socket only makes the time *before* the edit finishes visible.

  ## Mounting it

  Sockets are declared on the endpoint, which belongs to the host, so this
  needs one line in `endpoint.ex`:

      socket "/phoenix_kit/board", PhoenixKitBoards.Web.BoardSocket, websocket: true

  Nothing more: `connect/3` takes the peer from the signed token and reads no
  `connect_info`, so there is none to declare.

  It is optional. A host that hasn't added it loses nothing that worked
  before: the client notices the socket isn't there and falls back to
  relaying cursors through its LiveView, which is where they used to go.

  ## Who may join

  A board page mints a short-lived signed token naming the board and the
  peer, and hands it to the client. The channel re-derives the peer from the
  token rather than believing anything the client says about itself — so a
  client cannot join a board it was never shown, and cannot present as
  somebody else.
  """
  use Phoenix.Socket

  @salt "phoenix_kit_boards board peer"

  # Long enough to cover a page that sits open before anyone touches it, short
  # enough that a leaked token isn't a standing invitation. Reconnects reuse
  # it, so this is also how long an unattended tab can drop off the network
  # and come back without a reload.
  @max_age 24 * 60 * 60

  channel("board:*", PhoenixKitBoards.Web.BoardChannel)

  @default_path "/phoenix_kit/board"

  @doc """
  Where the host mounted this socket.

  The endpoint line names the path, so a host that mounts it somewhere else
  says so with:

      config :phoenix_kit_boards, board_socket_path: "/somewhere/else"

  The client is told the answer rather than guessing it.
  """
  def mount_path do
    Application.get_env(:phoenix_kit_boards, :board_socket_path, @default_path)
  end

  @doc """
  Mint the token a board page hands to its client.

  Carries the peer's identity, so the channel never has to take the client's
  word for who it is.
  """
  def sign(endpoint_or_socket, board_uuid, peer) do
    Phoenix.Token.sign(endpoint_or_socket, @salt, %{
      board: board_uuid,
      id: peer.id,
      name: peer.name,
      color: peer.color
    })
  end

  @doc false
  def verify(endpoint_or_socket, token) do
    Phoenix.Token.verify(endpoint_or_socket, @salt, token, max_age: @max_age)
  end

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify(socket, token) do
      {:ok, %{board: board} = peer} when is_binary(board) ->
        {:ok, assign(socket, :peer, peer)}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Per-connection rather than per-user: two tabs of one person are two
  # presences on the board, and `nil` would mean neither could be disconnected
  # without disconnecting the other.
  @impl true
  def id(_socket), do: nil
end
