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

  The hero image is fetched the same way, by the same walk — an `og:image`
  is as attacker-controlled as the page, and a hero that redirects into the
  private range would reach it just as surely.

  The rest is proportion: a 12s budget for the whole unfurl, a 2MB cap
  enforced *as the body streams* rather than after it has all arrived, and
  HTML only. A link preview is a nicety, and none of it is worth a hung
  request or a page of arbitrary size buffered into memory.

  ## Known limit

  The guard resolves the host and then asks `Req` for the same host by name,
  so a DNS answer that changes between the two — rebinding — is not caught.
  Closing that means pinning the checked address and carrying the original
  host through as a header and SNI name, which is a lot of machinery for a
  surface only an admin can reach. It is a deliberate omission, not an
  oversight.
  """

  require Logger

  alias OpenFresco.Scene

  @timeout_ms 10_000
  @max_bytes 2 * 1024 * 1024
  @max_redirects 3

  # One wall-clock budget for the whole unfurl — page, its redirects, and the
  # hero. `unfurl/1` is called straight from the LiveView's `handle_event/3`,
  # which has to answer and so cannot hand the work off, and a blocked
  # LiveView processes nothing else meanwhile: not the user's own edits, not
  # peers' deltas, not cursors. Per-request timeouts alone compound — four
  # hops plus a hero is the better part of a minute — so the deadline is
  # shared and each request gets whatever is left of it.
  @budget_ms 12_000

  # Card proportions, in the same units the Scene is laid out in. The hero
  # takes about two thirds and the rest is the footer, which is where the
  # title and site sit — the arrangement every link preview settled on.
  @card_w 640
  @card_h 480
  @image_h 330
  @radius 20
  @footer_bg "#6e6e73"

  @doc """
  Unfurl `url` into `{:ok, %{svg: binary, width: integer, height: integer}}`.

  Any failure — unreachable, not HTML, no usable metadata — comes back as
  `{:error, reason}` and is the caller's cue to leave the pasted link as text.
  """
  @spec unfurl(String.t()) :: {:ok, map()} | {:error, term()}
  def unfurl(url) when is_binary(url) do
    deadline = deadline(@budget_ms)

    with {:ok, html, final_url} <- fetch(url, @max_redirects, deadline),
         {:ok, meta} <- metadata(html, final_url) do
      svg = meta |> inline_hero(deadline) |> scene() |> svg()
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
  defp inline_hero(%{image: nil} = meta, _deadline), do: meta

  defp inline_hero(%{image: src} = meta, deadline) do
    case fetch_image(src, @max_redirects, deadline) do
      {:ok, data_url} ->
        %{meta | image: data_url}

      {:error, reason} ->
        Logger.debug("[boards] link preview hero dropped (#{inspect(reason)}): #{inspect(src)}")
        %{meta | image: nil}
    end
  end

  # The hero goes through `walk/3` exactly like the page does. An `og:image`
  # is attacker-controlled precisely as much as the page it was read from, so
  # there is no version of this that gets to be the relaxed one.
  defp fetch_image(src, redirects_left, deadline) do
    walk(src, redirects_left, %{
      deadline: deadline,
      req_opts: [],
      on_ok: fn headers, body, _uri -> inline_image(headers, body) end
    })
  end

  defp inline_image(_headers, :too_large), do: {:error, :too_large}

  defp inline_image(headers, body) when is_binary(body) do
    type = headers |> header("content-type") |> to_string() |> String.split(";") |> hd()

    if String.starts_with?(type, "image/"),
      do: {:ok, "data:" <> type <> ";base64," <> Base.encode64(body)},
      else: {:error, {:not_an_image, type}}
  end

  defp inline_image(_headers, _body), do: {:error, :unexpected_body}

  # ── 1. Fetch ───────────────────────────────────────────────────────────────

  @doc false
  def fetch(url, redirects_left \\ @max_redirects, deadline \\ nil)

  def fetch(url, redirects_left, nil), do: fetch(url, redirects_left, deadline(@budget_ms))

  def fetch(url, redirects_left, deadline) do
    walk(url, redirects_left, %{
      deadline: deadline,
      req_opts: [
        headers: [
          {"accept", "text/html,application/xhtml+xml"},
          {"user-agent", "PhoenixKitBoards link preview"}
        ]
      ],
      on_ok: &usable_page/3
    })
  end

  # ── The guarded walk ───────────────────────────────────────────────────────
  #
  # One implementation, used by both the page fetch and the hero fetch. They
  # differ only in the headers they send and what they do with a 200, and
  # `opts` carries exactly that — everything load-bearing is here.
  #
  # That is deliberate rather than tidy. Redirects are followed by hand so
  # every hop gets the same address check as the first, because a public host
  # redirecting to 127.0.0.1 is the standard way around a naive guard. When
  # the two fetchers were written out separately, one of them was given
  # `redirect: false` and the other was not, and the one that was not checked
  # the first address and then followed a `Location` anywhere it was pointed.
  # There is one of these so there is nothing to keep in sync.
  defp walk(_url, redirects_left, _opts) when redirects_left < 0,
    do: {:error, :too_many_redirects}

  defp walk(url, redirects_left, opts) do
    with {:ok, uri} <- safe_uri(url),
         {:ok, timeout} <- time_left(opts.deadline) do
      req =
        Req.new(
          [
            url: URI.to_string(uri),
            redirect: false,
            receive_timeout: timeout,
            max_retries: 0,
            into: capped_into()
          ] ++ opts.req_opts
        )

      req |> Req.get() |> dispatch(uri, redirects_left, opts)
    end
  end

  defp dispatch({:ok, %{status: status, headers: headers}}, uri, redirects_left, opts)
       when status in 300..399 do
    with {:ok, target} <- redirect_target(headers, uri),
         do: walk(target, redirects_left - 1, opts)
  end

  defp dispatch({:ok, %{status: 200, headers: headers, body: body}}, uri, _redirects_left, opts),
    do: opts.on_ok.(headers, body, uri)

  defp dispatch({:ok, %{status: status}}, _uri, _redirects_left, _opts),
    do: {:error, {:http_status, status}}

  defp dispatch({:error, reason}, _uri, _redirects_left, _opts),
    do: {:error, {:unreachable, reason}}

  # Cap the body as it arrives instead of after the fact. Left to itself Req
  # reads the whole response into memory and only then hands it over, so a
  # URL serving gigabytes costs gigabytes before anything gets to reject it.
  # Halting mid-stream drops the connection at the limit.
  #
  # Streaming also turns Req's decompression off, which is why nothing here
  # asks for it: the `compressed` step only sets `accept-encoding` when the
  # body is buffered, so a server has no reason to send an encoding that
  # would then arrive undecoded.
  defp capped_into do
    fn {:data, chunk}, {req, resp} ->
      body = resp.body <> chunk

      if byte_size(body) > @max_bytes,
        do: {:halt, {req, %{resp | body: :too_large}}},
        else: {:cont, {req, %{resp | body: body}}}
    end
  end

  # ── Budget ─────────────────────────────────────────────────────────────────

  defp deadline(budget_ms), do: System.monotonic_time(:millisecond) + budget_ms

  defp time_left(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      left when left > 0 -> {:ok, min(left, @timeout_ms)}
      _ -> {:error, :timeout}
    end
  end

  defp usable_page(headers, body, uri) do
    with :ok <- ensure_html(headers),
         :ok <- ensure_small_enough(body) do
      {:ok, to_string(body), URI.to_string(uri)}
    end
  end

  defp redirect_target(headers, from) do
    case header(headers, "location") do
      nil -> {:error, :redirect_without_location}
      loc -> {:ok, from |> URI.merge(loc) |> URI.to_string()}
    end
  end

  defp ensure_html(headers) do
    type = headers |> header("content-type") |> to_string()

    if String.contains?(type, "html"),
      do: :ok,
      else: {:error, {:not_html, type}}
  end

  # The cap is enforced as the body streams (see `capped_into/0`); this is
  # where a stream halted at the limit becomes an error the caller reports.
  defp ensure_small_enough(:too_large), do: {:error, :too_large}
  defp ensure_small_enough(body) when is_binary(body), do: :ok
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
  # IETF protocol assignments — 192.0.0.0/24.
  def private_address?({192, 0, 0, _}), do: true
  # Benchmarking — 198.18.0.0/15.
  def private_address?({198, b, _, _}) when b >= 18 and b <= 19, do: true
  # Multicast (224.0.0.0/4) and the reserved 240.0.0.0/4, which takes the
  # 255.255.255.255 broadcast address with it. Neither is somewhere a link
  # preview has any business sending a request.
  def private_address?({a, _, _, _}) when a >= 224, do: true
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
    # No canvas background: the card is a rounded rect and the corners outside
    # it have to be transparent, or it renders as a rounded card pasted onto a
    # white square.
    Scene.new(width: @card_w, height: @card_h)
    |> Scene.add(
      Scene.shape("card",
        box: %{x: 0, y: 0, w: @card_w, h: @card_h},
        radius: @radius,
        fill: Scene.solid(@footer_bg)
      )
    )
    |> maybe_hero(meta)
    |> Scene.add(
      # Squares off the hero's rounded bottom corners and forms the footer in
      # one go. It stops short of the card's own bottom edge so the rounded
      # corners down there survive — same colour, so the seam is invisible.
      Scene.shape("footer",
        box: %{x: 0, y: @image_h - 20, w: @card_w, h: @card_h - @image_h - 4},
        radius: 0,
        fill: Scene.solid(@footer_bg)
      )
    )
    |> Scene.add(
      Scene.text("title",
        box: %{x: 32, y: @image_h + 16, w: @card_w - 64, h: 84},
        value: meta.title,
        size: 30,
        weight: 700,
        fill: Scene.solid("#ffffff")
      )
    )
    |> Scene.add(
      Scene.text("site",
        box: %{x: 32, y: @card_h - 62, w: @card_w - 64, h: 36},
        value: meta.site,
        size: 24,
        weight: 500,
        fill: Scene.solid("#d8d8dd")
      )
    )
  end

  # No `og:image` is the common case on plain pages. The card keeps its shape
  # — a link preview that changes size depending on whether the site set a
  # meta tag would be worse than one with a plain coloured head.
  defp maybe_hero(scene, %{image: nil}), do: scene

  defp maybe_hero(scene, %{image: src}) do
    Scene.add(
      scene,
      Scene.image("hero",
        box: %{x: 0, y: 0, w: @card_w, h: @image_h},
        value: src,
        fit: :cover,
        radius: @radius
      )
    )
  end

  # ── 4. Render ──────────────────────────────────────────────────────────────

  @doc false
  def svg(scene), do: OpenFresco.render_svg(scene, %{})
end
