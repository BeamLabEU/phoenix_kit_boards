defmodule PhoenixKitBoards.LinkPreview do
  @moduledoc """
  Turn a pasted URL into a preview card image.

  Four steps, each of which can fail without taking the paste with it — the
  caller falls back to leaving the link on the canvas as text:

    1. `fetch/1` — GET the page, under SSRF, size and time limits.
    2. `metadata/2` — read its OpenGraph tags, falling back to `<title>`.
    3. `scene/1` — lay the card out as an `OpenFresco.Scene`.
    4. `svg/1` — emit it as a self-contained SVG.

  ## Why SVG and not PNG

  open_fresco can rasterise, but only through the optional `:resvg` NIF or a
  resvg / rsvg-convert / magick binary on PATH — and "magick is installed" is
  not the same as "magick can draw an SVG": without its rsvg delegate it
  falls back to an internal renderer that can't load fonts and emits zero
  bytes, while still reporting a rasterizer as available.

  The browser already has a correct SVG renderer with the right fonts, so it
  does that half: the client draws this SVG onto a canvas, exports a PNG, and
  sends it through the ordinary image-upload path. No native dependency, and
  the card ends up in storage like any other pasted picture.

  The hero image is inlined as a `data:` URL for the same reason it has to
  be: an SVG referencing a remote image would make the *renderer* fetch it,
  which is the hole the SSRF guard here exists to close.

  ## Why the fetch is the careful part

  The URL comes from whatever a user pasted, and the request is made by the
  *server*, from inside the network the server lives in. Unguarded that is a
  textbook SSRF: paste `http://169.254.169.254/…` and the reply is the cloud
  instance's credentials. So the host is resolved and every address it maps
  to is checked against the private, loopback, link-local and CGNAT ranges
  before a byte is sent — and again on each redirect, because a public host
  is free to redirect to a private one.

  The rest is proportion: a 10s timeout, a 2MB cap, and HTML only. A link
  preview is a nicety, and none of it is worth a hung request or a page of
  arbitrary size buffered into memory.
  """

  require Logger

  alias OpenFresco.Scene

  @timeout_ms 10_000
  @max_bytes 2 * 1024 * 1024
  @max_redirects 3

  # Card proportions, in the same units the Scene is laid out in.
  @card_w 640
  @card_h 480
  @image_h 300

  @doc """
  Unfurl `url` into `{:ok, %{svg: binary, width: integer, height: integer}}`.

  Any failure — unreachable, not HTML, no usable metadata — comes back as
  `{:error, reason}` and is the caller's cue to leave the pasted link as text.
  """
  @spec unfurl(String.t()) :: {:ok, map()} | {:error, term()}
  def unfurl(url) when is_binary(url) do
    with {:ok, html, final_url} <- fetch(url),
         {:ok, meta} <- metadata(html, final_url) do
      svg = meta |> inline_hero() |> scene() |> svg()
      {:ok, %{svg: svg, width: @card_w, height: @card_h}}
    end
  end

  # open_fresco refuses remote image hrefs by default — rendering one would
  # mean the rasterizer making the request, which is the SSRF hole this
  # module exists to close. So the hero is fetched HERE, through the same
  # guard as the page, and handed over as a `data:` URL, which always passes.
  #
  # Best effort: a card with a title and no picture is still a card, so a
  # hero that won't load is dropped rather than failing the unfurl.
  defp inline_hero(%{image: nil} = meta), do: meta

  defp inline_hero(%{image: src} = meta) do
    case fetch_image(src) do
      {:ok, data_url} ->
        %{meta | image: data_url}

      {:error, reason} ->
        Logger.debug("[boards] link preview hero dropped (#{inspect(reason)}): #{src}")
        %{meta | image: nil}
    end
  end

  defp fetch_image(src) do
    with {:ok, uri} <- safe_uri(src),
         {:ok, %{status: 200, headers: headers, body: body}} <-
           Req.get(URI.to_string(uri), receive_timeout: @timeout_ms, max_retries: 0) do
      type = headers |> header("content-type") |> to_string() |> String.split(";") |> hd()

      cond do
        not String.starts_with?(type, "image/") -> {:error, {:not_an_image, type}}
        byte_size(body) > @max_bytes -> {:error, :too_large}
        true -> {:ok, "data:" <> type <> ";base64," <> Base.encode64(body)}
      end
    else
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── 1. Fetch ───────────────────────────────────────────────────────────────

  @doc false
  def fetch(url, redirects_left \\ @max_redirects)

  def fetch(_url, redirects_left) when redirects_left < 0, do: {:error, :too_many_redirects}

  def fetch(url, redirects_left) do
    with {:ok, uri} <- safe_uri(url) do
      req =
        Req.new(
          url: URI.to_string(uri),
          # Redirects are followed by hand so each hop gets the same address
          # check as the first — a public host redirecting to 127.0.0.1 is
          # the standard way around a naive guard.
          redirect: false,
          receive_timeout: @timeout_ms,
          max_retries: 0,
          headers: [
            {"accept", "text/html,application/xhtml+xml"},
            {"user-agent", "PhoenixKitBoards link preview"}
          ]
        )

      case Req.get(req) do
        {:ok, %{status: status, headers: headers}} when status in 300..399 ->
          follow_redirect(headers, uri, redirects_left)

        {:ok, %{status: 200, headers: headers, body: body}} ->
          usable_page(headers, body, uri)

        {:ok, %{status: status}} ->
          {:error, {:http_status, status}}

        {:error, reason} ->
          {:error, {:unreachable, reason}}
      end
    end
  end

  defp usable_page(headers, body, uri) do
    with :ok <- ensure_html(headers),
         :ok <- ensure_small_enough(body) do
      {:ok, to_string(body), URI.to_string(uri)}
    end
  end

  defp follow_redirect(headers, from, redirects_left) do
    case header(headers, "location") do
      nil -> {:error, :redirect_without_location}
      loc -> from |> URI.merge(loc) |> URI.to_string() |> fetch(redirects_left - 1)
    end
  end

  defp ensure_html(headers) do
    type = headers |> header("content-type") |> to_string()

    if String.contains?(type, "html"),
      do: :ok,
      else: {:error, {:not_html, type}}
  end

  defp ensure_small_enough(body) when is_binary(body) do
    if byte_size(body) <= @max_bytes, do: :ok, else: {:error, :too_large}
  end

  defp ensure_small_enough(_body), do: {:error, :unexpected_body}

  defp header(headers, name) do
    case headers do
      %{} = map -> map |> Map.get(name, []) |> List.wrap() |> List.first()
      list when is_list(list) -> for({^name, v} <- list, do: v) |> List.first()
      _ -> nil
    end
  end

  # ── SSRF guard ─────────────────────────────────────────────────────────────

  @doc false
  def safe_uri(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, {:bad_scheme, uri.scheme}}
      is_nil(uri.host) or uri.host == "" -> {:error, :no_host}
      true -> check_addresses(uri)
    end
  end

  defp check_addresses(uri) do
    case :inet.getaddrs(String.to_charlist(uri.host), :inet) do
      {:ok, addrs} ->
        # EVERY address, not just the first: a host that resolves to one
        # public and one private address would otherwise slip through.
        if Enum.any?(addrs, &private_address?/1),
          do: {:error, {:blocked_address, uri.host}},
          else: {:ok, uri}

      {:error, reason} ->
        {:error, {:dns, reason}}
    end
  end

  @doc false
  def private_address?({127, _, _, _}), do: true
  def private_address?({10, _, _, _}), do: true
  def private_address?({192, 168, _, _}), do: true
  def private_address?({169, 254, _, _}), do: true
  def private_address?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  # Carrier-grade NAT — 100.64.0.0/10.
  def private_address?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  def private_address?({0, _, _, _}), do: true
  def private_address?(_), do: false

  # ── 2. Metadata ────────────────────────────────────────────────────────────

  @doc false
  def metadata(html, url) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        title = og(doc, "og:title") || text_of(doc, "title") || host_of(url)

        {:ok,
         %{
           title: clip(title, 120),
           description: clip(og(doc, "og:description") || "", 200),
           site: og(doc, "og:site_name") || host_of(url),
           image: absolute(og(doc, "og:image"), url),
           url: url
         }}

      _ ->
        {:error, :unparseable}
    end
  end

  defp og(doc, property) do
    doc
    |> Floki.attribute(~s(meta[property="#{property}"]), "content")
    |> List.first()
    |> presence()
  end

  defp text_of(doc, selector) do
    doc |> Floki.find(selector) |> Floki.text() |> String.trim() |> presence()
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(s) when is_binary(s), do: String.trim(s) |> then(&if &1 == "", do: nil, else: &1)

  defp host_of(url), do: URI.parse(url).host || url

  defp clip(s, max) when is_binary(s) do
    if String.length(s) > max, do: String.slice(s, 0, max) <> "…", else: s
  end

  defp clip(_, _), do: ""

  # Relative `og:image` paths are common; resolve against the page.
  defp absolute(nil, _base), do: nil
  defp absolute(src, base), do: base |> URI.merge(src) |> URI.to_string()

  # ── 3. Scene ───────────────────────────────────────────────────────────────

  @doc false
  def scene(meta) do
    Scene.new(
      width: @card_w,
      height: @card_h,
      background: Scene.solid("#ffffff")
    )
    |> maybe_hero(meta)
    |> Scene.add(
      Scene.text("title",
        box: %{x: 28, y: @image_h + 26, w: @card_w - 56, h: 110},
        value: meta.title,
        size: 30,
        weight: 700,
        fill: Scene.solid("#111827")
      )
    )
    |> Scene.add(
      Scene.text("site",
        box: %{x: 28, y: @card_h - 58, w: @card_w - 56, h: 34},
        value: meta.site,
        size: 22,
        weight: 500,
        fill: Scene.solid("#6b7280")
      )
    )
  end

  # No `og:image` is the common case on plain pages, so the card drops the
  # hero band and gives the whole face to the title rather than reserving a
  # blank rectangle for a picture that doesn't exist.
  defp maybe_hero(scene, %{image: nil}), do: scene

  defp maybe_hero(scene, %{image: src}) do
    Scene.add(
      scene,
      Scene.image("hero",
        box: %{x: 0, y: 0, w: @card_w, h: @image_h},
        value: src,
        fit: :cover
      )
    )
  end

  # ── 4. Render ──────────────────────────────────────────────────────────────

  @doc false
  def svg(scene), do: OpenFresco.render_svg(scene, %{})
end
