defmodule PhoenixKitBoards.Web.IndexLive do
  @moduledoc """
  The boards list (`/admin/boards`): create a board, open one, or delete it.
  PhoenixKit applies the admin layout automatically.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKitBoards.{Boards, Paths}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Boards")
     |> load_boards()}
  end

  @impl true
  def handle_event("create", _params, socket) do
    attrs = %{
      "name" => "Untitled board",
      "created_by" => current_user_uuid(socket)
    }

    case Boards.create_board(attrs) do
      {:ok, board} -> {:noreply, push_navigate(socket, to: Paths.board(board.uuid))}
      {:error, _cs} -> {:noreply, put_flash(socket, :error, "Could not create the board.")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Boards.get_board(id) do
      nil ->
        {:noreply, socket}

      board ->
        case Boards.delete_board(board) do
          {:ok, _board} ->
            {:noreply, load_boards(socket)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not delete the board.")}
        end
    end
  end

  defp load_boards(socket), do: assign(socket, :boards, Boards.list_boards())

  defp current_user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-5xl px-4 py-6 space-y-6">
      <div class="flex items-center justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold">Boards</h1>
          <p class="text-sm text-base-content/60">
            Collaborative infinite canvases — open one in two tabs to see live sync.
          </p>
        </div>
        <button type="button" phx-click="create" class="btn btn-primary btn-sm">
          <.icon name="hero-plus" class="w-4 h-4" /> New board
        </button>
      </div>

      <div
        :if={@boards == []}
        class="rounded-lg border border-dashed border-base-300 p-10 text-center"
      >
        <.icon name="hero-rectangle-group" class="w-8 h-8 mx-auto text-base-content/40" />
        <p class="mt-2 text-base-content/60">No boards yet. Create your first one.</p>
      </div>

      <ul :if={@boards != []} class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <li :for={board <- @boards} class="card bg-base-100 border border-base-300 shadow-sm">
          <div class="card-body p-4 gap-3">
            <div class="flex items-start justify-between gap-2">
              <.link navigate={Paths.board(board.uuid)} class="font-medium hover:underline truncate">
                {board.name}
              </.link>
              <button
                type="button"
                phx-click="delete"
                phx-value-id={board.uuid}
                data-confirm="Delete this board?"
                class="btn btn-ghost btn-xs btn-circle text-error"
                aria-label="Delete board"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            </div>
            <p class="text-xs text-base-content/50">
              Updated {Calendar.strftime(board.updated_at, "%Y-%m-%d %H:%M")}
            </p>
            <.link navigate={Paths.board(board.uuid)} class="btn btn-sm btn-outline w-full">
              Open
            </.link>
          </div>
        </li>
      </ul>
    </div>
    """
  end
end
