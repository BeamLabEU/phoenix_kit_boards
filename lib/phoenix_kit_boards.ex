defmodule PhoenixKitBoards do
  @moduledoc """
  Collaborative infinite-canvas **boards** for PhoenixKit.

  Admins open **Boards** in the sidebar, create a board, and open it — an
  infinite [Fresco](https://hex.pm/packages/fresco) canvas with the
  [Etcher](https://hex.pm/packages/etcher) drawing layer (shapes, text,
  images). Multiple people on the same board see each other's edits, cursors,
  and presence in real time. Each board is one row in `phoenix_kit_boards`
  (its `Fresco.Canvas` document lives in the `data` jsonb column).

  ## How it works

  - **Zero JS setup.** PhoenixKit core already loads `fresco.js` + `etcher.js`
    and their hooks (the media annotation feature), so `<Fresco.canvas>` +
    `<Etcher.layer>` work in this module's pages out of the box. This module's
    own collaboration hooks are delivered by the board page itself, as
    LiveView runtime hooks — see `PhoenixKitBoards.Web.RuntimeHooks`. Nothing
    is asked of the host beyond depending on this module: no compiler entry,
    no script tag, no `app.js` import.

    `js_sources/0` is still declared, so a host running core's
    `:phoenix_kit_js_sources` compiler keeps getting the bundle that way and
    LiveView prefers it. It is no longer load-bearing — which it silently
    was. A host that bundles dependency JS its own way got no hooks and no
    error: the board rendered and local edits saved, so the failure looked
    like "collaboration is broken" rather than "the JS never loaded".
  - **Collaboration** rides the etcher document: each edit re-emits the full
    annotation list (`etcher:annotations-changed`); the LiveView persists it,
    broadcasts over PubSub, and peers apply the delta — no canvas remount.
  - **Presence + cursors** ride plain PubSub on the board's topic.

  ## Installation

      # host mix.exs
      {:phoenix_kit_boards, "~> 0.1"}

  Then `mix deps.get` and `mix phoenix_kit.update` (creates the
  `phoenix_kit_boards` table). Enable it on the admin Modules page.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ── Required callbacks ─────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def module_key, do: "boards"

  @impl PhoenixKit.Module
  def module_name, do: "Boards"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("boards_enabled", false)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system,
    do: Settings.update_boolean_setting_with_module("boards_enabled", true, module_key())

  @impl PhoenixKit.Module
  def disable_system,
    do: Settings.update_boolean_setting_with_module("boards_enabled", false, module_key())

  # ── Optional callbacks ─────────────────────────────────────────────────

  @impl PhoenixKit.Module
  def version, do: "0.3.0"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Boards",
      icon: "hero-rectangle-group",
      description: "Collaborative infinite-canvas boards"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    # Multi-page module: routes come from `route_module/0`, so the tab carries
    # no `:live_view` — it's the sidebar entry (and active-state anchor) only.
    [
      %Tab{
        id: :admin_boards,
        label: "Boards",
        icon: "hero-rectangle-group",
        path: "boards",
        priority: 645,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc "Multi-page routing (list + individual board) — see `PhoenixKitBoards.Routes`."
  def route_module, do: PhoenixKitBoards.Routes

  @impl PhoenixKit.Module
  @doc "The `phoenix_kit_boards` table coordinator (run by `mix phoenix_kit.update`)."
  def migration_module, do: PhoenixKitBoards.Migrations

  @impl PhoenixKit.Module
  @doc "Tailwind scans this app's templates for classes used by the board UI."
  def css_sources, do: [:phoenix_kit_boards]

  @impl PhoenixKit.Module
  @doc """
  The collaboration + cursors hook bundle. Core's `:phoenix_kit_js_sources`
  compiler concatenates this into the host's `phoenix_kit_modules.js` (loaded
  before app.js) and folds `window.PhoenixKitBoardsHooks` into
  `window.PhoenixKitHooks`.

  A fast path, not a requirement. Hosts that don't run that compiler get the
  same hooks from `PhoenixKitBoards.Web.RuntimeHooks`, which the board page
  emits itself; LiveView checks the host's own registration first, so where
  both exist this one wins and there is never a second copy.
  """
  def js_sources do
    [
      %{
        app: :phoenix_kit_boards,
        file: "static/assets/phoenix_kit_boards.js",
        global: "PhoenixKitBoardsHooks"
      }
    ]
  end

  @impl PhoenixKit.Module
  def get_config, do: %{enabled: enabled?()}
end
