defmodule PhoenixKitBoards.Web.BoardsPanel do
  @moduledoc """
  A widget for the quick boards of one place — drop it into a section of your
  own page, wherever people jot things down.

      <PhoenixKitBoards.Web.Components.boards_panel
        id="project-notes"
        scope={{"project", @project.uuid}}
        label="Notes"
        current_user={@current_scope.user}
        return_to={~p"/projects/\#{@project}"}
      />

  (or `<.live_component module={PhoenixKitBoards.Web.BoardsPanel} id=… … />` —
  they are the same thing.)

  It is a grid of tiles, one per board, and a last tile of the same size that
  makes a new one. Until there is a board, that tile is all there is, centred:

    * the big **+** makes an empty canvas and opens it;
    * **Text** makes a canvas with a note already on it;
    * **Image** takes a picture (the phone's camera, or any file — it is also a
      drop target) and makes a canvas with it already on it.

  Text and image boards stay on the page and appear as tiles; the empty one
  opens, because there is nothing in it to see. Each tile has a menu: rename,
  pin, make private or shared, archive, delete.

  **Paste.** Click into the widget (or tab to it) and paste: text makes a note
  board, and images — one or several, with any text that came with them — make
  ONE board holding all of them. It only listens while the widget has focus, and
  never while you are typing in one of its fields, so a paste anywhere else on
  the page is untouched. The new-board tile shows a faint hint while it is
  listening, and a short notice with **Undo** follows each paste. The board is
  not opened, so several pastes in a row are fine. `paste={false}` turns it off.

  The widget does not manage places or projects — *you* decide what place it
  is for, by `scope`, and put one wherever you want one.

  ## Attributes

    * `id` — required, unique on the page
    * `current_user` — required; with none the widget only asks to sign in
    * `scope` — `{type, id}` naming the place; each a string, integer or atom
      (`{"project", uuid}`, `{"order", 1001}`, `{"page", "/docs/setup"}`), kept as
      strings, which is what the `:authorize` hook is given. `nil` is the boards
      that belong nowhere — the ones `/admin/boards` lists — and like them is
      shown only to users holding `"boards.manage"`; a place with
      a missing id shows nothing at all
    * `label` — what the place's media folder is called, and a small heading
    * `show_label` — `false` to keep the label for the folder name but not draw
      it (default `true`), for a page that already has its own heading
    * `folder` — where the files of these boards go, see
      `PhoenixKitBoards.MediaFolders` (`{:under, uuid}`, `{:path, ["Clients",
      "Acme"]}`, `:root`, or a function); omit it for the host's hook or the
      default `Boards / <place> / <board>`
    * `visibility_options` — which of `[:private, :shared]` a person may choose
      (default both; one value hides the choice, so `[:private]` makes a
      personal notepad and `[:shared]` a team one)
    * `default_visibility` — `:shared` or `:private`
    * `actions` — which ways to start a board to offer, from `[:empty, :text,
      :image]` (default all three)
    * `paste` — `false` to switch off paste-to-make-a-board (default `true`)
    * `script_nonce` — CSP nonce for the one `<script>` the paste behaviour
      needs, for a host that enforces a Content-Security-Policy
    * `limit` — tiles shown before "Show all" (default 11, so a row of four fills
      neatly with the new-board tile)
    * `open` — what opening a board does: `:overlay` (default) opens it over
      the page in the same viewer as the board page (the board page itself,
      framed), with a close button, and leaves the person where they were;
      `:navigate` goes to the board page; `:new_tab` opens it in a new tab
    * `return_to` — the page's own path, so an opened board can link back to it
    * `poll` — milliseconds between refreshes (default 5000; `0` for none)
    * `class` — extra classes for the wrapper

  ## Who sees what

  Private is the creator's alone and the module enforces that itself. Whether a
  user may look at a *place* at all is the host's call — see
  `PhoenixKitBoards.Access` and its `:authorize` hook. The widget renders
  nothing for a place the user may not view, and every action re-checks against
  the stored board, never the browser's say-so.

  ## Staying current

  Other people's changes appear on their own: the widget re-reads its list on a
  timer (`poll`). That needs nothing from the host. For *instant* updates a host
  can subscribe its LiveView to the place and forward the message:

      # in mount/3, when connected?
      PhoenixKitBoards.Boards.subscribe_scope({"project", project.uuid})

      def handle_info({:boards_scope_changed, _board_uuid}, socket) do
        PhoenixKitBoards.Web.BoardsPanel.refresh("project-notes")
        {:noreply, socket}
      end

  The widget does not subscribe the host's process itself: a host `handle_info`
  with no catch-all would crash on a message it did not expect.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBoards.{Access, Boards, Paths, Quick}

  @default_limit 11
  @show_all_limit 500
  @default_poll 5_000
  @all_actions [:empty, :text, :image]
  @image_accept ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp)
  @image_max_bytes 25_000_000
  @note_max 2_000
  @paste_notice_ms 8_000
  @max_paste_files 8

  # The paste behaviour is a few dozen lines of browser code. It travels with
  # the widget as a runtime hook (see `PhoenixKitBoards.Web.RuntimeHooks` for
  # the mechanism) rather than through the 40 KB board bundle, which a page of
  # tiles has no other use for.
  @paste_js Path.expand("../../../priv/static/assets/boards_panel_paste.js", __DIR__)
  @external_resource @paste_js
  @paste_hook File.read!(@paste_js)

  # "Export as PDF" from a tile: the board is drawn off screen for the export
  # and taken down again (see the script). Same delivery as the paste hook.
  @export_js Path.expand("../../../priv/static/assets/boards_panel_export.js", __DIR__)
  @external_resource @export_js
  @export_hook File.read!(@export_js)

  @doc """
  Re-read the widget with the given `id` now. Call from the host LiveView, e.g.
  when it hears `{:boards_scope_changed, _}` (see the moduledoc).
  """
  @spec refresh(String.t(), pid()) :: :ok
  def refresh(id, pid \\ self()),
    do: Phoenix.LiveView.send_update(pid, __MODULE__, id: id, refresh: true)

  # ── Lifecycle ──────────────────────────────────────────────────────────

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  # The notice clears itself — unless a newer board has replaced it.
  def update(%{clear_created: uuid}, socket) do
    case socket.assigns[:created] do
      %{id: ^uuid} -> {:ok, assign(socket, :created, nil)}
      _ -> {:ok, socket}
    end
  end

  # One chain of timers per widget: a tick clears the flag and re-arms, and a
  # host re-render in between finds it set and does not start a second chain.
  def update(%{tick: true}, socket) do
    {:ok, socket |> assign(:timer_armed?, false) |> load() |> arm_timer()}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign_config(assigns)
      |> init_once()
      |> load()
      |> arm_timer()

    {:ok, socket}
  end

  defp assign_config(socket, assigns) do
    user = assigns[:current_user]
    previous = {socket.assigns[:user_uuid], socket.assigns[:scope], socket.assigns[:scope_ok?]}
    user_uuid = user_uuid(user)
    {scope, scope_ok?} = scope_of(assigns[:scope])

    socket
    |> assign(:id, assigns.id)
    |> assign(:user, user)
    |> assign(:user_uuid, user_uuid)
    |> assign(:scope, scope)
    |> assign(:scope_ok?, scope_ok?)
    |> assign(:label, assigns[:label])
    |> assign(:show_label?, Map.get(assigns, :show_label, true))
    |> assign(:folder, assigns[:folder])
    |> assign(:actions, actions(assigns[:actions]))
    |> assign(:limit, assigns[:limit] || @default_limit)
    |> assign(:open, open_mode(assigns[:open]))
    |> assign(:return_to, Paths.local_path(assigns[:return_to]))
    |> assign(:poll, Map.get(assigns, :poll, @default_poll))
    |> assign(:class, assigns[:class])
    |> assign(:paste?, Map.get(assigns, :paste, true) != false)
    |> assign(:script_nonce, assigns[:script_nonce])
    |> assign(:visibility_options, visibility_options(assigns[:visibility_options]))
    |> assign(:default_visibility, default_visibility(assigns))
    |> assign(:admin?, admin?(user))
    |> reset_context(previous != {user_uuid, scope, scope_ok?})
    |> constrain_visibility()
  end

  # Access may change while the widget stays mounted, even for the same user
  # and place. Refresh it before listing and check it again before mutations.
  defp assign_access(socket) do
    scope = socket.assigns.scope
    user = socket.assigns.user
    valid? = socket.assigns.scope_ok?

    phoenix_scope = if valid?, do: scope_of_user(user)
    can_view? = valid? and Access.can_list?(user, scope, phoenix_scope)
    can_create? = can_view? and Access.can?(:create, user, scope, phoenix_scope)

    socket
    |> clear_capture(socket.assigns[:can_create?] == true and not can_create?)
    |> assign(:can_view?, can_view?)
    |> assign(:can_create?, can_create?)
  end

  defp reset_context(%{assigns: %{initialized?: true}} = socket, true) do
    socket
    |> clear_capture(true)
    |> assign(
      show_all?: false,
      renaming: nil,
      error: nil,
      created: nil,
      visibility: socket.assigns.default_visibility
    )
  end

  defp reset_context(socket, _changed), do: socket

  defp clear_capture(socket, true) do
    socket
    |> cancel_image_entries()
    |> assign(note: "", text_open?: false, paste_text: nil)
  end

  defp clear_capture(socket, false), do: socket

  defp constrain_visibility(socket) do
    if socket.assigns[:visibility] in socket.assigns.visibility_options,
      do: socket,
      else: assign(socket, :visibility, socket.assigns.default_visibility)
  end

  # A place the host named badly (no id, say) shows nothing at all — it must
  # not fall back to the boards that belong nowhere.
  defp scope_of(scope) do
    case Boards.normalize_scope(scope) do
      {:ok, normalized} -> {normalized, true}
      :error -> {nil, false}
    end
  end

  defp admin?(nil), do: false
  defp admin?(user), do: user |> scope_of_user() |> Access.admin?()

  # Built from the user at each check, not kept: a permission taken away must
  # show on the next refresh. Once per check, handed on to `Access`.
  defp scope_of_user(%PhoenixKit.Users.Auth.User{} = user), do: Scope.for_user(user)
  defp scope_of_user(_), do: nil

  defp user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil

  defp actions(nil), do: @all_actions

  defp actions(list) when is_list(list) do
    case Enum.filter(list, &(&1 in @all_actions)) do
      [] -> @all_actions
      valid -> Enum.uniq(valid)
    end
  end

  defp visibility_options(nil), do: ["private", "shared"]

  defp visibility_options(options) when is_list(options) do
    case options
         |> Enum.map(&to_string/1)
         |> Enum.filter(&(&1 in ["private", "shared"]))
         |> Enum.uniq() do
      [] -> ["private", "shared"]
      valid -> valid
    end
  end

  defp default_visibility(assigns) do
    options = visibility_options(assigns[:visibility_options])
    wanted = to_string(assigns[:default_visibility] || "shared")
    if wanted in options, do: wanted, else: hd(options)
  end

  # State the person builds up, kept across the host's re-renders.
  defp init_once(%{assigns: %{initialized?: true}} = socket), do: socket

  defp init_once(socket) do
    socket
    |> assign(:initialized?, true)
    |> assign(:show_all?, false)
    |> assign(:renaming, nil)
    |> assign(:error, nil)
    |> assign(:note, "")
    |> assign(:text_open?, false)
    |> assign(:created, nil)
    |> assign(:paste_text, nil)
    |> assign(:exporting, nil)
    |> assign(:viewing, nil)
    |> assign(:export_seq, 0)
    |> assign(:visibility, socket.assigns.default_visibility)
    |> assign(:boards, [])
    |> assign(:total, 0)
    |> allow_upload(:quick_image,
      accept: image_accept(),
      max_entries: @max_paste_files,
      max_file_size: @image_max_bytes,
      auto_upload: true,
      progress: &handle_image_progress/3
    )
  end

  # `allow_upload` raises on a filter the host's `:mime` cannot resolve. The
  # list is filtered, not trusted — same rule as the board page.
  defp image_accept do
    Enum.filter(@image_accept, fn
      "." <> ext -> MIME.has_type?(ext)
      type -> MIME.extensions(type) != []
    end)
  end

  defp load(socket), do: socket |> assign_access() |> load_boards()

  defp load_boards(%{assigns: %{can_view?: true, user_uuid: uuid}} = socket)
       when is_binary(uuid) do
    limit = if socket.assigns.show_all?, do: @show_all_limit, else: socket.assigns.limit

    socket
    |> assign(
      :boards,
      Boards.list_for_scope(socket.assigns.scope, uuid, limit: limit, include_data: false)
    )
    |> assign(:total, Boards.count_for_scope(socket.assigns.scope, uuid))
  end

  defp load_boards(socket), do: assign(socket, boards: [], total: 0)

  # Only once connected: the disconnected render has no process to deliver to.
  defp arm_timer(%{assigns: %{poll: ms}} = socket) when is_integer(ms) and ms > 0 do
    if connected?(socket) and socket.assigns[:timer_armed?] != true do
      Phoenix.LiveView.send_update_after(__MODULE__, [id: socket.assigns.id, tick: true], ms)
      assign(socket, :timer_armed?, true)
    else
      socket
    end
  end

  defp arm_timer(socket), do: socket

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  # The big +: an empty canvas, opened.
  def handle_event("create_empty", _params, socket) do
    case allow_create(socket) do
      :ok ->
        case Quick.create_empty(
               socket.assigns.scope,
               socket.assigns.user_uuid,
               create_opts(socket)
             ) do
          {:ok, board} -> {:noreply, after_create(socket, board)}
          {:error, _reason} -> {:noreply, fail(socket, "Could not create the board.")}
        end

      {:error, message} ->
        {:noreply, fail(socket, message)}
    end
  end

  def handle_event("text_open", _params, socket),
    do: {:noreply, assign(socket, :text_open?, true)}

  def handle_event("text_cancel", _params, socket),
    do: {:noreply, socket |> assign(:text_open?, false) |> assign(:note, "")}

  def handle_event("quick_note", %{"note" => text}, socket) do
    case allow_create(socket) do
      :ok ->
        case Quick.create_note(
               socket.assigns.scope,
               socket.assigns.user_uuid,
               text,
               create_opts(socket)
             ) do
          {:ok, _board} ->
            {:noreply,
             socket
             |> assign(:note, "")
             |> assign(:text_open?, false)
             |> assign(:error, nil)
             |> load()}

          {:error, :empty} ->
            {:noreply, fail(socket, "Write something first.")}

          {:error, _reason} ->
            {:noreply, fail(socket, "Could not save the note.")}
        end

      {:error, message} ->
        {:noreply, fail(socket, message)}
    end
  end

  # Text pasted into the widget: a note board of its own, kept on the page.
  def handle_event("paste_text", %{"text" => text}, socket) when is_binary(text) do
    with true <- socket.assigns.paste? and :text in socket.assigns.actions,
         :ok <- allow_create(socket) do
      case Quick.create_collection(
             socket.assigns.scope,
             socket.assigns.user_uuid,
             [],
             text,
             create_opts(socket)
           ) do
        {:ok, board} -> {:noreply, created(socket, board)}
        {:error, :empty} -> {:noreply, socket}
        {:error, _reason} -> {:noreply, fail(socket, "Could not save the note.")}
      end
    else
      {:error, message} -> {:noreply, fail(socket, message)}
      _ -> {:noreply, socket}
    end
  end

  # Said just before pasted images are uploaded: whatever text came with them
  # goes on the same board, and the finished upload is announced as a paste.
  def handle_event("paste_context", %{"text" => text}, socket) when is_binary(text) do
    if socket.assigns.paste? and :image in socket.assigns.actions and allow_create(socket) == :ok,
      do: {:noreply, assign(socket, :paste_text, String.slice(text, 0, @note_max))},
      else: {:noreply, socket}
  end

  def handle_event("undo_paste", %{"id" => id}, socket) do
    with %{id: ^id} <- socket.assigns.created,
         {:ok, board} <- visible_board(socket, id),
         :ok <- allow_manage(socket, board),
         {:ok, _} <- Boards.delete_board(board) do
      {:noreply, socket |> assign(:created, nil) |> load()}
    else
      _ -> {:noreply, socket |> assign(:created, nil) |> load()}
    end
  end

  def handle_event("dismiss_created", _params, socket),
    do: {:noreply, assign(socket, :created, nil)}

  def handle_event("note_changed", %{"note" => text}, socket),
    do: {:noreply, assign(socket, :note, String.slice(text, 0, @note_max))}

  def handle_event("set_visibility", %{"visibility" => visibility}, socket) do
    if visibility in socket.assigns.visibility_options,
      do: {:noreply, assign(socket, :visibility, visibility)},
      else: {:noreply, socket}
  end

  def handle_event("validate_image", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_image", %{"ref" => ref}, socket) do
    socket = cancel_upload(socket, :quick_image, ref)

    case active_image_entries(socket) do
      [] ->
        {:noreply, assign(socket, :paste_text, nil)}

      entries ->
        if Enum.all?(entries, & &1.done?), do: make_image_board(socket), else: {:noreply, socket}
    end
  end

  def handle_event("show_all", _params, socket),
    do: {:noreply, socket |> assign(:show_all?, true) |> load()}

  def handle_event("dismiss_error", _params, socket), do: {:noreply, assign(socket, :error, nil)}

  def handle_event("rename_start", %{"id" => id}, socket) do
    with {:ok, board} <- visible_board(socket, id), :ok <- allow_manage(socket, board) do
      {:noreply, assign(socket, :renaming, board.uuid)}
    else
      error -> {:noreply, refuse(socket, error)}
    end
  end

  def handle_event("rename_cancel", _params, socket),
    do: {:noreply, assign(socket, :renaming, nil)}

  def handle_event("rename_save", %{"board_id" => id, "name" => name}, socket) do
    with {:ok, board} <- visible_board(socket, id),
         :ok <- allow_manage(socket, board),
         name when name != "" <- String.trim(name),
         {:ok, _} <- Boards.rename_board(board, name) do
      {:noreply, socket |> assign(:renaming, nil) |> load()}
    else
      "" -> {:noreply, assign(socket, :renaming, nil)}
      {:error, %Ecto.Changeset{}} -> {:noreply, fail(socket, "That name will not do.")}
      error -> {:noreply, refuse(socket, error)}
    end
  end

  def handle_event("pin", %{"id" => id}, socket),
    do: act(socket, id, &Boards.pin(&1, socket.assigns.user_uuid))

  def handle_event("unpin", %{"id" => id}, socket),
    do: act(socket, id, &Boards.unpin(&1, socket.assigns.user_uuid))

  def handle_event("board_visibility", %{"id" => id, "to" => to}, socket) do
    if to in socket.assigns.visibility_options do
      act(socket, id, &Boards.set_visibility(&1, to, socket.assigns.user_uuid))
    else
      {:noreply, fail(socket, "That is not available here.")}
    end
  end

  def handle_event("archive", %{"id" => id}, socket),
    do: act(socket, id, &Boards.archive(&1, socket.assigns.user_uuid))

  def handle_event("delete", %{"id" => id}, socket) do
    with {:ok, board} <- visible_board(socket, id),
         :ok <- allow_manage(socket, board),
         {:ok, _} <- Boards.delete_board(board) do
      {:noreply, load(socket)}
    else
      {:error, %Ecto.Changeset{}} -> {:noreply, fail(socket, "Could not delete the board.")}
      error -> {:noreply, refuse(socket, error)}
    end
  end

  def handle_event("open_board", %{"id" => id}, socket) do
    case visible_board(socket, id) do
      {:ok, board} -> {:noreply, assign(socket, :viewing, viewing(board))}
      error -> {:noreply, refuse(socket, error)}
    end
  end

  # Closing re-reads the tiles: the board's preview and name may have changed
  # while it was open.
  def handle_event("close_board", _params, %{assigns: %{viewing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("close_board", _params, socket),
    do: {:noreply, socket |> assign(:viewing, nil) |> load()}

  # One at a time: a second click while a board is being drawn for its PDF
  # is ignored rather than starting another copy.
  def handle_event("export_pdf", %{"id" => _id}, %{assigns: %{exporting: %{}}} = socket),
    do: {:noreply, socket}

  def handle_event("export_pdf", %{"id" => id}, socket) do
    with {:ok, board} <- visible_board(socket, id),
         %{} = board <- Boards.get_board(board.uuid) do
      seq = socket.assigns.export_seq + 1

      {:noreply,
       socket
       |> assign(:export_seq, seq)
       |> assign(:error, nil)
       |> assign(:exporting, %{
         id: board.uuid,
         name: board.name,
         canvas: Boards.load_canvas(board),
         fresco_id: "#{socket.assigns.id}-export-#{seq}"
       })}
    else
      nil -> {:noreply, refuse(socket, {:error, :gone})}
      error -> {:noreply, refuse(socket, error)}
    end
  end

  def handle_event("export_done", params, socket) do
    socket = assign(socket, :exporting, nil)

    if params["ok"] == true,
      do: {:noreply, socket},
      else: {:noreply, fail(socket, "Could not export the board as a PDF.")}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Uploads finished: make ONE board of them. A picture chosen or dropped on its
  # own is a board with that picture; several at once, or a paste that came with
  # text, share a board. The work waits for the last file — each one reports
  # done separately.
  defp handle_image_progress(:quick_image, %{done?: true}, socket) do
    entries = active_image_entries(socket)

    if Enum.all?(entries, & &1.done?) do
      make_image_board(socket)
    else
      {:noreply, socket}
    end
  end

  defp handle_image_progress(:quick_image, _entry, socket), do: {:noreply, socket}

  defp active_image_entries(socket),
    do: Enum.reject(socket.assigns.uploads.quick_image.entries, & &1.cancelled?)

  defp make_image_board(socket) do
    pasted? = socket.assigns.paste_text != nil
    text = socket.assigns.paste_text
    socket = assign(socket, :paste_text, nil)

    case allow_create(socket) do
      :ok ->
        case save_image_collection(socket, text) do
          {:ok, board} when pasted? -> {:noreply, created(socket, board)}
          {:ok, _board} -> {:noreply, socket |> assign(:error, nil) |> load()}
          {:error, :empty} -> {:noreply, socket}
          {:error, reason} -> {:noreply, fail_image(socket, reason)}
        end

      {:error, message} ->
        # Dropped, not left behind: entries still on the upload would ride into
        # the next board made here, and while their refs are live the paste
        # hook waits for them — with no cancel button to clear them once the
        # new-board tile is gone, it would wait for good.
        {:noreply, socket |> clear_capture(true) |> load() |> fail(message)}
    end
  end

  defp cancel_image_entries(socket) do
    Enum.reduce(active_image_entries(socket), socket, fn entry, acc ->
      cancel_upload(acc, :quick_image, entry.ref)
    end)
  end

  defp save_image_collection(socket, text) do
    # Canceled channels may still be shutting down. Consume only the active,
    # completed entries, without waiting for those channels to disappear.
    copied =
      socket
      |> active_image_entries()
      |> Enum.map(fn entry ->
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, copy_image(path, entry)}
        end)
      end)

    files = for {path, entry} <- copied, is_binary(path), do: {path, entry}

    try do
      case Enum.find(copied, &match?({:error, _}, &1)) do
        nil ->
          Quick.create_collection(
            socket.assigns.scope,
            socket.assigns.user_uuid,
            files,
            text,
            create_opts(socket)
          )

        error ->
          error
      end
    after
      Enum.each(files, fn {copy, _entry} -> File.rm(copy) end)
    end
  end

  defp copy_image(path, entry) do
    copy = Path.join(System.tmp_dir!(), "boards-paste-#{System.unique_integer([:positive])}")

    case File.cp(path, copy) do
      :ok ->
        {copy, entry}

      {:error, reason} ->
        File.rm(copy)
        {:error, reason}
    end
  end

  # Storage's own reasons are for the log, not for the person.
  defp fail_image(socket, reason) do
    Logger.warning("[boards] quick image failed: #{inspect(reason)}")
    fail(socket, "Could not save the image.")
  end

  # A board that appeared from a paste: on the page, announced, undoable.
  defp created(socket, board) do
    Phoenix.LiveView.send_update_after(
      __MODULE__,
      [id: socket.assigns.id, clear_created: board.uuid],
      @paste_notice_ms
    )

    socket
    |> assign(:error, nil)
    |> assign(:created, %{id: board.uuid, name: board.name})
    |> load()
  end

  # ── Checks ─────────────────────────────────────────────────────────────

  defp allow_create(socket) do
    assigns = socket.assigns

    phoenix_scope = if assigns.scope_ok?, do: scope_of_user(assigns.user)

    if assigns.scope_ok? and Access.can_list?(assigns.user, assigns.scope, phoenix_scope) and
         Access.can?(:create, assigns.user, assigns.scope, phoenix_scope),
       do: :ok,
       else: {:error, "You cannot add boards here."}
  end

  # The creator, or an admin. Sharing and archiving are narrower (the creator
  # only) and enforced by the context, which does not know about admins.
  defp allow_manage(socket, board) do
    if board.created_by == socket.assigns.user_uuid or admin?(socket.assigns.user),
      do: :ok,
      else: {:error, :forbidden}
  end

  # The board the browser named, only if it is in THIS widget's place and the
  # user may see it. An id from anywhere else is as good as none.
  defp visible_board(%{assigns: assigns}, id) do
    phoenix_scope = if assigns.scope_ok?, do: scope_of_user(assigns.user)

    with true <-
           assigns.scope_ok? and Access.can_list?(assigns.user, assigns.scope, phoenix_scope),
         board when not is_nil(board) <- Boards.get_board(id, include_data: false) do
      if Boards.scope_of(board) == assigns.scope and
           Boards.visible_to?(board, assigns.user_uuid),
         do: {:ok, board},
         else: {:error, :gone}
    else
      _ -> {:error, :gone}
    end
  end

  defp act(socket, id, fun) do
    with {:ok, board} <- visible_board(socket, id),
         {:ok, _} <- fun.(board) do
      {:noreply, load(socket)}
    else
      {:error, %Ecto.Changeset{}} -> {:noreply, fail(socket, "That did not work.")}
      error -> {:noreply, refuse(socket, error)}
    end
  end

  defp refuse(socket, {:error, :forbidden}),
    do: socket |> fail("Only the board's creator can do that.") |> load()

  defp refuse(socket, _gone), do: socket |> fail("That board is no longer available.") |> load()

  defp fail(socket, message), do: assign(socket, :error, message)

  defp after_create(socket, board) do
    socket = socket |> assign(:error, nil) |> load()

    case socket.assigns.open do
      :navigate -> redirect(socket, to: Paths.user_board(board.uuid, socket.assigns.return_to))
      :overlay -> assign(socket, :viewing, viewing(board))
      _ -> socket
    end
  end

  defp open_mode(mode) when mode in [:navigate, :new_tab, :overlay], do: mode
  defp open_mode(_), do: :overlay

  defp viewing(board),
    do: %{id: board.uuid, name: board.name, src: Paths.embedded_board(board.uuid)}

  defp create_opts(socket) do
    [
      visibility: socket.assigns.visibility,
      folder: socket.assigns.folder,
      label: socket.assigns.label
    ]
  end

  # ── Render ─────────────────────────────────────────────────────────────

  @impl true
  def render(%{user: nil} = assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60",
        @class
      ]}
    >
      Sign in to see boards here.
    </div>
    """
  end

  def render(%{can_view?: false} = assigns) do
    ~H"""
    <div id={@id} class="hidden" aria-hidden="true"></div>
    """
  end

  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class={["group/panel space-y-3 outline-none", @class]}
      data-boards-panel
      phx-hook={if @paste?, do: "BoardsPanelPaste"}
      tabindex={if @paste? and @can_create?, do: "-1"}
      data-paste={if @paste? and @can_create?, do: "on", else: "off"}
      data-paste-images={if :image in @actions, do: "on", else: "off"}
      data-paste-text={if :text in @actions, do: "on", else: "off"}
      data-paste-context={inspect({@user_uuid, @scope, @scope_ok?})}
    >
      <script :if={@paste?} data-phx-runtime-hook="BoardsPanelPaste" nonce={@script_nonce}>
        <%= Phoenix.HTML.raw("window.phx_hook_BoardsPanelPaste = function () { return " <> paste_hook() <> "; };") %>
      </script>

      <%!-- The one upload input for the panel, kept apart from the tile so a
            paste can reach it whatever the tile is showing (the note form
            replaces it). The tile's camera button is a label for this. --%>
      <form
        :if={@can_create? and :image in @actions}
        id={"#{@id}-image"}
        phx-change="validate_image"
        phx-target={@myself}
        class="hidden"
      >
        <.live_file_input upload={@uploads.quick_image} />
      </form>

      <h3 :if={@label && @show_label?} class="text-sm font-medium text-base-content/70">
        {@label}
        <span :if={@total > 0} class="ml-1 text-xs font-normal text-base-content/50">{@total}</span>
      </h3>

      <div :if={@created} role="status" class="alert py-2 text-sm">
        <span>Board created: {@created.name}</span>
        <span class="flex items-center gap-1">
          <button
            type="button"
            phx-click="undo_paste"
            phx-value-id={@created.id}
            phx-target={@myself}
            class="btn btn-ghost btn-xs"
          >
            Undo
          </button>
          <button
            type="button"
            phx-click="dismiss_created"
            phx-target={@myself}
            class="btn btn-ghost btn-xs btn-circle"
            aria-label="Dismiss"
          >
            <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
          </button>
        </span>
      </div>

      <%!-- The open board, over the page: the board page itself in its embedded
            form (`?embed=1`), framed — the same viewer, live collaboration,
            uploads and export, under the same access rules as opening it on
            its own. Escape or the ✕ closes it. --%>
      <div
        :if={@viewing}
        id={"#{@id}-viewer"}
        class="fixed inset-0 z-[60] flex flex-col bg-black/60 backdrop-blur-sm sm:p-4"
        role="dialog"
        aria-modal="true"
        aria-label={@viewing.name}
        phx-window-keydown="close_board"
        phx-key="Escape"
        phx-target={@myself}
      >
        <div class="flex min-h-0 flex-1 flex-col overflow-hidden bg-base-100 shadow-2xl sm:rounded-xl">
          <div class="flex shrink-0 items-center gap-2 border-b border-base-300 px-3 py-2">
            <.icon name="hero-rectangle-group" class="h-4 w-4 shrink-0 text-base-content/50" />
            <span class="min-w-0 flex-1 truncate text-sm font-medium">{@viewing.name}</span>
            <a
              href={Paths.user_board(@viewing.id, @return_to)}
              target="_blank"
              rel="noopener"
              class="btn btn-ghost btn-xs btn-circle"
              aria-label="Open in a new tab"
              title="Open in a new tab"
            >
              <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" />
            </a>
            <button
              type="button"
              phx-click="close_board"
              phx-target={@myself}
              class="btn btn-ghost btn-sm btn-circle"
              aria-label="Close"
              title="Close (Esc)"
            >
              <.icon name="hero-x-mark" class="h-5 w-5" />
            </button>
          </div>
          <iframe
            id={"#{@id}-viewer-#{@viewing.id}"}
            src={@viewing.src}
            title={@viewing.name}
            class="min-h-0 w-full flex-1 border-0"
            allow="fullscreen; clipboard-read; clipboard-write"
            allowfullscreen
          ></iframe>
        </div>
      </div>

      <%!-- The board being exported, drawn off screen with the same canvas and
            layer as the board page (see `boards_panel_export.js`). Not
            `visibility: hidden`: the export reads each shape's computed
            style, and hidden would be what it read. --%>
      <script :if={@exporting} data-phx-runtime-hook="BoardsPanelExport" nonce={@script_nonce}>
        <%= Phoenix.HTML.raw("window.phx_hook_BoardsPanelExport = function () { return " <> export_hook() <> "; };") %>
      </script>
      <div
        :if={@exporting}
        id={"#{@exporting.fresco_id}-host"}
        phx-hook="BoardsPanelExport"
        phx-update="ignore"
        data-fresco-id={@exporting.fresco_id}
        data-filename={@exporting.name}
        aria-hidden="true"
        inert
        style="position: fixed; left: -20000px; top: 0; width: 1600px; height: 1000px; pointer-events: none; overflow: hidden;"
      >
        <Fresco.canvas
          id={@exporting.fresco_id}
          canvas={@exporting.canvas}
          infinite_canvas
          nav_buttons={[]}
          class="w-full h-full"
        />
        <Etcher.layer fresco_id={@exporting.fresco_id} nav_buttons={[]} />
      </div>
      <div :if={@exporting} role="status" class="flex items-center gap-2 text-sm text-base-content/70">
        <span class="loading loading-spinner loading-xs"></span>
        Exporting “{@exporting.name}” as a PDF…
      </div>

      <div :if={@error} role="alert" class="alert alert-error py-2 text-sm">
        <span>{@error}</span>
        <button
          type="button"
          phx-click="dismiss_error"
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
        >
          Dismiss
        </button>
      </div>

      <%!-- Nothing yet: the new-board tile alone, centred and larger. --%>
      <div :if={@boards == [] and @can_create?} class="mx-auto w-full max-w-xs">
        <.new_tile {assigns} big={true} />
      </div>

      <p
        :if={@boards == [] and not @can_create?}
        class="rounded-lg border border-dashed border-base-300 p-6 text-center text-sm text-base-content/60"
      >
        No boards here yet.
      </p>

      <ul
        :if={@boards != []}
        class="grid grid-cols-[repeat(auto-fill,minmax(8.5rem,1fr))] gap-3"
      >
        <.board_tile :for={board <- @boards} {assigns} board={board} />
        <li :if={@can_create?} class="contents">
          <.new_tile {assigns} big={false} />
        </li>
      </ul>

      <button
        :if={@total > length(@boards) and not @show_all?}
        type="button"
        phx-click="show_all"
        phx-target={@myself}
        class="btn btn-ghost btn-xs"
      >
        Show all {@total}
      </button>
    </section>
    """
  end

  defp paste_hook, do: @paste_hook
  defp export_hook, do: @export_hook

  # ── The new-board tile ─────────────────────────────────────────────────

  defp new_tile(%{text_open?: true} = assigns) do
    ~H"""
    <form
      id={"#{@id}-note"}
      phx-change="note_changed"
      phx-submit="quick_note"
      phx-target={@myself}
      class="flex aspect-square flex-col gap-2 rounded-xl border border-primary/40 bg-base-100 p-2"
    >
      <textarea
        name="note"
        maxlength="2000"
        placeholder="Jot a note…"
        autofocus
        class="textarea textarea-ghost min-h-0 w-full flex-1 resize-none p-1 text-sm leading-snug focus:border-transparent focus:outline-none"
      >{@note}</textarea>
      <div class="flex items-center justify-end gap-1">
        <button
          type="button"
          phx-click="text_cancel"
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
        >
          Cancel
        </button>
        <button type="submit" class="btn btn-primary btn-xs">Save</button>
      </div>
    </form>
    """
  end

  defp new_tile(assigns) do
    ~H"""
    <div
      id={"#{@id}-new"}
      phx-drop-target={if :image in @actions, do: @uploads.quick_image.ref}
      class="flex aspect-square flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed border-base-300 p-3 text-base-content/60 transition-colors hover:border-primary/50 group-focus-within/panel:border-primary/50"
    >
      <button
        :if={:empty in @actions}
        type="button"
        phx-click="create_empty"
        phx-target={@myself}
        aria-label="New empty board"
        class={[
          "btn btn-circle btn-primary shadow-sm",
          if(@big, do: "h-20 w-20", else: "h-12 w-12")
        ]}
      >
        <.icon name="hero-plus" class={if(@big, do: "h-10 w-10", else: "h-6 w-6")} />
      </button>

      <div
        :if={length(@actions -- [:empty]) > 0}
        class="flex flex-wrap items-center justify-center gap-1.5"
      >
        <button
          :if={:text in @actions}
          type="button"
          phx-click="text_open"
          phx-target={@myself}
          title="Start with a note"
          aria-label="Start with a note"
          class={["btn btn-sm btn-outline", if(@big, do: "gap-1", else: "btn-circle")]}
        >
          <.icon name="hero-pencil-square" class="h-4 w-4" />
          <span :if={@big}>Text</span>
        </button>

        <label
          :if={:image in @actions}
          for={@uploads.quick_image.ref}
          title="Start with an image"
          aria-label="Start with an image"
          class={[
            "btn btn-sm btn-outline cursor-pointer",
            if(@big, do: "gap-1", else: "btn-circle")
          ]}
        >
          <.icon name="hero-camera" class="h-4 w-4" />
          <span :if={@big}>Image</span>
        </label>
      </div>

      <form
        :if={length(@visibility_options) > 1}
        id={"#{@id}-visibility"}
        phx-change="set_visibility"
        phx-target={@myself}
      >
        <select
          name="visibility"
          aria-label="Who can see the board"
          class="select select-ghost select-xs h-6 min-h-0 text-xs text-base-content/60"
        >
          <option :for={o <- @visibility_options} value={o} selected={o == @visibility}>
            {visibility_label(o)}
          </option>
        </select>
      </form>

      <%!-- Only while the widget has focus, which is when a paste is heard. --%>
      <p
        :if={@paste?}
        class="hidden text-center text-xs leading-tight text-primary group-focus-within/panel:block"
      >
        Paste text or an image
      </p>

      <div :for={entry <- @uploads.quick_image.entries} class="flex w-full items-center gap-1 text-xs">
        <progress class="progress progress-primary flex-1" value={entry.progress} max="100"></progress>
        <span :for={err <- upload_errors(@uploads.quick_image, entry)} class="text-error">
          {upload_error_text(err)}
        </span>
        <button
          type="button"
          phx-click="cancel_image"
          phx-value-ref={entry.ref}
          phx-target={@myself}
          class="btn btn-ghost btn-xs btn-circle"
          aria-label="Cancel upload"
        >
          <.icon name="hero-x-mark" class="h-3.5 w-3.5" />
        </button>
      </div>
      <p :for={err <- upload_errors(@uploads.quick_image)} class="text-xs text-error">
        {upload_error_text(err)}
      </p>
    </div>
    """
  end

  # ── A board's tile ─────────────────────────────────────────────────────

  defp board_tile(assigns) do
    assigns =
      assigns
      |> assign(:creator?, assigns.board.created_by == assigns.user_uuid)
      |> assign(:manage?, assigns.board.created_by == assigns.user_uuid or assigns.admin?)
      |> assign(:href, Paths.user_board(assigns.board.uuid, assigns.return_to))
      |> assign(:blank?, blank_preview?(assigns.board.preview))

    ~H"""
    <li
      id={"#{@id}-#{@board.uuid}"}
      class="group relative flex aspect-square flex-col rounded-xl border border-base-300 bg-base-100 shadow-sm transition-shadow focus-within:z-30 hover:shadow-md"
    >
      <.tile_link
        open={@open}
        href={@href}
        board={@board}
        myself={@myself}
        class="relative block min-h-0 w-full flex-1 overflow-hidden rounded-t-[inherit] bg-base-200 text-left"
        tabindex="-1"
        aria-hidden="true"
      >
        <img
          :if={@board.preview && @board.preview["image_url"]}
          src={@board.preview["image_url"]}
          loading="lazy"
          alt=""
          class="h-full w-full object-cover"
        />
        <p
          :if={@board.preview && !@board.preview["image_url"] && @board.preview["text"]}
          class="line-clamp-4 whitespace-pre-line p-3 text-sm leading-snug text-base-content/75"
        >
          {@board.preview["text"]}
        </p>
        <%!-- A soft edge where a long note is cut off, rather than half a line. --%>
        <div
          :if={@board.preview && !@board.preview["image_url"] && @board.preview["text"]}
          class="pointer-events-none absolute inset-x-0 bottom-0 h-8 bg-gradient-to-t from-base-200 to-transparent"
        >
        </div>
        <div :if={@blank?} class="flex h-full items-center justify-center text-base-content/25">
          <.icon name="hero-rectangle-group" class="h-9 w-9" />
        </div>
      </.tile_link>

      <div class="flex min-h-9 items-center gap-1 px-2 py-1.5">
        <.tile_title {assigns} />
      </div>

      <.tile_menu {assigns} />
    </li>
    """
  end

  defp tile_title(%{renaming: renaming, board: %{uuid: renaming}} = assigns) do
    ~H"""
    <form phx-submit="rename_save" phx-target={@myself} class="flex w-full items-center gap-1">
      <input type="hidden" name="board_id" value={@board.uuid} />
      <input
        type="text"
        name="name"
        value={@board.name}
        maxlength="200"
        autofocus
        phx-key="Escape"
        phx-keydown="rename_cancel"
        phx-target={@myself}
        class="input input-xs min-w-0 flex-1"
      />
      <button type="submit" class="btn btn-primary btn-xs px-2" aria-label="Save name">
        <.icon name="hero-check" class="h-3.5 w-3.5" />
      </button>
    </form>
    """
  end

  defp tile_title(assigns) do
    ~H"""
    <.icon
      :if={@board.pinned_at}
      name="hero-bookmark-solid"
      class="h-3.5 w-3.5 shrink-0 text-warning"
    />
    <.icon
      :if={@board.visibility == "private"}
      name="hero-lock-closed"
      class="h-3.5 w-3.5 shrink-0 text-base-content/50"
    />
    <.tile_link
      open={@open}
      href={@href}
      board={@board}
      myself={@myself}
      class="min-w-0 flex-1 truncate text-left text-sm font-medium hover:underline"
      title={@board.name}
    >
      {@board.name}
    </.tile_link>
    """
  end

  # A tile's way into its board: a button that opens the overlay, or a link to
  # the board page (here or in a new tab).
  attr(:open, :atom, required: true)
  attr(:href, :string, required: true)
  attr(:board, :map, required: true)
  attr(:myself, :any, required: true)
  attr(:class, :string, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  defp tile_link(%{open: :overlay} = assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_board"
      phx-value-id={@board.uuid}
      phx-target={@myself}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp tile_link(assigns) do
    ~H"""
    <a
      href={@href}
      target={if @open == :new_tab, do: "_blank"}
      rel={if @open == :new_tab, do: "noopener"}
      class={@class}
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  defp tile_menu(assigns) do
    ~H"""
    <%!-- The menu is positioned against the tile (this wrapper is `static`), not
          the corner button: it spans the tile's width, so on a phone, where a
          tile is barely wider than the button, it cannot run off the screen.
          The tile does not clip (`overflow-hidden` would cut the menu off at
          its edge) and rises above its neighbours while the menu is open. --%>
    <div class="dropdown dropdown-end !static">
      <button
        type="button"
        tabindex="0"
        class="btn btn-circle btn-xs absolute right-1 top-1 z-10 border-0 bg-base-100/80 opacity-70 shadow-sm backdrop-blur group-hover:opacity-100 focus:opacity-100"
        aria-label={"Actions for #{@board.name}"}
      >
        <.icon name="hero-ellipsis-horizontal" class="h-4 w-4" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-sm absolute inset-x-1 top-9 z-30 w-auto rounded-box border border-base-300 bg-base-100 p-1 shadow"
      >
        <li :if={@manage?}>
          <button
            type="button"
            phx-click="rename_start"
            phx-value-id={@board.uuid}
            phx-target={@myself}
          >
            <.icon name="hero-pencil" class="h-4 w-4" /> Rename
          </button>
        </li>
        <li>
          <button
            :if={is_nil(@board.pinned_at)}
            type="button"
            phx-click="pin"
            phx-value-id={@board.uuid}
            phx-target={@myself}
          >
            <.icon name="hero-bookmark" class="h-4 w-4" /> Pin to front
          </button>
          <button
            :if={@board.pinned_at}
            type="button"
            phx-click="unpin"
            phx-value-id={@board.uuid}
            phx-target={@myself}
          >
            <.icon name="hero-bookmark-slash" class="h-4 w-4" /> Unpin
          </button>
        </li>
        <li :if={@creator? and length(@visibility_options) == 2 and @board.visibility == "shared"}>
          <button
            type="button"
            phx-click="board_visibility"
            phx-value-id={@board.uuid}
            phx-value-to="private"
            phx-target={@myself}
          >
            <.icon name="hero-lock-closed" class="h-4 w-4" /> Make private
          </button>
        </li>
        <li :if={@creator? and length(@visibility_options) == 2 and @board.visibility == "private"}>
          <button
            type="button"
            phx-click="board_visibility"
            phx-value-id={@board.uuid}
            phx-value-to="shared"
            phx-target={@myself}
          >
            <.icon name="hero-user-group" class="h-4 w-4" /> Share with everyone here
          </button>
        </li>
        <li>
          <button
            type="button"
            phx-click="export_pdf"
            phx-value-id={@board.uuid}
            phx-target={@myself}
            disabled={not is_nil(@exporting)}
          >
            <.icon name="hero-document-arrow-down" class="h-4 w-4" /> Export as PDF
          </button>
        </li>
        <li :if={@creator?}>
          <button type="button" phx-click="archive" phx-value-id={@board.uuid} phx-target={@myself}>
            <.icon name="hero-archive-box" class="h-4 w-4" /> Archive
          </button>
        </li>
        <li :if={@manage?}>
          <button
            type="button"
            phx-click="delete"
            phx-value-id={@board.uuid}
            phx-target={@myself}
            data-confirm="Delete this board? Its files move to the media trash."
            class="text-error"
          >
            <.icon name="hero-trash" class="h-4 w-4" /> Delete
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp blank_preview?(nil), do: true
  defp blank_preview?(preview), do: !preview["image_url"] and !preview["text"]

  defp visibility_label("private"), do: "Only me"
  defp visibility_label("shared"), do: "Everyone here"

  defp upload_error_text(:too_large), do: "That file is too large."
  defp upload_error_text(:not_accepted), do: "Only images can be added here."
  defp upload_error_text(:too_many_files), do: "Up to #{@max_paste_files} images at a time."
  defp upload_error_text(_), do: "That upload failed."
end
