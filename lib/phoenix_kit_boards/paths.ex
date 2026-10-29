defmodule PhoenixKitBoards.Paths do
  @moduledoc """
  Centralized path helpers. Every link/redirect goes through
  `PhoenixKit.Utils.Routes.path/1` so the host's URL prefix + locale are
  applied — never hardcode PhoenixKit paths.
  """

  alias PhoenixKit.Utils.Routes

  @doc "The boards list page."
  def boards, do: Routes.path("/admin/boards")

  @doc "A single board page (the admin one)."
  def board(id), do: Routes.path("/admin/boards/#{id}")

  @doc """
  A board page for signed-in users who are not admins, optionally remembering
  the page they came from so the board can link back to it.

  `return_to` is only kept when it is a path on this site (see `local_path/1`).
  """
  def user_board(id, return_to \\ nil) do
    base = Routes.path("/dashboard/boards/#{id}")

    case local_path(return_to) do
      nil -> base
      path -> base <> "?" <> URI.encode_query(%{"return_to" => path})
    end
  end

  @doc """
  `path` when it is a path on this site, else `nil`.

  A `return_to` is attacker-controlled, so a back link built from it must not
  leave the site: `//evil.example`, `/\\evil.example` and `https://...` are
  all refused. Only a single leading slash followed by something that is not a
  second slash, backslash, or control character is a local path.
  """
  @spec local_path(term()) :: String.t() | nil
  def local_path("/" <> rest = path) when byte_size(path) <= 2000 do
    cond do
      String.starts_with?(rest, ["/", "\\"]) -> nil
      String.match?(path, ~r/[\x00-\x1f\x7f\\]/) -> nil
      true -> path
    end
  end

  def local_path(_), do: nil
end
