defmodule PhoenixKitBoards.Web.BoardLive do
  @moduledoc """
  A single collaborative board (`/admin/boards/:id`).

  Renders a `<Fresco.canvas>` (infinite) + `<Etcher.layer>` and wires three
  real-time channels over one PubSub topic (`phoenix_kit_boards:<id>`):

    * **Shapes** — the client emits `etcher:annotations-changed` (full list) on
      every edit; we diff, persist, and broadcast. Peers diff against their own
      state and push a create/update/delete delta to `BoardSync`, which applies
      it via `window.Etcher.layerFor(id)` — no canvas remount. Echo is broken
      server-side (an unchanged list diffs to empty).
    * **Presence** — a roster of who's viewing, via join/hello/leave messages.
    * **Cursors** — pointer positions in *canvas* coordinates, so each viewer
      maps them through their own pan/zoom (`BoardCursors`).
  """
  use PhoenixKitWeb, :live_view

  alias Phoenix.PubSub
  alias PhoenixKit.PubSubHelper
  alias PhoenixKitBoards.{Boards, Paths}

  @tools [
    :grabber,
    :image,
    :rectangle,
    :circle,
    :polygon,
    :line,
    :freehand,
    :marker,
    :text,
    :callout,
    :dimension,
    :eraser
  ]

  @cursor_colors ~w(#2563eb #db2777 #16a34a #d97706 #7c3aed #0891b2 #dc2626 #4f46e5)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Boards.get_board(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Board not found.")
         |> push_navigate(to: Paths.boards())}

      board ->
        {:ok, canvas} = {:ok, Boards.load_canvas(board)}
        annotations = Boards.annotations(canvas)
        me = identity(socket)
        topic = topic(board.id)

        if connected?(socket) do
          PubSubHelper.subscribe(topic)
          broadcast(topic, {:board_join, me, self()})
        end

        {:ok,
         socket
         |> assign(:page_title, board.name)
         |> assign(:board, board)
         |> assign(:canvas, canvas)
         |> assign(:annotations, annotations)
         |> assign(:tools, @tools)
         |> assign(:topic, topic)
         |> assign(:me, me)
         |> assign(:peers, %{})}
    end
  end

  # ── Local edits (client → server) ─────────────────────────────────────────

  @impl true
  def handle_event("etcher:annotations-changed", %{"annotations" => incoming}, socket)
      when is_list(incoming) do
    if empty_delta?(diff(socket.assigns.annotations, incoming)) do
      {:noreply, socket}
    else
      case Boards.save_annotations(socket.assigns.board, socket.assigns.canvas, incoming) do
        {:ok, canvas, board} ->
          broadcast(socket.assigns.topic, {:board_annotations, incoming, self()})

          {:noreply,
           socket
           |> assign(:board, board)
           |> assign(:canvas, canvas)
           |> assign(:annotations, incoming)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not save the board.")}
      end
    end
  end

  def handle_event("etcher:annotations-changed", _params, socket), do: {:noreply, socket}

  # Other etcher client events we don't persist here (tools, colors, tooltips…).
  def handle_event("etcher:" <> _rest, _params, socket), do: {:noreply, socket}

  # A local pointer move → broadcast our cursor (canvas coords) to peers.
  def handle_event("cursor:move", %{"x" => x, "y" => y}, socket) do
    broadcast(socket.assigns.topic, {:board_cursor, socket.assigns.me.id, x, y, self()})
    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ── Remote events (peer → server → client) ────────────────────────────────

  @impl true
  def handle_info({:board_annotations, _incoming, from}, socket) when from == self(),
    do: {:noreply, socket}

  def handle_info({:board_annotations, incoming, _from}, socket) do
    delta = diff(socket.assigns.annotations, incoming)

    if empty_delta?(delta) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:annotations, incoming)
       |> assign(:canvas, Boards.put_annotations(socket.assigns.canvas, incoming))
       |> push_event("board:apply", delta)}
    end
  end

  # Presence: a newcomer joined → record them and reply so they learn about us.
  def handle_info({:board_join, _peer, from}, socket) when from == self(), do: {:noreply, socket}

  def handle_info({:board_join, peer, _from}, socket) do
    broadcast(socket.assigns.topic, {:board_hello, socket.assigns.me, self()})
    {:noreply, add_peer(socket, peer)}
  end

  def handle_info({:board_hello, _peer, from}, socket) when from == self(), do: {:noreply, socket}
  def handle_info({:board_hello, peer, _from}, socket), do: {:noreply, add_peer(socket, peer)}

  def handle_info({:board_leave, peer_id}, socket) do
    {:noreply,
     socket
     |> update(:peers, &Map.delete(&1, peer_id))
     |> push_event("cursor:remove", %{id: peer_id})}
  end

  def handle_info({:board_cursor, _id, _x, _y, from}, socket) when from == self(),
    do: {:noreply, socket}

  def handle_info({:board_cursor, id, x, y, _from}, socket) do
    peer = Map.get(socket.assigns.peers, id, %{name: "Guest", color: "#64748b"})

    {:noreply,
     push_event(socket, "cursor:update", %{id: id, x: x, y: y, name: peer.name, color: peer.color})}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:topic] && socket.assigns[:me] do
      broadcast(socket.assigns.topic, {:board_leave, socket.assigns.me.id})
    end

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp add_peer(socket, %{id: id} = peer),
    do: update(socket, :peers, &Map.put(&1, id, peer))

  defp identity(socket) do
    user = socket.assigns[:phoenix_kit_current_user]
    uuid = (user && Map.get(user, :uuid)) || "anon"
    name = (user && (Map.get(user, :email) || Map.get(user, :username))) || "Guest"
    # A per-connection id so two tabs of the same user are distinct peers.
    peer_id = "#{uuid}:#{Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)}"
    %{id: peer_id, name: to_string(name), color: color_for(peer_id)}
  end

  defp color_for(seed) do
    Enum.at(@cursor_colors, rem(:erlang.phash2(seed), length(@cursor_colors)))
  end

  defp topic(board_id), do: "phoenix_kit_boards:#{board_id}"

  defp broadcast(topic, msg), do: PubSub.broadcast(PubSubHelper.pubsub(), topic, msg)

  # ── Shape-list diff (by uuid) ───────────────────────────────────────────────

  defp diff(old, new) do
    old_by = index_by_uuid(old)
    new_by = index_by_uuid(new)
    old_ids = MapSet.new(Map.keys(old_by))
    new_ids = MapSet.new(Map.keys(new_by))

    created = new_ids |> MapSet.difference(old_ids) |> Enum.map(&Map.get(new_by, &1))
    deleted = old_ids |> MapSet.difference(new_ids) |> MapSet.to_list()

    updated =
      old_ids
      |> MapSet.intersection(new_ids)
      |> Enum.map(&Map.get(new_by, &1))
      |> Enum.filter(fn s -> s != Map.get(old_by, s["uuid"]) end)

    %{"created" => created, "updated" => updated, "deleted" => deleted}
  end

  defp index_by_uuid(list) do
    Enum.reduce(list, %{}, fn
      %{"uuid" => uuid} = shape, acc when is_binary(uuid) -> Map.put(acc, uuid, shape)
      _other, acc -> acc
    end)
  end

  defp empty_delta?(%{"created" => [], "updated" => [], "deleted" => []}), do: true
  defp empty_delta?(_), do: false

  # ── Render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-[calc(100vh-8rem)] min-h-[520px] px-4 py-4 gap-3">
      <header class="flex items-center gap-3 shrink-0">
        <.link
          navigate={Paths.boards()}
          class="btn btn-ghost btn-sm btn-circle"
          aria-label="Back to boards"
        >
          <.icon name="hero-arrow-left" class="w-5 h-5" />
        </.link>
        <span class="font-semibold truncate">{@board.name}</span>

        <div class="ml-auto flex items-center gap-2">
          <div class="flex -space-x-2">
            <span
              class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium text-white ring-2 ring-base-100"
              style={"background:#{@me.color}"}
              title={"#{@me.name} (you)"}
            >
              {initials(@me.name)}
            </span>
            <span
              :for={{_id, peer} <- @peers}
              class="inline-flex h-7 w-7 items-center justify-center rounded-full text-xs font-medium text-white ring-2 ring-base-100"
              style={"background:#{peer.color}"}
              title={peer.name}
            >
              {initials(peer.name)}
            </span>
          </div>
          <span class="text-xs text-base-content/50">
            {map_size(@peers) + 1} online
          </span>
        </div>
      </header>

      <%!-- phx-update="ignore": the canvas is hook-managed; LiveView must not
            re-render it. Collaboration flows through pushed events. --%>
      <div
        id="board-root"
        phx-hook="BoardSync"
        phx-update="ignore"
        data-fresco-id="board-canvas"
        class="relative flex-1 min-h-0 rounded-lg border border-base-300 overflow-hidden bg-base-200"
      >
        <Fresco.canvas
          id="board-canvas"
          canvas={@canvas}
          infinite_canvas
          theme={:inherit}
          class="w-full h-full"
        />
        <Etcher.layer fresco_id="board-canvas" toolbar tools={@tools} />
        <div
          id="board-cursors"
          phx-hook="BoardCursors"
          data-fresco-id="board-canvas"
          class="pointer-events-none absolute inset-0 overflow-hidden"
        >
        </div>
      </div>
    </div>
    """
  end

  defp initials(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.first()
    |> Kernel.||("?")
    |> String.upcase()
  end
end
