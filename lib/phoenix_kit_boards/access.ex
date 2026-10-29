defmodule PhoenixKitBoards.Access do
  @moduledoc """
  Who may do what with boards that belong to a place.

  Two rules meet here, and they are kept apart on purpose:

    * **The module's own rule** (`PhoenixKitBoards.Boards.visible_to?/2`): a
      *private* board is its creator's alone. The host cannot widen that.
    * **The host's rule**: whether a user may look at / add to a *place* at
      all. The module cannot know what "can see project X" means in your app,
      so it asks:

          config :phoenix_kit_boards, :authorize, {MyApp.Boards, :can?}

      called as `can?(action, user, scope)` with `action` one of `:view` or
      `:create`, `user` the signed-in user and `scope` the `{type, id}` pair
      (or `nil` for boards with no place). It answers a boolean.

  With no hook configured any signed-in user may view and create. A hook that
  raises, throws, exits, is not exported or answers something other than a
  boolean **denies** — a broken rule must not open a door — and the failure is
  logged by shape only (never the arguments, which name a user and a place).

  Users holding the `"boards"` admin permission may open any board, as they
  always could on `/admin/boards`: that includes other people's private ones.
  """

  require Logger

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBoards.{Board, Boards}

  @app :phoenix_kit_boards
  @actions [:view, :create]

  @doc """
  Whether `user` may `action` (`:view` or `:create`) in `scope`, by the host's
  rule. A missing user is always refused.
  """
  @spec can?(:view | :create, map() | nil, Boards.scope()) :: boolean()
  def can?(action, user, scope) when action in @actions do
    case user do
      %{uuid: uuid} when is_binary(uuid) -> host_allows?(action, user, scope)
      _ -> false
    end
  end

  @doc """
  Whether the viewer may open `board`: an admin with the `"boards"` permission
  always may (`phoenix_scope` is the `PhoenixKit.Users.Auth.Scope` of the
  session); anyone else needs the board to be visible to them by the module's
  rule *and* the host to allow `:view` of its place. A board with no place is
  admin-only.
  """
  @spec can_open?(Board.t(), map() | nil, Scope.t() | nil) :: boolean()
  def can_open?(%Board{} = board, user, phoenix_scope \\ nil) do
    cond do
      admin?(phoenix_scope) ->
        true

      is_nil(Boards.scope_of(board)) ->
        false

      true ->
        Boards.visible_to?(board, user_uuid(user)) and can?(:view, user, Boards.scope_of(board))
    end
  end

  @doc "Whether the session holds the `\"boards\"` admin permission."
  @spec admin?(Scope.t() | nil) :: boolean()
  def admin?(%Scope{} = scope), do: Scope.can?(scope, "boards")
  def admin?(_), do: false

  defp user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil

  defp host_allows?(action, user, scope) do
    case Application.get_env(@app, :authorize) do
      nil -> true
      {mod, fun} when is_atom(mod) and is_atom(fun) -> ask(mod, fun, action, user, scope)
      other -> deny("the config is not a {module, function} pair: #{shape(other)}")
    end
  end

  defp ask(mod, fun, action, user, scope) do
    Code.ensure_loaded(mod)

    if function_exported?(mod, fun, 3) do
      case apply(mod, fun, [action, user, scope]) do
        answer when is_boolean(answer) -> answer
        other -> deny("the hook answered #{shape(other)}")
      end
    else
      deny("#{inspect(mod)}.#{fun}/3 is not exported")
    end
  rescue
    error -> deny("the hook raised #{inspect(error.__struct__)}")
  catch
    :throw, _ -> deny("the hook threw")
    :exit, _ -> deny("the hook exited")
  end

  defp deny(reason) do
    Logger.warning("[boards] :authorize hook refused by default: #{reason}")
    false
  end

  defp shape(value) when is_atom(value), do: inspect(value)
  defp shape(value) when is_tuple(value), do: "a #{tuple_size(value)}-tuple"
  defp shape(value) when is_map(value), do: "a map"
  defp shape(value) when is_list(value), do: "a list"
  defp shape(value) when is_binary(value), do: "a string"
  defp shape(_), do: "a value of another type"
end
