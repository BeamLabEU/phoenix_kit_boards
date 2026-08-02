defmodule PhoenixKitBoards.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Migrations

  describe "current_version/0" do
    test "matches the highest version the coordinator can apply" do
      assert Migrations.current_version() == 1
    end
  end

  describe "parse_version_comment/1" do
    test "reads the stamp written by record_version/2" do
      assert Migrations.parse_version_comment("1") == {:ok, 1}
      assert Migrations.parse_version_comment("12") == {:ok, 12}
    end

    test "tolerates surrounding whitespace" do
      assert Migrations.parse_version_comment(" 1 ") == {:ok, 1}
      assert Migrations.parse_version_comment("1\n") == {:ok, 1}
    end

    # A table with no comment at all is the case that used to be assumed to be
    # version 1 — an assertion about a table nobody had looked at. It now falls
    # through to shape inspection instead.
    test "treats a missing comment as unstamped" do
      assert Migrations.parse_version_comment(nil) == :unstamped
    end

    # Somebody else's annotation on our table must not be read as a version,
    # and must not crash the migration by reaching String.to_integer/1.
    test "treats a non-version comment as unstamped" do
      assert Migrations.parse_version_comment("collaborative boards") == :unstamped
      assert Migrations.parse_version_comment("") == :unstamped
      assert Migrations.parse_version_comment("1.2") == :unstamped
      assert Migrations.parse_version_comment("v1") == :unstamped
      assert Migrations.parse_version_comment("1 board") == :unstamped
    end

    test "rejects a negative version rather than accepting a bogus stamp" do
      assert Migrations.parse_version_comment("-1") == :unstamped
    end
  end
end
