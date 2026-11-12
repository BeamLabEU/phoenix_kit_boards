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
      {:phoenix_kit_boards, "~> 0.6"}

  Then `mix deps.get` and `mix phoenix_kit.update` (creates the
  `phoenix_kit_boards` table). Enable it on the admin Modules page.
  """

  use PhoenixKit.Module
  use Gettext, backend: PhoenixKitBoards.Gettext

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions

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
  def version, do: "0.7.0"

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Boards",
      icon: "hero-rectangle-group",
      description: "Collaborative infinite-canvas boards",
      # The base key is the user's: the boards widget and the board page on
      # `/dashboard/boards/:id`, where the host's `:authorize` hook still
      # decides which places. `boards.manage` is the admin's: `/admin/boards`,
      # any board in any place, and no hook. `migrate_legacy/0` grants it once
      # to every role that held `boards` before the split.
      sub_permissions: [
        %{
          key: "manage",
          label: "Manage boards",
          description:
            "Open the boards admin pages and every board, in any place, whoever made it"
        }
      ],
      gettext_backend: PhoenixKitBoards.Gettext,
      gettext_domain: "default"
    }
  end

  @manage_backfill_key "boards_manage_backfilled"

  @doc """
  One-time data repair core calls on every boot.

  `boards.manage` is granted to every role that already holds the base
  `boards` key, so nobody loses the admin pages when they move behind the
  sub-key. A role granted `boards` afterwards gets the narrow, user meaning,
  and a later revoke sticks. Once every grant has succeeded the
  `boards_manage_backfilled` setting (`"true"`, module `"boards"`) is set; a
  failed pass leaves it unset and retries on the next boot. The name of that
  setting is part of this module's contract: a host that grants the keys in
  its own migration reads it to know whether this ran.
  """
  @impl PhoenixKit.Module
  def migrate_legacy do
    if Settings.get_setting(@manage_backfill_key) == "true",
      do: :ok,
      else: backfill_manage_permission()
  rescue
    error ->
      Logger.warning("[PhoenixKitBoards] migrate_legacy failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  end

  @doc false
  # `:grant` and `:role_grants` are options only so a test can make a grant
  # or the lookup fail and prove the flag then stays unset; production always
  # uses core's grant and `role_grants/0`.
  def backfill_manage_permission(opts \\ []) do
    grant = Keyword.get(opts, :grant, &Permissions.grant_permission/3)
    role_grants = Keyword.get(opts, :role_grants, &role_grants/0)
    key = "#{module_key()}.manage"

    failures =
      for {role_uuid, granted} <- role_grants.(),
          module_key() in granted,
          key not in granted,
          result = grant.(role_uuid, key, nil),
          not match?({:ok, _}, result) do
        {role_uuid, result}
      end

    with [] <- failures,
         {:ok, _} <-
           Settings.update_setting_with_module(@manage_backfill_key, "true", module_key()) do
      :ok
    else
      failed ->
        Logger.warning(
          "[PhoenixKitBoards] #{key} backfill incomplete, will retry next boot: " <>
            inspect(failed)
        )

        {:error, {:manage_backfill_incomplete, failed}}
    end
  end

  # Every role's granted keys, read with a query that RAISES on failure (and
  # `migrate_legacy/0` rescues it, leaving the flag unset). Core's
  # `Permissions.get_permissions_for_role/1` rescues a query error to `[]`,
  # which would read as "this role has no `boards`" and set the flag for good
  # with the role never granted the sub-key.
  defp role_grants do
    import Ecto.Query, only: [from: 2]

    from(rp in PhoenixKit.Users.RolePermission, select: {rp.role_uuid, rp.module_key})
    |> PhoenixKit.RepoHelper.repo().all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Pins the labels `permission_metadata/0` declares as gettext msgids.

  They are plain string literals there, so `mix gettext.extract` never sees
  them; the permissions matrix translates them at render time through the
  declared backend, but only msgids already in the catalogue.
  `dgettext_noop/2` registers the msgid and returns it unchanged.
  """
  @spec translatable_labels() :: [String.t()]
  def translatable_labels do
    [
      dgettext_noop("default", "Boards"),
      dgettext_noop("default", "Manage boards"),
      dgettext_noop(
        "default",
        "Open the boards admin pages and every board, in any place, whoever made it"
      )
    ]
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
        permission: "#{module_key()}.manage",
        match: :prefix,
        group: :admin_modules
      }
    ]
  end

  @impl PhoenixKit.Module
  @doc """
  The board page for signed-in users who are not admins — the people who meet a
  `PhoenixKitBoards.Web.BoardsPanel` on a page of the host app and open a board
  from it. Hidden from the dashboard menu (`visible: false`): it exists only so
  core generates the route, `/dashboard/boards/:id`, inside the authenticated
  live_session with the user layout.

  Whether a given user may open a given board is decided by
  `PhoenixKitBoards.Access`, not by the route.
  """
  def user_dashboard_tabs do
    [
      %Tab{
        id: :user_board,
        label: "Board",
        path: "/dashboard/boards/:id",
        level: :user,
        visible: false,
        live_view: {PhoenixKitBoards.Web.BoardLive, :user}
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
