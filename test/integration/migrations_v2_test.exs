defmodule PhoenixKitBoards.Integration.MigrationsV2Test do
  # Not async: it rewrites the table's version comment (inside the sandbox
  # transaction, so it is rolled back, but the comment is global to the table).
  use PhoenixKitBoards.DataCase, async: false

  alias PhoenixKitBoards.Migrations

  defp columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'phoenix_kit_boards'"
      )

    List.flatten(rows)
  end

  test "the chain is installed at the current version" do
    assert Migrations.migrated_version_runtime() == Migrations.current_version()
  end

  test "V2 adds the scope, visibility and folder columns" do
    for column <- ~w(scope_type scope_id visibility kind folder_uuid folder_parent_uuid
                     preview pinned_at archived_at) do
      assert column in columns(), "missing column #{column}"
    end
  end

  test "a V2 table that lost its stamp is recognised by its shape" do
    Repo.query!("COMMENT ON TABLE phoenix_kit_boards IS NULL")
    assert Migrations.migrated_version_runtime() == 2
  end

  test "rows from before V2 read as unscoped, shared canvas boards" do
    Repo.query!("INSERT INTO phoenix_kit_boards (name, data, inserted_at, updated_at)
                 VALUES ('old', '{}', now(), now())")

    assert %{rows: [["shared", "canvas", nil, nil]]} =
             Repo.query!(
               "SELECT visibility, kind, scope_type, scope_id FROM phoenix_kit_boards WHERE name = 'old'"
             )
  end
end
