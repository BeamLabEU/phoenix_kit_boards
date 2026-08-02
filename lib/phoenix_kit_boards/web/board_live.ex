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

  require Logger

  alias Phoenix.PubSub
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.PubSubHelper
  alias PhoenixKitBoards.{Boards, Paths}

  # Pasted / dropped images go to storage; the shape keeps a URL.
  #
  # Left alone, Etcher embeds an image file in the shape as a base64 data URL.
  # Since the whole annotation list is re-emitted on every edit, an embedded
  # screenshot is then re-sent in full every time anything on the board
  # changes — moving a shape, typing a label. Two or three images is enough to
  # push an ordinary edit past the socket's frame limit, and past it the socket
  # closes and the edit is lost with nothing shown to the user. Uploading costs
  # one request and keeps the list small however many images a board collects.
  @image_accept ~w(.png .jpg .jpeg .gif .webp)
  @image_max_bytes 25_000_000

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
    # LiveView mounts twice — once for the HTTP render, once on WebSocket
    # connect — so anything done unconditionally here runs twice. The
    # disconnected pass is pure waste on this page: #board-root is
    # `phx-update="ignore"` and driven entirely by the BoardSync/BoardCursors
    # hooks, so a server-rendered canvas is discarded the moment JS takes over,
    # and the board is unusable without a socket regardless. Load nothing and
    # render a spinner; `render/1` has a matching `board: nil` clause that
    # deliberately omits #board-root, so the connected render inserts that
    # subtree fresh rather than having `phx-update="ignore"` pin a skeleton.
    if connected?(socket) do
      mount_connected(id, socket)
    else
      {:ok, assign(socket, :board, nil)}
    end
  end

  defp mount_connected(id, socket) do
    case Boards.get_board(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Board not found.")
         |> push_navigate(to: Paths.boards())}

      board ->
        canvas = Boards.load_canvas(board)
        me = identity(socket)
        topic = topic(board.uuid)

        PubSubHelper.subscribe(topic)
        broadcast(topic, {:board_join, me, self()})

        {:ok,
         socket
         |> assign(:page_title, board.name)
         |> assign(:board, board)
         |> assign(:canvas, canvas)
         |> assign(:annotations, Boards.annotations(canvas))
         |> assign(:tools, @tools)
         |> assign(:topic, topic)
         |> assign(:me, me)
         |> assign(:peers, %{})
         |> allow_upload(:board_image,
           accept: @image_accept,
           max_entries: 1,
           max_file_size: @image_max_bytes,
           auto_upload: true,
           progress: &handle_image_progress/3
         )}
    end
  end

  # ── Image upload (paste / drop / picker) ──────────────────────────────────
  #
  # Driven entirely from JS: `BoardSync` registers an uploader with Etcher and
  # calls `this.upload/2`, so the `live_file_input` in the template is never
  # shown or clicked — it exists because that's how LiveView locates an upload
  # by name. One entry at a time, and the hook serialises pastes to match,
  # which is what lets the client pair a reply with its request by order.
  defp handle_image_progress(:board_image, entry, socket) do
    if entry.done? do
      result = consume_uploaded_entry(socket, entry, &{:ok, store_image(&1.path, entry, socket)})
      {:noreply, reply_to_upload(socket, result)}
    else
      {:noreply, socket}
    end
  end

  defp reply_to_upload(socket, {:ok, url}) do
    push_event(socket, "board:image-uploaded", %{"url" => url})
  end

  defp reply_to_upload(socket, {:error, reason}) do
    # The client falls back to embedding the image, so the paste survives at
    # the cost of payload size. Say why in the log — a board silently getting
    # heavier again is exactly the failure this whole path exists to prevent.
    Logger.warning("[boards] image upload failed (#{inspect(reason)}); client will embed it")
    push_event(socket, "board:image-upload-failed", %{"reason" => inspect(reason)})
  end

  defp store_image(path, entry, socket) do
    user_uuid = uploader_uuid(socket)

    with {:ok, user_uuid} <- require_user(user_uuid),
         {:ok, checksum} <- file_checksum(path),
         {:ok, file} <- store_or_reuse(path, user_uuid, checksum, entry),
         url when is_binary(url) <- Storage.get_public_url(file) do
      {:ok, url}
    else
      nil -> {:error, :no_url_for_stored_file}
      {:error, reason} -> {:error, reason}
    end
  end

  # Same per-user dedupe the upload controller does, so pasting the same
  # screenshot onto two boards stores one file.
  defp store_or_reuse(path, user_uuid, checksum, entry) do
    case Storage.get_file_by_user_checksum(
           Storage.calculate_user_file_checksum(user_uuid, checksum)
         ) do
      nil ->
        ext = entry.client_name |> Path.extname() |> String.replace_leading(".", "")

        path
        |> Storage.store_file_in_buckets("image", user_uuid, checksum, ext, entry.client_name)
        |> normalize_stored()

      existing ->
        {:ok, existing}
    end
  end

  # `store_file_in_buckets/6` answers `{:ok, file, :duplicate}` when it
  # recognises the bytes — the per-user check above doesn't catch that, since
  # it keys on the user. Same file either way, so flatten to `{:ok, file}`
  # rather than let the 3-tuple fall through as a failure and send the client
  # back to embedding the image it just uploaded successfully.
  defp normalize_stored({:ok, file, _dedupe}), do: {:ok, file}
  defp normalize_stored(other), do: other

  defp file_checksum(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, :md5 |> :crypto.hash(data) |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Storage files belong to a user. The board pages are behind admin auth so
  # there always is one; bail rather than invent an owner if that changes.
  defp require_user(nil), do: {:error, :no_user}
  defp require_user(uuid), do: {:ok, uuid}

  defp uploader_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) -> uuid
      _ -> nil
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

  # Position in the annotation list *is* z-order — etcher paints in array
  # order — so the diff has to treat a reshuffle as a real change. Keying
  # purely by uuid made a pure reorder look identical to no edit at all:
  # `empty_delta?` returned true, so bringing a caption in front of an image
  # was never saved and never reached the other viewers.
  #
  # `order` carries the full uuid list on every delta, not just reorders. The
  # client applies created/updated/deleted by removing and re-adding shapes,
  # and re-adding appends — which would scramble layering on any edit at all.
  # Re-imposing the authoritative order afterwards makes that self-correcting.
  @doc false
  # Public only so the delta rules can be tested directly — this is where a
  # silently-dropped reorder would hide, and the suite runs without a DB.
  def diff(old, new) do
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

    %{
      "created" => created,
      "updated" => updated,
      "deleted" => deleted,
      "order" => uuid_order(new),
      # Compared over the shapes present in both, so a create or delete
      # doesn't masquerade as a reorder — those are already reported above.
      "reordered" => reordered?(old, new)
    }
  end

  defp uuid_order(list) do
    for %{"uuid" => uuid} <- list, is_binary(uuid), do: uuid
  end

  defp reordered?(old, new) do
    old_ids = old |> uuid_order() |> MapSet.new()
    new_ids = new |> uuid_order() |> MapSet.new()
    survivors = MapSet.intersection(old_ids, new_ids)

    kept = fn list -> list |> uuid_order() |> Enum.filter(&MapSet.member?(survivors, &1)) end

    kept.(old) != kept.(new)
  end

  defp index_by_uuid(list) do
    Enum.reduce(list, %{}, fn
      %{"uuid" => uuid} = shape, acc when is_binary(uuid) -> Map.put(acc, uuid, shape)
      _other, acc -> acc
    end)
  end

  @doc false
  def empty_delta?(%{
        "created" => [],
        "updated" => [],
        "deleted" => [],
        "reordered" => false
      }),
      do: true

  def empty_delta?(_), do: false

  # ── Render ───────────────────────────────────────────────────────────────

  # Disconnected render: no board loaded yet, and deliberately no #board-root —
  # see `mount/3`.
  @impl true
  def render(%{board: nil} = assigns) do
    ~H"""
    <div class="flex items-center justify-center h-[calc(100vh-8rem)] min-h-[520px]">
      <span class="loading loading-spinner loading-lg text-base-content/40"></span>
    </div>
    """
  end

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

      <%!-- The upload target for pasted / dropped images. Never shown and
            never clicked — `BoardSync` feeds it files through `this.upload/2`
            — but LiveView finds an upload by locating its input in the DOM,
            so it has to be here. Outside #board-root, which is
            phx-update="ignore" and therefore off-limits to LiveView. --%>
      <.live_file_input upload={@uploads.board_image} class="hidden" tabindex="-1" />
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
