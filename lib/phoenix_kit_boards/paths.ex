defmodule PhoenixKitBoards.Paths do
  @moduledoc """
  Centralized path helpers. Every link/redirect goes through
  `PhoenixKit.Utils.Routes.path/1` so the host's URL prefix + locale are
  applied — never hardcode PhoenixKit paths.
  """

  alias PhoenixKit.Utils.Routes

  @doc "The boards list page."
  def boards, do: Routes.path("/admin/boards")

  @doc "A single board page."
  def board(id), do: Routes.path("/admin/boards/#{id}")
end
