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

  With no hook configured any signed-in user holding the `"boards"` permission
  may view and create. A hook that raises, throws, exits, is not exported or
  answers something other than a boolean **denies** — a broken rule must not
  open a door — and the failure is logged by shape only (never the arguments,
  which name a user and a place).

  Two permission keys, kept apart:

    * `"boards"` — the user's. Without it nobody gets anything here, and the
      host's hook is not even asked; with it, the hook (if any) decides the
      place.
    * `"boards.manage"` — the admin's. It opens any board in any place, as it
      always could on `/admin/boards`: that includes other people's private
      ones, and the hook is not asked.

  Everything here takes the `PhoenixKit.Users.Auth.Scope` of the session when
  the caller has one, and builds it from the user otherwise.
  """

  require Logger

  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKitBoards.{Board, Boards}

  @app :phoenix_kit_boards
  @actions [:view, :create]

  @doc """
  Whether `user` may `action` (`:view` or `:create`) in `place`: a holder of
  `"boards.manage"` always may; anyone else needs the base `"boards"`
  permission *and* the host's rule. A missing user is always refused.

  `phoenix_scope` is the session's `PhoenixKit.Users.Auth.Scope`; built from
  `user` when not given. `user` is a `PhoenixKit.Users.Auth.User`: anything
  else, a plain map included, holds no permission and is refused.
  """
  @spec can?(:view | :create, User.t() | nil, Boards.scope(), Scope.t() | nil) :: boolean()
  def can?(action, user, place, phoenix_scope \\ nil) when action in @actions do
    case user do
      %{uuid: uuid} when is_binary(uuid) ->
        scope = scope_for(user, phoenix_scope)
        admin?(scope) or (user?(scope) and host_allows?(action, user, place))

      _ ->
        false
    end
  end

  @doc """
  Whether the viewer may open `board`: a holder of `"boards.manage"` always
  may; anyone else needs the base `"boards"` permission, the board to be
  visible to them by the module's rule *and* the host to allow `:view` of its
  place. A board with no place is for admins only.
  """
  @spec can_open?(Board.t(), User.t() | nil, Scope.t() | nil) :: boolean()
  def can_open?(%Board{} = board, user, phoenix_scope \\ nil) do
    scope = scope_for(user, phoenix_scope)

    cond do
      admin?(scope) ->
        true

      is_nil(Boards.scope_of(board)) ->
        false

      true ->
        Boards.visible_to?(board, user_uuid(user)) and
          can?(:view, user, Boards.scope_of(board), scope)
    end
  end

  @doc """
  Whether `user` may see the boards of `place` listed — what a list of a place's
  boards (`PhoenixKitBoards.Web.BoardsPanel`) asks before showing any of them.

  The same rule as `can?/4` for `:view`; and for the unscoped boards (`nil`),
  `"boards.manage"` only. Those are the boards `/admin/boards` lists, and
  `can_open?/3` opens them for admins only — a list that showed them to anyone
  else would publish their names and previews behind tiles that do not open.
  """
  @spec can_list?(User.t() | nil, Boards.scope(), Scope.t() | nil) :: boolean()
  def can_list?(user, place, phoenix_scope \\ nil)

  def can_list?(user, nil, phoenix_scope) do
    case user do
      %{uuid: uuid} when is_binary(uuid) -> user |> scope_for(phoenix_scope) |> admin?()
      _ -> false
    end
  end

  def can_list?(user, place, phoenix_scope), do: can?(:view, user, place, phoenix_scope)

  @doc "Whether the session holds the `\"boards.manage\"` permission."
  @spec admin?(term()) :: boolean()
  def admin?(scope) when is_struct(scope, Scope), do: Scope.can?(scope, "boards.manage")
  def admin?(_), do: false

  # The base key, `Scope.can?/2` checks the module is enabled as well.
  defp user?(scope) when is_struct(scope, Scope), do: Scope.can?(scope, "boards")
  defp user?(_), do: false

  # The session's scope when the caller has it, else one built from the user.
  # Only a persisted user has one: anything else holds no permission.
  defp scope_for(_user, %Scope{} = scope), do: scope
  defp scope_for(%User{} = user, _), do: Scope.for_user(user)
  defp scope_for(_user, _), do: nil

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
