defmodule PhoenixKitBoards.Web.BoardsPanel do
  @moduledoc """
  A list of the boards that belong to one place, to drop into any page.

      <PhoenixKitBoards.Web.Components.boards_panel
        id="project-boards"
        scope={{"project", @project.uuid}}
        label={@project.name}
        current_user={@current_scope.user}
        return_to={~p"/projects/\#{@project}"}
      />

  (or `<.live_component module={PhoenixKitBoards.Web.BoardsPanel} id=… … />`
  — they are the same thing.)

  It shows the boards of `scope` that the signed-in user may see — everyone's
  shared ones and their own private ones — with a **New board** button and, by
  default, a **quick capture** box: type a note or drop an image and it becomes
  a board in one step, without opening the editor. Each row can be renamed,
  pinned, made private or shared again, archived or deleted.

  ## Attributes

    * `id` — required, unique on the page
    * `current_user` — required; with none the panel only asks to sign in
    * `scope` — `{type, id}` naming the place (`{"project", uuid}`,
      `{"page", "/docs/setup"}`); `nil` for the boards that belong nowhere
    * `label` — the place's human name: the heading, and what the place's media
      folder is called
    * `folder` — where the boards' files go, see `PhoenixKitBoards.MediaFolders`
      (`{:under, uuid}`, `{:path, ["Clients", "Acme"]}`, `:root`, or a function);
      omit it for the host's hook or the default `Boards / <place>` layout
    * `visibility_options` — which of `[:private, :shared]` a person may choose
      (default both; `[:private]` makes a personal-notes panel)
    * `default_visibility` — `:shared` or `:private`
    * `layout` — `:list` (default), `:grid` or `:compact`
    * `limit` — how many boards to show before "Show all" (default 20)
    * `quick_capture` — show the note / image box (default `true`)
    * `open` — `:navigate` (default) or `:new_tab`
    * `return_to` — the page's own path, so an opened board can link back to it
    * `poll` — milliseconds between refreshes (default 5000; `0` for none)
    * `class` — extra classes for the wrapper

  ## Who sees what

  Private is the creator's alone and the module enforces that itself. Whether a
  user may look at a *place* at all is the host's call — see
  `PhoenixKitBoards.Access` and its `:authorize` hook. The panel renders
  nothing for a place the user may not view, and every action re-checks
  against the stored board, never the browser's say-so.

  ## Staying current

  Other people's changes appear on their own: the panel re-reads its list on a
  timer (`poll`). That needs nothing from the host. For *instant* updates a host
  can subscribe its LiveView to the place and forward the message:

      # in mount/3, when connected?
      PhoenixKitBoards.Boards.subscribe_scope({"project", project.uuid})

      def handle_info({:boards_scope_changed, _board_uuid}, socket) do
        PhoenixKitBoards.Web.BoardsPanel.refresh("project-boards")
        {:noreply, socket}
      end

  The panel does not subscribe the host's process itself: a host `handle_info`
  with no catch-all would crash on a message it did not expect.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBoards.{Access, Boards, Paths, Quick}

  @default_limit 20
  @show_all_limit 500
  @default_poll 5_000
  @image_accept ~w(.png .jpg .jpeg .gif .webp image/png image/jpeg image/gif image/webp)
  @image_max_bytes 25_000_000
  @note_max 2_000

  @doc """
  Re-read the panel with the given `id` now. Call from the host LiveView, e.g.
  when it hears `{:boards_scope_changed, _}` (see the moduledoc).
  """
  @spec refresh(String.t(), pid()) :: :ok
  def refresh(id, pid \\ self()),
    do: Phoenix.LiveView.send_update(pid, __MODULE__, id: id, refresh: true)

  # ── Lifecycle ──────────────────────────────────────────────────────────

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  # One chain of timers per panel: a tick clears the flag and re-arms, and a
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
    previous = socket.assigns[:user_uuid]
    user_uuid = user_uuid(user)

    socket
    |> assign(:id, assigns.id)
    |> assign(:user, user)
    |> assign(:user_uuid, user_uuid)
    |> assign(:scope, assigns[:scope])
    |> assign(:label, assigns[:label])
    |> assign(:folder, assigns[:folder])
    |> assign(:layout, assigns[:layout] || :list)
    |> assign(:limit, assigns[:limit] || @default_limit)
    |> assign(:quick_capture, Map.get(assigns, :quick_capture, true))
    |> assign(:open, assigns[:open] || :navigate)
    |> assign(:return_to, Paths.local_path(assigns[:return_to]))
    |> assign(:poll, Map.get(assigns, :poll, @default_poll))
    |> assign(:class, assigns[:class])
    |> assign(:visibility_options, visibility_options(assigns[:visibility_options]))
    |> assign(:default_visibility, default_visibility(assigns))
    |> assign_access(user, previous != user_uuid)
  end

  # What the host allows and whether this user is an admin is looked up once per
  # user, not on every refresh: the second reads roles and permissions.
  defp assign_access(socket, user, true = _changed) do
    scope = socket.assigns.scope

    socket
    |> assign(:can_view?, Access.can?(:view, user, scope))
    |> assign(:can_create?, Access.can?(:create, user, scope))
    |> assign(:admin?, admin?(user))
  end

  defp assign_access(socket, _user, false), do: socket

  defp admin?(nil), do: false
  defp admin?(user), do: user |> Scope.for_user() |> Access.admin?()

  defp user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil

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
    |> assign(:search, "")
    |> assign(:show_all?, false)
    |> assign(:renaming, nil)
    |> assign(:error, nil)
    |> assign(:note, "")
    |> assign(:new_open?, false)
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

  defp load(%{assigns: %{can_view?: true, user_uuid: uuid}} = socket) when is_binary(uuid) do
    limit = if socket.assigns.show_all?, do: @show_all_limit, else: socket.assigns.limit
    opts = [limit: limit, search: socket.assigns.search]

    socket
    |> assign(:boards, Boards.list_for_scope(socket.assigns.scope, uuid, opts))
    |> assign(
      :total,
      Boards.count_for_scope(socket.assigns.scope, uuid, search: socket.assigns.search)
    )
  end

  defp load(socket), do: assign(socket, boards: [], total: 0)

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
  def handle_event("create", %{"name" => name} = params, socket) do
    with :ok <- allow_create(socket) do
      attrs = %{
        "name" => blank_to(name, "Untitled board"),
        "created_by" => socket.assigns.user_uuid,
        "visibility" => visibility_param(params, socket)
      }

      case Boards.create_board(with_scope(attrs, socket.assigns.scope), folder_opts(socket)) do
        {:ok, board} ->
          {:noreply, after_create(socket, board)}

        {:error, _changeset} ->
          {:noreply, fail(socket, "Could not create the board.")}
      end
    else
      {:error, message} -> {:noreply, fail(socket, message)}
    end
  end

  def handle_event("quick_note", %{"note" => text} = params, socket) do
    with :ok <- allow_create(socket) do
      opts = [visibility: visibility_param(params, socket)] ++ folder_opts(socket)

      case Quick.create_note(socket.assigns.scope, socket.assigns.user_uuid, text, opts) do
        {:ok, _board} ->
          {:noreply, socket |> assign(:note, "") |> assign(:error, nil) |> load()}

        {:error, :empty} ->
          {:noreply, fail(socket, "Write something first.")}

        {:error, _reason} ->
          {:noreply, fail(socket, "Could not save the note.")}
      end
    else
      {:error, message} -> {:noreply, fail(socket, message)}
    end
  end

  def handle_event("note_changed", %{"note" => text} = params, socket) do
    {:noreply,
     socket
     |> assign(:note, String.slice(text, 0, @note_max))
     |> assign(:visibility, visibility_param(params, socket))}
  end

  def handle_event("validate_image", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :quick_image, ref)}

  def handle_event("toggle_new", _params, socket),
    do: {:noreply, update(socket, :new_open?, &(not &1))}

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, String.slice(q, 0, 100)) |> load()}
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

  def handle_event("visibility", %{"id" => id, "to" => to}, socket) do
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
  # the board page — a pasted screenshot is small and the person is waiting.
  defp handle_image_progress(:quick_image, %{done?: true} = entry, socket) do
    case allow_create(socket) do
      :ok ->
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            opts = [visibility: socket.assigns.visibility] ++ folder_opts(socket)

            {:ok,
             Quick.create_image(
               socket.assigns.scope,
               socket.assigns.user_uuid,
               path,
               entry,
               opts
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

  defp allow_create(%{assigns: %{can_create?: true, user_uuid: uuid}}) when is_binary(uuid),
    do: :ok

  defp allow_create(_socket), do: {:error, "You cannot add boards here."}

  # The creator, or an admin. Sharing and archiving are narrower (the creator
  # only) and enforced by the context, which does not know about admins.
  defp allow_manage(socket, board) do
    if board.created_by == socket.assigns.user_uuid or socket.assigns.admin?,
      do: :ok,
      else: {:error, :forbidden}
  end

  # The board the browser named, only if it is in THIS panel's place and the
  # user may see it. An id from anywhere else is as good as none.
  defp visible_board(%{assigns: %{can_view?: true} = assigns}, id) do
    case Boards.get_board(id) do
      nil ->
        {:error, :gone}

      board ->
        if Boards.scope_of(board) == assigns.scope and
             Boards.visible_to?(board, assigns.user_uuid),
           do: {:ok, board},
           else: {:error, :gone}
    end
  end

  defp visible_board(_socket, _id), do: {:error, :gone}

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
    socket = socket |> assign(:new_open?, false) |> assign(:error, nil) |> load()

    if socket.assigns.open == :navigate,
      do: push_navigate(socket, to: Paths.user_board(board.uuid, socket.assigns.return_to)),
      else: socket
  end

  defp with_scope(attrs, nil), do: attrs

  defp with_scope(attrs, {type, id}),
    do: Map.merge(attrs, %{"scope_type" => type, "scope_id" => id})

  defp folder_opts(socket), do: [folder: socket.assigns.folder, label: socket.assigns.label]

  defp visibility_param(params, socket) do
    case params["visibility"] do
      v when is_binary(v) ->
        if v in socket.assigns.visibility_options, do: v, else: socket.assigns.default_visibility

      _ ->
        socket.assigns.visibility
    end
  end

  defp blank_to(value, default) do
    case value |> to_string() |> String.trim() do
      "" -> default
      name -> String.slice(name, 0, 200)
    end
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
      <header class="flex items-center justify-between gap-2">
        <h3 class="font-medium text-base-content">
          {@label || "Boards"}
          <span :if={@total > 0} class="ml-1 text-xs font-normal text-base-content/50">{@total}</span>
        </h3>
        <button
          :if={@can_create?}
          type="button"
          phx-click="toggle_new"
          phx-target={@myself}
          class="btn btn-primary btn-xs"
        >
          <.icon name="hero-plus" class="w-3.5 h-3.5" /> New board
        </button>
      </header>

      <div
        :if={@error}
        role="alert"
        class="alert alert-error py-2 text-sm"
      >
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

      <form
        :if={@new_open? and @can_create?}
        id={"#{@id}-new"}
        phx-submit="create"
        phx-target={@myself}
        class="flex flex-wrap items-center gap-2"
      >
        <input
          type="text"
          name="name"
          placeholder="Board name"
          maxlength="200"
          autofocus
          class="input input-bordered input-sm flex-1 min-w-40"
        />
        <.visibility_select options={@visibility_options} selected={@visibility} />
        <button type="submit" class="btn btn-primary btn-sm">Create</button>
      </form>

      <div :if={@quick_capture and @can_create?} class="space-y-2">
        <form
          id={"#{@id}-note"}
          phx-change="note_changed"
          phx-submit="quick_note"
          phx-target={@myself}
          class="space-y-2"
        >
          <textarea
            name="note"
            rows="2"
            maxlength="2000"
            placeholder="Jot a note…"
            class="textarea textarea-bordered w-full text-sm"
          >{@note}</textarea>
          <div class="flex flex-wrap items-center gap-2">
            <.visibility_select options={@visibility_options} selected={@visibility} />
            <button type="submit" class="btn btn-sm btn-outline">
              <.icon name="hero-bolt" class="w-4 h-4" /> Save as board
            </button>
          </div>
        </form>

        <form id={"#{@id}-image"} phx-change="validate_image" phx-target={@myself}>
          <label
            phx-drop-target={@uploads.quick_image.ref}
            class="flex cursor-pointer items-center justify-center gap-2 rounded-lg border border-dashed border-base-300 px-3 py-3 text-sm text-base-content/60 hover:bg-base-200/50"
          >
            <.icon name="hero-photo" class="w-4 h-4" />
            <span>Drop an image here, or click to choose one</span>
            <.live_file_input upload={@uploads.quick_image} class="hidden" />
          </label>
          <div
            :for={entry <- @uploads.quick_image.entries}
            class="mt-2 flex items-center gap-2 text-xs"
          >
            <progress class="progress progress-primary flex-1" value={entry.progress} max="100"></progress>
            <span class="truncate max-w-40">{entry.client_name}</span>
            <button
              type="button"
              phx-click="cancel_image"
              phx-value-ref={entry.ref}
              phx-target={@myself}
              class="btn btn-ghost btn-xs"
              aria-label="Cancel upload"
            >
              <.icon name="hero-x-mark" class="w-3.5 h-3.5" />
            </button>
            <span :for={err <- upload_errors(@uploads.quick_image, entry)} class="text-error">
              {upload_error_text(err)}
            </span>
          </div>
          <p :for={err <- upload_errors(@uploads.quick_image)} class="mt-1 text-xs text-error">
            {upload_error_text(err)}
          </p>
        </form>
      </div>

      <form
        :if={@total > 8 or @search != ""}
        id={"#{@id}-search"}
        phx-change="search"
        phx-submit="search"
        phx-target={@myself}
      >
        <input
          type="search"
          name="q"
          value={@search}
          placeholder="Search boards"
          phx-debounce="250"
          class="input input-bordered input-sm w-full"
        />
      </form>

      <p
        :if={@boards == [] and @search == ""}
        class="rounded-lg border border-dashed border-base-300 p-6 text-center text-sm text-base-content/60"
      >
        <.icon name="hero-rectangle-group" class="mx-auto mb-1 block w-6 h-6 text-base-content/40" />
        No boards here yet.
      </p>
      <p :if={@boards == [] and @search != ""} class="text-sm text-base-content/60">
        No boards match “{@search}”.
      </p>

      <.board_list :if={@boards != []} {assigns} />

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

  # ── Layouts ────────────────────────────────────────────────────────────

  defp board_list(%{layout: :grid} = assigns) do
    ~H"""
    <ul class="grid grid-cols-1 gap-3 sm:grid-cols-2">
      <li
        :for={board <- @boards}
        id={"#{@id}-#{board.uuid}"}
        class="card bg-base-100 border border-base-300 shadow-sm"
      >
        <.board_open board={board} open={@open} return_to={@return_to}>
          <div class="h-24 w-full overflow-hidden rounded-t-lg bg-base-200">
            <img
              :if={board.preview && board.preview["image_url"]}
              src={board.preview["image_url"]}
              loading="lazy"
              alt=""
              class="h-full w-full object-cover"
            />
            <p
              :if={board.preview && !board.preview["image_url"] && board.preview["text"]}
              class="line-clamp-3 whitespace-pre-line p-3 text-sm text-base-content/70"
            >
              {board.preview["text"]}
            </p>
            <div
              :if={is_nil(board.preview) or (!board.preview["image_url"] and !board.preview["text"])}
              class="flex h-full items-center justify-center text-base-content/30"
            >
              <.icon name="hero-rectangle-group" class="w-8 h-8" />
            </div>
          </div>
        </.board_open>
        <div class="card-body gap-1 p-3">
          <.board_title {assigns} board={board} />
          <p class="text-xs text-base-content/50">
            <.time_ago datetime={board.updated_at} class="text-xs" />
          </p>
        </div>
      </li>
    </ul>
    """
  end

  defp board_list(%{layout: :compact} = assigns) do
    ~H"""
    <ul class="space-y-0.5">
      <li
        :for={board <- @boards}
        id={"#{@id}-#{board.uuid}"}
        class="flex items-center gap-1.5 text-sm"
      >
        <.board_flags board={board} user_uuid={@user_uuid} />
        <.board_open
          board={board}
          open={@open}
          return_to={@return_to}
          class="truncate hover:underline"
        >
          {board.name}
        </.board_open>
      </li>
    </ul>
    """
  end

  defp board_list(assigns) do
    ~H"""
    <ul class="divide-y divide-base-300 rounded-lg border border-base-300">
      <li
        :for={board <- @boards}
        id={"#{@id}-#{board.uuid}"}
        class="flex items-center gap-3 px-3 py-2"
      >
        <div class="min-w-0 flex-1">
          <.board_title {assigns} board={board} />
          <p
            :if={board.preview && board.preview["text"] && @renaming != board.uuid}
            class="truncate text-xs text-base-content/60"
          >
            {board.preview["text"]}
          </p>
        </div>
        <img
          :if={board.preview && board.preview["image_url"]}
          src={board.preview["image_url"]}
          loading="lazy"
          alt=""
          class="h-9 w-12 shrink-0 rounded object-cover"
        />
        <span class="hidden shrink-0 text-base-content/50 sm:inline">
          <.time_ago datetime={board.updated_at} class="text-xs" />
        </span>
        <.board_menu {assigns} board={board} />
      </li>
    </ul>
    """
  end

  # The name (or its rename form) with the flags in front, and — for the grid —
  # the menu beside it.
  defp board_title(%{renaming: renaming, board: %{uuid: renaming}} = assigns) do
    ~H"""
    <form phx-submit="rename_save" phx-target={@myself} class="flex items-center gap-1">
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
        class="input input-bordered input-xs flex-1"
      />
      <button type="submit" class="btn btn-primary btn-xs">Save</button>
      <button
        type="button"
        phx-click="rename_cancel"
        phx-target={@myself}
        class="btn btn-ghost btn-xs"
      >
        Cancel
      </button>
    </form>
    """
  end

  defp board_title(%{layout: :grid} = assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <.board_flags board={@board} user_uuid={@user_uuid} />
      <.board_open
        board={@board}
        open={@open}
        return_to={@return_to}
        class="min-w-0 flex-1 truncate font-medium hover:underline"
      >
        {@board.name}
      </.board_open>
      <.board_menu {assigns} />
    </div>
    """
  end

  defp board_title(assigns) do
    ~H"""
    <div class="flex items-center gap-1.5">
      <.board_flags board={@board} user_uuid={@user_uuid} />
      <.board_open
        board={@board}
        open={@open}
        return_to={@return_to}
        class="truncate font-medium hover:underline"
      >
        {@board.name}
      </.board_open>
    </div>
    """
  end

  attr(:board, :any, required: true)
  attr(:user_uuid, :string, default: nil)

  defp board_flags(assigns) do
    ~H"""
    <.icon
      :if={@board.pinned_at}
      name="hero-bookmark-solid"
      class="w-3.5 h-3.5 shrink-0 text-warning"
    />
    <.icon
      :if={@board.visibility == "private"}
      name="hero-lock-closed"
      class="w-3.5 h-3.5 shrink-0 text-base-content/50"
    />
    <.icon
      :if={@board.kind == "quick"}
      name="hero-bolt"
      class="w-3.5 h-3.5 shrink-0 text-base-content/40"
    />
    """
  end

  attr(:board, :any, required: true)
  attr(:open, :atom, required: true)
  attr(:return_to, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  defp board_open(%{open: :new_tab} = assigns) do
    ~H"""
    <a
      href={Paths.user_board(@board.uuid, @return_to)}
      target="_blank"
      rel="noopener"
      class={@class}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  defp board_open(assigns) do
    ~H"""
    <.link navigate={Paths.user_board(@board.uuid, @return_to)} class={@class}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp board_menu(assigns) do
    assigns =
      assigns
      |> assign(:creator?, assigns.board.created_by == assigns.user_uuid)
      |> assign(:manage?, assigns.board.created_by == assigns.user_uuid or assigns.admin?)

    ~H"""
    <div class="dropdown dropdown-end shrink-0">
      <button
        type="button"
        tabindex="0"
        class="btn btn-ghost btn-xs btn-circle"
        aria-label={"Actions for #{@board.name}"}
      >
        <.icon name="hero-ellipsis-horizontal" class="w-4 h-4" />
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-sm z-10 w-48 rounded-box border border-base-300 bg-base-100 p-1 shadow"
      >
        <li :if={@manage?}>
          <button
            type="button"
            phx-click="rename_start"
            phx-value-id={@board.uuid}
            phx-target={@myself}
          >
            <.icon name="hero-pencil" class="w-4 h-4" /> Rename
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
            <.icon name="hero-bookmark" class="w-4 h-4" /> Pin to top
          </button>
          <button
            :if={@board.pinned_at}
            type="button"
            phx-click="unpin"
            phx-value-id={@board.uuid}
            phx-target={@myself}
          >
            <.icon name="hero-bookmark-slash" class="w-4 h-4" /> Unpin
          </button>
        </li>
        <li :if={@creator? and length(@visibility_options) == 2 and @board.visibility == "shared"}>
          <button
            type="button"
            phx-click="visibility"
            phx-value-id={@board.uuid}
            phx-value-to="private"
            phx-target={@myself}
          >
            <.icon name="hero-lock-closed" class="w-4 h-4" /> Make private
          </button>
        </li>
        <li :if={@creator? and length(@visibility_options) == 2 and @board.visibility == "private"}>
          <button
            type="button"
            phx-click="visibility"
            phx-value-id={@board.uuid}
            phx-value-to="shared"
            phx-target={@myself}
          >
            <.icon name="hero-user-group" class="w-4 h-4" /> Share with everyone here
          </button>
        </li>
        <li :if={@creator?}>
          <button type="button" phx-click="archive" phx-value-id={@board.uuid} phx-target={@myself}>
            <.icon name="hero-archive-box" class="w-4 h-4" /> Archive
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
            <.icon name="hero-trash" class="w-4 h-4" /> Delete
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr(:options, :list, required: true)
  attr(:selected, :string, required: true)

  defp visibility_select(%{options: [_single]} = assigns) do
    ~H"""
    <input type="hidden" name="visibility" value={@selected} />
    <span
      :if={@selected == "private"}
      class="inline-flex items-center gap-1 text-xs text-base-content/60"
    >
      <.icon name="hero-lock-closed" class="w-3.5 h-3.5" /> Only me
    </span>
    """
  end

  defp visibility_select(assigns) do
    ~H"""
    <select name="visibility" class="select select-bordered select-sm" aria-label="Who can see it">
      <option :for={option <- @options} value={option} selected={option == @selected}>
        {visibility_label(option)}
      </option>
    </select>
    """
  end

  defp visibility_label("private"), do: "Only me"
  defp visibility_label("shared"), do: "Everyone here"

  defp upload_error_text(:too_large), do: "That file is too large."
  defp upload_error_text(:not_accepted), do: "Only images can be dropped here."
  defp upload_error_text(:too_many_files), do: "One image at a time."
  defp upload_error_text(_), do: "That upload failed."
end
