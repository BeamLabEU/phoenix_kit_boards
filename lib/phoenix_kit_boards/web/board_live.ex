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
  alias PhoenixKit.Users.Auth
  alias PhoenixKitBoards.{Boards, LinkPreview, Paths}
  alias PhoenixKitBoards.Web.BoardSocket
  alias PhoenixKitBoards.Web.RuntimeHooks

  # Pasted / dropped images go to storage; the shape keeps a URL.
  #
  # Left alone, Etcher embeds an image file in the shape as a base64 data URL.
  # Since the whole annotation list is re-emitted on every edit, an embedded
  # screenshot is then re-sent in full every time anything on the board
  # changes — moving a shape, typing a label. Two or three images is enough to
  # push an ordinary edit past the socket's frame limit, and past it the socket
  # closes and the edit is lost with nothing shown to the user. Uploading costs
  # one request and keeps the list small however many images a board collects.
  # MIME types as well as extensions: a file off the clipboard is not
  # guaranteed to arrive with a usable filename, but it always carries a type.
  @image_accept ~w(
    .png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp
    .mp3 .m4a .wav .ogg .opus audio/mpeg audio/mp4 audio/wav audio/ogg audio/opus
    .mp4 .m4v .webm .mov video/mp4 video/webm video/quicktime
  )

  # `allow_upload` RAISES on any filter the `mime` library can't resolve, and
  # what it can resolve depends on the HOST's `config :mime` — not on anything
  # this module can see. On a default install `.m4a`, `.ogg`, `.m4v` and the
  # `audio/mp4` type are all unresolvable, and each one took the whole board
  # page down with an ArgumentError at mount rather than degrading.
  #
  # So the list is filtered rather than trusted, applying LiveView's own two
  # rules (`Phoenix.LiveView.UploadConfig`): an extension needs a known type,
  # and a type needs at least one known extension. Every format is named both
  # ways here, so dropping one form still leaves the other — a narrower file
  # picker, not a rejected format. Adding the mapping to the host's
  # `config :mime` restores it.
  defp upload_accept do
    Enum.filter(@image_accept, fn
      "." <> ext -> MIME.has_type?(ext)
      type -> MIME.extensions(type) != []
    end)
  end

  # One cap for all three kinds, sized for video: a screen recording runs to
  # hundreds of MB where a pasted screenshot is under one. The ceiling is the
  # upload channel's, not the socket's 8MB frame limit — LiveView uploads
  # chunk over their own channel.
  #
  # Past this, the answer isn't a bigger number: it's an external uploader
  # (`allow_upload(..., external: ...)`) so bytes go straight to storage
  # instead of through the server. Worth doing when someone actually hits it.
  @image_max_bytes 256_000_000

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
    :eraser,
    :pointer
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
        {board, canvas} = migrate_embedded_images(board, socket)
        me = identity(socket)
        topic = topic(board.uuid)

        PubSubHelper.subscribe(topic)
        broadcast(topic, {:board_join, me, self()})

        {:ok,
         socket
         |> assign(:page_title, board.name)
         |> assign(:board, board)
         |> assign(:canvas, canvas)
         # The canvas the TEMPLATE draws, assigned once and never again.
         #
         # `@canvas` carries the annotations, and `Fresco.canvas` writes them
         # into `data-extensions` as JSON — so re-rendering it costs an encode
         # and a diff of the whole board, and sends the result down the socket.
         # On a board of any size that is enormous (5 MB on the demo board),
         # and it happened on every edit, from either end.
         #
         # All of it was waste: `#board-root` is `phx-update="ignore"`, so the
         # client discards the markup and takes its updates from `board:apply`
         # instead. What it cost was real, though — the encode blocked the
         # process while cursor messages queued behind it, which is what made
         # remote cursors choppy and seconds late, and a frame that size per
         # edit is enough to drop the socket and remount the peer.
         #
         # Separating the two assigns leaves change tracking with nothing to
         # do: this one never changes, so the canvas subtree is rendered at
         # mount and skipped forever after, while `@canvas` stays current for
         # persistence without ever reaching the template.
         |> assign(:initial_canvas, canvas)
         |> assign(:annotations, Boards.annotations(canvas))
         |> assign(:tools, @tools)
         |> assign(:topic, topic)
         |> assign(:me, me)
         |> allow_upload(:board_image,
           accept: upload_accept(),
           max_entries: 1,
           max_file_size: @image_max_bytes,
           auto_upload: true,
           progress: &handle_image_progress/3
         )
         # Deliberately nothing pushed here. See `handle_event("board:ready")`.
         |> assign(:peers, %{})}
    end
  end

  # Boards written before images were uploaded — or while an upload was
  # failing — carry the bytes inline. Doing this at open rather than waiting
  # for an edit means the first edit is already a fast one, and a board nobody
  # has touched since still gets lighter.
  #
  # Costs nothing on a board with nothing embedded: one pass over the list,
  # no write.
  defp migrate_embedded_images(board, socket) do
    canvas = Boards.load_canvas(board)
    annotations = Boards.annotations(canvas)

    case hoist_embedded_images(annotations, socket) do
      {_annotations, []} ->
        {board, canvas}

      {hoisted, moved} ->
        Logger.info("[boards] moved #{length(moved)} embedded image(s) into storage")

        case Boards.save_annotations(board, canvas, hoisted) do
          {:ok, canvas, board} ->
            {board, canvas}

          {:error, reason} ->
            # The board still works, it is just still heavy.
            Logger.warning("[boards] could not save the migrated board: #{inspect(reason)}")
            {board, canvas}
        end
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
      # Nothing is drawn from this — Etcher places the shape immediately and
      # uploads behind it, so there is no bar to fill. It is the client's
      # proof that the transfer is still alive, which is what stops
      # `armUploadWatchdog` giving up on a big slow upload.
      {:noreply, push_event(socket, "board:image-progress", %{"progress" => entry.progress})}
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
         {:ok, file} <- store(path, user_uuid, checksum, entry),
         url when is_binary(url) <- Storage.get_public_url(file) do
      {:ok, url}
    else
      nil -> {:error, :no_url_for_stored_file}
      {:error, reason} -> {:error, reason}
    end
  end

  # `store_file_in_buckets/6` does the per-user dedupe itself, so pasting the
  # same screenshot onto two boards still stores one file — and it does more
  # than a lookup would: on a hit it checks the object is *still in the
  # bucket* and re-stores it (or recreates a lost instance record) when it
  # isn't. Short-circuiting on `get_file_by_user_checksum/1` here would skip
  # that repair, and a file that had gone missing from storage would hand
  # back a dead URL on every subsequent paste, forever.
  defp store(path, user_uuid, checksum, entry) do
    path
    |> Storage.store_file_in_buckets(
      "image",
      user_uuid,
      checksum,
      ext_for(entry),
      entry.client_name
    )
    |> normalize_stored()
  end

  # `store_file_in_buckets/6` answers `{:ok, file, :duplicate}` when it
  # recognises the bytes. Same file either way, so flatten to `{:ok, file}`
  # rather than let the 3-tuple fall through as a failure and send the client
  # back to embedding the image it just uploaded successfully.
  defp normalize_stored({:ok, file, _dedupe}), do: {:ok, file}
  defp normalize_stored(other), do: other

  # The extension decides how the stored object is named and served, and the
  # filename is the unreliable half of an entry — a clipboard paste is not
  # guaranteed to carry a usable one, which is why `@image_accept` lists MIME
  # types too. Fall back to the type when the name has nothing to give.
  defp ext_for(entry) do
    case entry.client_name |> Path.extname() |> String.replace_leading(".", "") do
      "" -> entry.client_type |> to_string() |> MIME.extensions() |> List.first() || "bin"
      ext -> ext
    end
  end

  defp file_checksum(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, :md5 |> :crypto.hash(data) |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Embedded images → storage ─────────────────────────────────────────────
  #
  # An image whose upload failed is embedded as a base64 `data:` URL so the
  # paste survives (see `reply_to_upload/2`). That rescue has a long tail: the
  # bytes are then part of the shape, and the client re-sends every shape on
  # every edit — so one 3.7 MB screenshot is 3.7 MB up the socket each time
  # anyone nudges a marker, forever. The demo board carried four of them,
  # 5.34 MB of the 5.36 MB it sent per edit; the drawing itself was 23 KB.
  #
  # So the bytes are moved into storage the first time they arrive, and the
  # shape rewritten to point at the stored file — the same place a successful
  # upload would have put them. One-time per image, and the board is small
  # from then on. The sender is told about the rewrite too, or it would keep
  # the data URL and send it again on the next edit.
  #
  # Failure here is not fatal: the shape keeps its data URL and the board
  # stays heavy, which is where it already was.
  defp hoist_embedded_images(annotations, socket) do
    if Enum.any?(annotations, &embedded_image?/1) do
      Enum.map_reduce(annotations, [], &hoist_one(&1, &2, socket))
    else
      # The overwhelmingly common case: nothing embedded, so this costs one
      # pass over the list and no work at all.
      {annotations, []}
    end
  end

  defp hoist_one(shape, done, socket) do
    case hoist_shape(shape, socket) do
      {:ok, rewritten} -> {rewritten, [rewritten | done]}
      :error -> {shape, done}
    end
  end

  defp embedded_image?(%{"geometry" => %{"href" => "data:" <> _}}), do: true
  defp embedded_image?(_), do: false

  # The sender is excluded from its own broadcast, so without this it would
  # still be holding the data URL and would send the bytes up again on its
  # next edit — the board would never actually get lighter for the person
  # doing the work.
  defp tell_sender_about_hoisted(socket, [], _annotations), do: socket

  defp tell_sender_about_hoisted(socket, hoisted, annotations) do
    push_event(socket, "board:apply", %{
      "updated" => hoisted,
      # Re-adding a shape appends, so the layering has to be re-imposed —
      # same reason the peer path sends it.
      "order" => uuid_order(annotations)
    })
  end

  defp hoist_shape(%{"geometry" => %{"href" => "data:" <> _ = href} = geom} = shape, socket) do
    case store_data_url(href, socket) do
      {:ok, url} ->
        {:ok, Map.put(shape, "geometry", Map.put(geom, "href", url))}

      {:error, reason} ->
        Logger.warning(
          "[boards] could not move an embedded image into storage: #{inspect(reason)}"
        )

        :error
    end
  end

  defp hoist_shape(_shape, _socket), do: :error

  defp store_data_url(href, socket) do
    with {:ok, bytes, ext} <- decode_data_url(href),
         {:ok, user_uuid} <- require_user(uploader_uuid(socket)) do
      # A name only for the extension and for what the file is called in the
      # library; the bytes are deduped by checksum like any other upload, so
      # re-hoisting the same image twice does not store it twice.
      name = "pasted-image-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}.#{ext}"
      path = Path.join(System.tmp_dir!(), name)

      # Stored through the same path an upload takes, so this inherits the
      # re-store-on-missing repair `store/4` exists for rather than quietly
      # skipping it. `ext_for/1` reads these two fields and nothing else.
      entry = %{client_name: name, client_type: MIME.type(ext)}

      try do
        with :ok <- File.write(path, bytes),
             {:ok, checksum} <- file_checksum(path),
             {:ok, file} <- store(path, user_uuid, checksum, entry),
             url when is_binary(url) <- Storage.get_public_url(file) do
          {:ok, url}
        else
          nil -> {:error, :no_url_for_stored_file}
          {:error, reason} -> {:error, reason}
        end
      after
        File.rm(path)
      end
    end
  end

  @doc false
  # Public only so the parsing can be tested directly — it reads bytes off the
  # wire, and the suite runs without storage or a database.
  def decode_data_url("data:" <> rest) do
    with [meta, encoded] <- String.split(rest, ",", parts: 2),
         true <- String.contains?(meta, ";base64"),
         {:ok, bytes} <- decode_base64(encoded) do
      {:ok, bytes, meta |> String.split(";") |> List.first() |> image_ext()}
    else
      # A `data:` URL that isn't base64 is percent-encoded text — an inline
      # SVG, most likely. Left alone rather than guessed at: it is small, so
      # it is not what makes a board heavy.
      false -> {:error, :not_base64}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :malformed_data_url}
    end
  end

  def decode_data_url(_), do: {:error, :not_a_data_url}

  defp decode_base64(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :bad_base64}
    end
  end

  defp image_ext("image/jpeg"), do: "jpg"
  defp image_ext("image/svg+xml"), do: "svg"
  defp image_ext("image/" <> subtype), do: String.replace(subtype, ~r/[^a-z0-9]/, "")
  defp image_ext(_), do: "png"

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
  # The client says when it can hear us, and only then is anything pushed.
  #
  # A `push_event` in the connected mount rides the join reply and is
  # dispatched the instant it lands. That was fine while hooks were registered
  # on the host's LiveSocket at construction time — `mounted` had already run.
  # Under this module's own runtime-hook delivery it is a race that is always
  # lost: the shim's `mounted` starts a ~40 KB fetch and the REAL
  # `BoardSync.mounted` — where `handleEvent("board:channel")` is registered —
  # runs hundreds of milliseconds later. The events dispatch to nobody and are
  # gone.
  #
  # The visible result was a board that rendered, edited and saved, while live
  # cursors, in-flight drags and stored preferences never appeared — because
  # the channel token and the prefs both arrived before anything was listening.
  # A host log showed 12 successful bundle fetches and zero BoardSocket
  # connections.
  #
  # So the hooks announce themselves and this answers. Correct under both
  # delivery models — a host-registered hook simply sends the ping a few
  # milliseconds earlier — and any push added here later inherits the same
  # guarantee. The extra round trip is dwarfed by the fetch it replaces
  # racing.
  #
  # Answered on EVERY ping rather than once. Both hooks ping, and whichever
  # mounts last triggers a push that both are registered for by then; the
  # handlers are idempotent (`BoardLink.ensure` reuses a live connection,
  # `setPrefs` re-applies the same set), so the duplicate costs nothing and
  # removes any need to reason about which hook won the race.
  def handle_event("board:ready", _params, socket) do
    board = socket.assigns.board

    {:noreply,
     socket
     |> push_event("board:prefs", %{prefs: load_prefs(socket)})
     # Lets the client open the ephemeral channel — cursors and in-flight
     # drags. It falls back to relaying them through here if the host hasn't
     # mounted the socket, so this is an offer rather than a requirement.
     |> push_event("board:channel", %{
       token: BoardSocket.sign(socket, board.uuid, socket.assigns.me),
       topic: "board:#{board.uuid}",
       # Where the host mounted the socket. It picks the path, so it has to be
       # the one to say — the client cannot guess it.
       path: BoardSocket.mount_path()
     })}
  end

  def handle_event("etcher:annotations-changed", %{"annotations" => incoming}, socket)
      when is_list(incoming) do
    if empty_delta?(diff(socket.assigns.annotations, incoming)) do
      {:noreply, socket}
    else
      # Told to the room before it is written down.
      #
      # Saving means encoding the whole board and writing it back, which on a
      # large one is not quick — and this ran first, so every peer waited out
      # a database round trip before seeing an edit that was already decided.
      # Nothing in the message depends on the result, so the wait bought them
      # nothing.
      #
      # A save that then fails leaves peers holding an edit that was not
      # stored, which the flash below reports and the next successful save
      # corrects. Being a moment optimistic is a better trade than making
      # every collaborator wait on the disk.
      # Any image still carrying its bytes goes to storage first, so what is
      # broadcast, stored and re-sent from here on is a URL.
      {annotations, hoisted} = hoist_embedded_images(incoming, socket)

      broadcast(socket.assigns.topic, {:board_annotations, annotations, self()})

      case Boards.save_annotations(socket.assigns.board, socket.assigns.canvas, annotations) do
        {:ok, canvas, board} ->
          {:noreply,
           socket
           |> assign(:board, board)
           |> assign(:canvas, canvas)
           |> assign(:annotations, annotations)
           |> tell_sender_about_hoisted(hoisted, annotations)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not save the board.")}
      end
    end
  end

  def handle_event("etcher:annotations-changed", _params, socket), do: {:noreply, socket}

  # The upload form's `phx-change`. Nothing to do here — `auto_upload: true`
  # starts the transfer and `handle_image_progress/3` does the work — but the
  # event has to be handled: it is the only thing that tells the server an
  # entry exists at all.
  def handle_event("board_image_selected", _params, socket), do: {:noreply, socket}

  # A pasted URL. Renders a preview card as an SVG and replies with it; the
  # client rasterises that, sends it back through the image-upload path
  # above, and swaps the pasted text for the stored card. Replying with an
  # error is not a failure path worth shouting about — without an answer
  # Etcher simply leaves the link on the canvas as text.
  #
  # Rescued rather than trusted to return: the whole point of the fallback is
  # that a bad link costs the user nothing, and an unhandled raise anywhere
  # in the fetch/parse/render chain would instead take the board down and
  # make them reconnect. Untrusted input reaches every step of it.
  def handle_event("board:unfurl", %{"url" => url}, socket) when is_binary(url) do
    {:reply, unfurl_reply(url), socket}
  end

  def handle_event("board:unfurl", _params, socket),
    do: {:reply, %{"error" => "bad_request"}, socket}

  # Other etcher client events we don't persist here (tools, colors, tooltips…).
  # Shared playback. Anyone may drive it, so there is no ownership check and
  # no conflict resolution: the command is relayed verbatim and the last one
  # to arrive wins. The sender has already applied it locally — this only
  # carries it to everyone else.
  #
  # Both fields are relayed verbatim to every peer, so both are checked for
  # being strings at all — the same reason `cursor_tool/1` exists. Not narrowed
  # further: the transport vocabulary is etcher's, and a whitelist here would
  # silently drop a command a later release adds. A malformed one falls to the
  # `"etcher:" <> _` clause below and is ignored.
  def handle_event("etcher:media-command", %{"uuid" => uuid, "action" => action} = params, socket)
      when is_binary(uuid) and is_binary(action) do
    position = normalize_position(params["position"])
    broadcast(socket.assigns.topic, {:board_media, uuid, action, position, self()})
    {:noreply, socket}
  end

  # A client answering the announce request above. Relayed to the room rather
  # than to the newcomer alone: this process has no idea which peer asked,
  # and everyone else is already at these positions.
  def handle_event("etcher:media-announce", %{"states" => states}, socket) when is_list(states) do
    Enum.each(states, fn
      %{"uuid" => uuid, "playing" => playing} = st when is_binary(uuid) and is_boolean(playing) ->
        broadcast(
          socket.assigns.topic,
          {:board_media, uuid, if(playing, do: "play", else: "pause"),
           normalize_position(st["position"]), self()}
        )

      _ ->
        :ok
    end)

    {:noreply, socket}
  end

  def handle_event("etcher:" <> _rest, _params, socket), do: {:noreply, socket}

  # The user changed how they like the board set up — which tools are on the
  # bar, how much of the style panel is open, whether the dots are shown.
  #
  # Kept against the USER rather than the board: these are answers about how
  # someone works, not facts about a drawing, and a board a person opens for
  # the first time should already look the way they arranged the last one.
  # Two people on the same board keep their own answers.
  #
  # Etcher does not know or care that this is where they end up. It emits the
  # change and accepts them back; a host storing them in a cookie, a
  # per-board row, or nowhere at all satisfies the same contract.
  def handle_event("etcher:prefs-changed", prefs, socket) when is_map(prefs) do
    {:noreply, save_prefs(socket, prefs)}
  end

  # A local pointer move → broadcast our cursor (canvas coords) to peers.
  #
  # This is the FALLBACK path. Cursors normally go over the board's own
  # channel, which doesn't come through here at all; this is what a host that
  # hasn't mounted that socket still gets.
  #
  # `pointer` says this person has the red pointer armed, so peers draw them
  # as a laser dot rather than an arrow with their name on it, and `tool` is
  # what they are holding. Both ride the cursor message instead of having one
  # of their own because both are facts about this person's cursor — separate
  # streams would race with this one and show the wrong thing for a moment on
  # every change.
  def handle_event("cursor:move", %{"x" => x, "y" => y} = params, socket) do
    meta = %{pointer: params["pointer"] == true, tool: cursor_tool(params["tool"])}

    broadcast(
      socket.assigns.topic,
      {:board_cursor, socket.assigns.me.id, x, y, meta, self()}
    )

    {:noreply, socket}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Arrives from a browser, so it can be anything. Bounded and constrained to
  # the shape a tool key has — it is relayed to every peer and ends up in a
  # DOM lookup, so an arbitrary string has no business travelling.
  defp cursor_tool(tool) when is_binary(tool) do
    if byte_size(tool) <= 32 and String.match?(tool, ~r/\A[a-z][a-z0-9_]*\z/), do: tool
  end

  defp cursor_tool(_), do: nil

  defp unfurl_reply(url) do
    case LinkPreview.unfurl(url) do
      {:ok, %{svg: svg, width: w, height: h}} ->
        %{"svg" => svg, "width" => w, "height" => h}

      {:error, reason} ->
        Logger.info("[boards] link preview declined for #{inspect(url)}: #{inspect(reason)}")
        %{"error" => to_string(elem_or(reason))}
    end
  rescue
    error ->
      Logger.warning(
        "[boards] link preview crashed for #{inspect(url)}: #{Exception.message(error)}"
      )

      %{"error" => "unfurl_failed"}
  end

  defp elem_or(reason) when is_tuple(reason), do: elem(reason, 0)
  defp elem_or(reason), do: reason

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
  def handle_info({:board_media, _uuid, _action, _position, from}, socket) when from == self(),
    do: {:noreply, socket}

  def handle_info({:board_media, uuid, action, position, _from}, socket) do
    {:noreply,
     push_event(socket, "board:media", %{
       "uuid" => uuid,
       "action" => action,
       "position" => position
     })}
  end

  def handle_info({:board_join, _peer, from}, socket) when from == self(), do: {:noreply, socket}

  def handle_info({:board_join, peer, _from}, socket) do
    broadcast(socket.assigns.topic, {:board_hello, socket.assigns.me, self()})

    {:noreply,
     socket
     |> add_peer(peer)
     # Playback travels as commands, so a newcomer arriving between two of
     # them would sit silent with no idea what is playing. Say where we are.
     # Peers already in sync ignore the answer — it lands inside etcher's
     # drift tolerance — so this costs one round trip per join and nothing
     # else.
     |> push_event("board:media-announce", %{})}
  end

  def handle_info({:board_hello, _peer, from}, socket) when from == self(), do: {:noreply, socket}
  def handle_info({:board_hello, peer, _from}, socket), do: {:noreply, add_peer(socket, peer)}

  def handle_info({:board_leave, peer_id}, socket) do
    {:noreply,
     socket
     |> update(:peers, &Map.delete(&1, peer_id))
     |> push_event("cursor:remove", %{id: peer_id})}
  end

  def handle_info({:board_cursor, _id, _x, _y, _meta, from}, socket) when from == self(),
    do: {:noreply, socket}

  # Everything about a cursor except where it is travels in one map, so
  # telling peers something new about it doesn't mean another element on the
  # message and another clause below to read the old shape.
  def handle_info({:board_cursor, id, x, y, meta, _from}, socket) when is_map(meta) do
    peer = Map.get(socket.assigns.peers, id, %{name: "Guest", color: "#64748b"})

    {:noreply,
     push_event(socket, "cursor:update", %{
       id: id,
       x: x,
       y: y,
       name: peer.name,
       color: peer.color,
       pointer: meta[:pointer] == true,
       tool: meta[:tool]
     })}
  end

  # Peers still running an earlier release send the older shapes: a bare
  # `pointer` boolean, or nothing at all. Read rather than crashing the board
  # for everyone on it — during a rolling deploy several shapes are on the
  # topic at once.
  def handle_info({:board_cursor, id, x, y, pointer, from}, socket) when is_boolean(pointer) do
    handle_info({:board_cursor, id, x, y, %{pointer: pointer, tool: nil}, from}, socket)
  end

  def handle_info({:board_cursor, _id, _x, _y, from}, socket) when from == self(),
    do: {:noreply, socket}

  def handle_info({:board_cursor, id, x, y, from}, socket) do
    handle_info({:board_cursor, id, x, y, %{pointer: false, tool: nil}, from}, socket)
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

  # ── Preferences, stored on the user ───────────────────────────────────────

  @prefs_field "etcher_prefs"

  defp load_prefs(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{custom_fields: %{@prefs_field => prefs}} when is_map(prefs) -> prefs
      # A signed-out visitor, or someone who has never changed anything.
      # Etcher treats an empty map as "nothing stored" and keeps its own
      # defaults, so there is nothing to special-case here.
      _ -> %{}
    end
  end

  defp save_prefs(socket, prefs) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{} = user ->
        # Merged inside the UPDATE rather than read-modify-written here: a
        # user with two boards open would otherwise have whichever tab saved
        # second silently overwrite the other's keys.
        case Auth.merge_user_custom_fields(user, %{@prefs_field => prefs}) do
          {:ok, updated} -> assign(socket, :phoenix_kit_current_user, updated)
          # The row went away underneath us, or the write failed. Preferences
          # are a convenience — losing one is not worth interrupting whatever
          # the person is drawing.
          _ -> socket
        end

      _ ->
        # Nobody to store them against. Etcher falls back to localStorage on
        # its own, so a signed-out user still keeps their setup on this
        # browser; it just cannot follow them anywhere.
        socket
    end
  end

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

  # A position arrives from the browser, so it can be anything. Anything that
  # isn't a usable number becomes 0 rather than being relayed onward to make
  # every peer seek somewhere undefined.
  defp normalize_position(pos) when is_number(pos) and pos >= 0, do: pos * 1.0
  defp normalize_position(_), do: 0.0

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

      <%!-- Delivers BoardSync + BoardCursors without the host wiring anything.
            Before the elements that use them: LiveView re-creates a runtime-hook
            script as the patch adds it, and a hook is resolved when its element
            mounts, which is after. --%>
      <RuntimeHooks.scripts nonce={assigns[:script_csp_nonce]} />

      <%!-- phx-update="ignore": the canvas is hook-managed; LiveView must not
            re-render it. Collaboration flows through pushed events. --%>
      <div
        id="board-root"
        phx-hook="BoardSync"
        phx-update="ignore"
        data-fresco-id="board-canvas"
        class="relative flex-1 min-h-0 rounded-lg border border-base-300 overflow-hidden bg-base-200"
      >
        <%!-- `@initial_canvas`, not `@canvas`: rendered once at mount and
              never re-rendered. See `mount_connected/2`. --%>
        <Fresco.canvas
          id="board-canvas"
          canvas={@initial_canvas}
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
            phx-update="ignore" and therefore off-limits to LiveView.

            The form is load-bearing, not decoration: `this.upload/2` tracks
            the files and then dispatches a bubbling `input` event, and a
            form's `phx-change` is what carries that to the server. Without
            one the event bubbles into nothing, the server is never told an
            entry exists, and the upload silently never happens. --%>
      <form id="board-image-upload-form" phx-change="board_image_selected" class="hidden">
        <.live_file_input upload={@uploads.board_image} tabindex="-1" />
      </form>
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
