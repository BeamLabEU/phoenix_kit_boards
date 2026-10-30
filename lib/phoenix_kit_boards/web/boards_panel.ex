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

  The widget does not manage places or projects — *you* decide what place it
  is for, by `scope`, and put one wherever you want one.

  ## Attributes

    * `id` — required, unique on the page
    * `current_user` — required; with none the widget only asks to sign in
    * `scope` — `{type, id}` naming the place; each a string, integer or atom
      (`{"project", uuid}`, `{"order", 1001}`, `{"page", "/docs/setup"}`), kept as
      strings, which is what the `:authorize` hook is given. `nil` is the boards
      that belong nowhere; a place with a missing id shows nothing at all
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
    * `limit` — tiles shown before "Show all" (default 11, so a row of four fills
      neatly with the new-board tile)
    * `open` — `:navigate` (default) or `:new_tab`: what opening a board does
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
    |> assign(:open, assigns[:open] || :navigate)
    |> assign(:return_to, Paths.local_path(assigns[:return_to]))
    |> assign(:poll, Map.get(assigns, :poll, @default_poll))
    |> assign(:class, assigns[:class])
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

    socket
    |> assign(:can_view?, valid? and Access.can?(:view, user, scope))
    |> assign(:can_create?, valid? and Access.can?(:create, user, scope))
  end

  defp reset_context(%{assigns: %{initialized?: true}} = socket, true) do
    socket =
      Enum.reduce(socket.assigns.uploads.quick_image.entries, socket, fn entry, acc ->
        cancel_upload(acc, :quick_image, entry.ref)
      end)

    assign(socket,
      show_all?: false,
      renaming: nil,
      error: nil,
      note: "",
      text_open?: false,
      visibility: socket.assigns.default_visibility
    )
  end

  defp reset_context(socket, _changed), do: socket

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
  defp admin?(user), do: user |> Scope.for_user() |> Access.admin?()

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
    |> assign(:visibility, socket.assigns.default_visibility)
    |> assign(:boards, [])
    |> assign(:total, 0)
    |> allow_upload(:quick_image,
      accept: image_accept(),
      max_entries: 1,
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

  def handle_event("note_changed", %{"note" => text}, socket),
    do: {:noreply, assign(socket, :note, String.slice(text, 0, @note_max))}

  def handle_event("set_visibility", %{"visibility" => visibility}, socket) do
    if visibility in socket.assigns.visibility_options,
      do: {:noreply, assign(socket, :visibility, visibility)},
      else: {:noreply, socket}
  end

  def handle_event("validate_image", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :quick_image, ref)}

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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # An upload finished: make the board. Heavy work in a progress callback, as on
  # the board page — a photo is small and the person is waiting.
  defp handle_image_progress(:quick_image, %{done?: true} = entry, socket) do
    case allow_create(socket) do
      :ok ->
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok,
             Quick.create_image(
               socket.assigns.scope,
               socket.assigns.user_uuid,
               path,
               entry,
               create_opts(socket)
             )}
          end)

        case result do
          {:ok, _board} ->
            {:noreply, socket |> assign(:error, nil) |> load()}

          {:error, reason} ->
            # Storage's own reasons are for the log, not for the person.
            Logger.warning("[boards] quick image failed: #{inspect(reason)}")
            {:noreply, fail(socket, "Could not save the image.")}
        end

      {:error, message} ->
        # Not consumed: the entry is dropped with the upload.
        {:noreply, fail(socket, message)}
    end
  end

  defp handle_image_progress(:quick_image, _entry, socket), do: {:noreply, socket}

  # ── Checks ─────────────────────────────────────────────────────────────

  defp allow_create(socket) do
    assigns = socket.assigns

    if assigns.scope_ok? and Access.can?(:view, assigns.user, assigns.scope) and
         Access.can?(:create, assigns.user, assigns.scope),
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
    with true <- assigns.scope_ok? and Access.can?(:view, assigns.user, assigns.scope),
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

    if socket.assigns.open == :navigate,
      do: redirect(socket, to: Paths.user_board(board.uuid, socket.assigns.return_to)),
      else: socket
  end

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
    <section id={@id} class={["space-y-3", @class]} data-boards-panel>
      <h3 :if={@label && @show_label?} class="text-sm font-medium text-base-content/70">
        {@label}
        <span :if={@total > 0} class="ml-1 text-xs font-normal text-base-content/50">{@total}</span>
      </h3>

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
      class="flex aspect-square flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed border-base-300 p-3 text-base-content/60 transition-colors hover:border-primary/50"
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

        <form
          :if={:image in @actions}
          id={"#{@id}-image"}
          phx-change="validate_image"
          phx-target={@myself}
        >
          <label
            title="Start with an image"
            aria-label="Start with an image"
            class={[
              "btn btn-sm btn-outline cursor-pointer",
              if(@big, do: "gap-1", else: "btn-circle")
            ]}
          >
            <.icon name="hero-camera" class="h-4 w-4" />
            <span :if={@big}>Image</span>
            <.live_file_input upload={@uploads.quick_image} class="hidden" />
          </label>
        </form>
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

      <div :for={entry <- @uploads.quick_image.entries} class="flex w-full items-center gap-1 text-xs">
        <progress class="progress progress-primary flex-1" value={entry.progress} max="100"></progress>
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
      class="group relative flex aspect-square flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-sm transition-shadow hover:shadow-md"
    >
      <a
        href={@href}
        target={if @open == :new_tab, do: "_blank"}
        rel={if @open == :new_tab, do: "noopener"}
        class="relative min-h-0 flex-1 overflow-hidden bg-base-200"
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
      </a>

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
    <a
      href={@href}
      target={if @open == :new_tab, do: "_blank"}
      rel={if @open == :new_tab, do: "noopener"}
      class="min-w-0 flex-1 truncate text-sm font-medium hover:underline"
      title={@board.name}
    >
      {@board.name}
    </a>
    """
  end

  defp tile_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end absolute right-1 top-1 z-10">
      <button
        type="button"
        tabindex="0"
        class="btn btn-circle btn-xs border-0 bg-base-100/80 opacity-70 shadow-sm backdrop-blur group-hover:opacity-100 focus:opacity-100"
        aria-label={"Actions for #{@board.name}"}
      >
        <.icon name="hero-ellipsis-horizontal" class="h-4 w-4" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-sm z-20 w-48 rounded-box border border-base-300 bg-base-100 p-1 shadow"
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
  defp upload_error_text(:too_many_files), do: "One image at a time."
  defp upload_error_text(_), do: "That upload failed."
end
