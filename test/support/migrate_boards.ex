defmodule PhoenixKitBoards.Test.MigrateBoards do
  @moduledoc """
  Runs this module's own versioned chain in the test database, the way a host's
  generated migration does (`mix phoenix_kit.update`).
  """
  use Ecto.Migration

  def up, do: PhoenixKitBoards.Migrations.up()
  def down, do: PhoenixKitBoards.Migrations.down()
end
