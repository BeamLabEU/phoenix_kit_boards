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
end
