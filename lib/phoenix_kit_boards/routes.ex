defmodule PhoenixKitBoards.Routes do
  @moduledoc """
  Route macros for the two board admin pages: the list (`/admin/boards`) and a
  single board (`/admin/boards/:id`). Returned from
  `PhoenixKitBoards.route_module/0`; PhoenixKit injects these inside the admin
  `live_session` (auth + admin layout applied automatically).

  Both localized (`/:locale/admin/...`) and non-localized sets are defined, as
  required — each route needs a unique `:as`.
  """

  @doc "Localized admin routes (inside the /:locale scope)."
  def admin_locale_routes do
    quote do
      live("/admin/boards", PhoenixKitBoards.Web.IndexLive, :index,
        as: :phoenix_kit_boards_localized
      )

      # Before `/admin/boards/:id`, which would otherwise claim it.
      get("/admin/boards/assets/hooks.js", PhoenixKitBoards.Web.AssetController, :js,
        as: :phoenix_kit_boards_hooks_localized
      )

      live("/admin/boards/:id", PhoenixKitBoards.Web.BoardLive, :show,
        as: :phoenix_kit_board_localized
      )
    end
  end

  @doc "Non-localized admin routes."
  def admin_routes do
    quote do
      live("/admin/boards", PhoenixKitBoards.Web.IndexLive, :index, as: :phoenix_kit_boards)

      # Before `/admin/boards/:id`, which would otherwise claim it.
      get("/admin/boards/assets/hooks.js", PhoenixKitBoards.Web.AssetController, :js,
        as: :phoenix_kit_boards_hooks
      )

      live("/admin/boards/:id", PhoenixKitBoards.Web.BoardLive, :show, as: :phoenix_kit_board)
    end
  end
end
