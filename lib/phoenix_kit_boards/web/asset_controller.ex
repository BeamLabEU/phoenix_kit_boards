defmodule PhoenixKitBoards.Web.AssetController do
  @moduledoc """
  Serves this module's collaboration hook bundle.

  The bundle is what makes a board collaborative — without it a peer's edits
  and cursors never arrive, though the page renders and local edits still
  save, so the failure looks like "collaboration is broken" rather than
  "the JS didn't load".

  Getting it into the page used to be the host's job: declare `js_sources/0`,
  add `:phoenix_kit_js_sources` to `compilers`, carry a `<script>` tag. A host
  that bundles dependency JS its own way got none of that, and nothing said
  so. Now the board page asks for the bundle from here, so the only thing a
  host has to do is depend on this module.

  Read once at compile time rather than from `priv` per request: it is 40 KB,
  it cannot change while the VM is up, and it removes any question of
  `priv_dir` resolving differently inside a release.
  """
  # A plug rather than `use Phoenix.Controller`: the response is a fixed
  # binary with fixed headers, so none of the view, layout or format
  # negotiation machinery has anything to do here.
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(action), do: action

  @impl Plug
  def call(conn, :js), do: js(conn, conn.params)

  @bundle_path Path.join(
                 :code.priv_dir(:phoenix_kit_boards),
                 "static/assets/phoenix_kit_boards.js"
               )
  @external_resource @bundle_path

  @bundle File.read!(@bundle_path)
  @digest :sha256 |> :crypto.hash(@bundle) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  @etag ~s("#{@digest}")

  @doc """
  The bundle's content digest.

  Rides on the URL as a query parameter so the response can be cached
  indefinitely and still be replaced the moment the module is upgraded.
  """
  def digest, do: @digest

  def js(conn, _params) do
    conn = put_resp_header(conn, "etag", @etag)

    if stale?(conn) do
      conn
      |> put_resp_header("content-type", "text/javascript; charset=utf-8")
      # Safe to keep forever because the digest is in the URL: a new bundle is
      # a new URL, so nothing has to expire for an upgrade to take effect.
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, @bundle)
    else
      send_resp(conn, 304, "")
    end
  end

  defp stale?(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.all?(&(&1 != @etag and &1 != "*"))
  end
end
