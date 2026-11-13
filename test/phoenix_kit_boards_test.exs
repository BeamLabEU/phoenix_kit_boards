defmodule PhoenixKitBoardsTest do
  use ExUnit.Case, async: true

  test "module metadata" do
    assert PhoenixKitBoards.module_key() == "boards"
    assert PhoenixKitBoards.module_name() == "Boards"
    assert PhoenixKitBoards.route_module() == PhoenixKitBoards.Routes
    assert PhoenixKitBoards.migration_module() == PhoenixKitBoards.Migrations
  end

  test "js_sources declares the collab bundle" do
    assert [%{global: "PhoenixKitBoardsHooks"}] = PhoenixKitBoards.js_sources()
  end

  test "version/0 matches mix.exs" do
    assert PhoenixKitBoards.version() == Mix.Project.config()[:version]
  end

  describe "permissions" do
    test "boards.manage is declared as the one sub-permission, under the base key" do
      meta = PhoenixKitBoards.permission_metadata()

      assert meta.key == "boards"
      assert [%{key: "manage", label: label, description: description}] = meta.sub_permissions
      assert is_binary(label) and is_binary(description)
      assert meta.gettext_backend == PhoenixKitBoards.Gettext
    end

    test "every declared label is a msgid of the catalogue" do
      meta = PhoenixKitBoards.permission_metadata()
      [sub] = meta.sub_permissions

      for label <- [meta.label, sub.label, sub.description] do
        assert label in PhoenixKitBoards.translatable_labels()
      end
    end

    test "the admin tab is behind boards.manage" do
      assert [%{permission: "boards.manage"}] = PhoenixKitBoards.admin_tabs()
    end

    test "the user page is not behind the admin key" do
      assert [%{level: :user, visible: false}] = PhoenixKitBoards.user_dashboard_tabs()
    end
  end
end
