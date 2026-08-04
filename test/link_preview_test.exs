defmodule PhoenixKitBoards.LinkPreviewTest do
  @moduledoc """
  The unfurl fetches a URL a user pasted, from inside the network the server
  lives in, so `safe_uri/1` is the only thing between "link preview" and
  "read the cloud instance's credentials". Every hop of both fetchers — the
  page and its hero image — goes through it, so these pin what it refuses.

  The end of that path can't be exercised here: a test HTTP server would sit
  on 127.0.0.1, which is exactly what the guard blocks. What is testable is
  the decision itself, and the rendering that happens after it.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.LinkPreview

  describe "safe_uri/1 — scheme" do
    test "refuses anything that isn't http(s)" do
      assert {:error, {:bad_scheme, "file"}} = LinkPreview.safe_uri("file:///etc/passwd")
      assert {:error, {:bad_scheme, "ftp"}} = LinkPreview.safe_uri("ftp://example.com/x")
      assert {:error, {:bad_scheme, "javascript"}} = LinkPreview.safe_uri("javascript:alert(1)")
      assert {:error, {:bad_scheme, "data"}} = LinkPreview.safe_uri("data:text/html,<b>x</b>")
    end

    test "refuses a URL with no host" do
      assert {:error, :no_host} = LinkPreview.safe_uri("http://")
      assert {:error, {:bad_scheme, nil}} = LinkPreview.safe_uri("/just/a/path")
    end
  end

  describe "safe_uri/1 — addresses" do
    # Loopback and the private ranges, written the obvious way and written
    # the way somebody trying to get past a string check would write them.
    test "refuses loopback" do
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://127.0.0.1/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://127.1.2.3/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://localhost/")
    end

    test "refuses loopback spelled as an integer or in octal" do
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://2130706433/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://0177.0.0.1/")
    end

    # The reason this module has a guard at all.
    test "refuses the cloud metadata endpoint" do
      assert {:error, {:blocked_address, _}} =
               LinkPreview.safe_uri("http://169.254.169.254/latest/meta-data/")
    end

    test "refuses the RFC1918 ranges" do
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://10.1.2.3/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://192.168.1.1/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://172.16.0.1/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://172.31.255.254/")
    end

    test "refuses CGNAT and 0.0.0.0/8" do
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://100.64.0.1/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://0.0.0.0/")
    end

    test "refuses the reserved ranges" do
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://192.0.0.1/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://198.18.0.1/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://239.255.255.250/")
      assert {:error, {:blocked_address, _}} = LinkPreview.safe_uri("http://255.255.255.255/")
    end

    # An IPv6 literal resolves to nothing under an `:inet` lookup, so it is
    # refused rather than reaching a `::1` the checks above don't cover.
    # Fail-closed: IPv6-only hosts can't be previewed at all.
    test "refuses an IPv6 literal" do
      assert {:error, {:dns, _}} = LinkPreview.safe_uri("http://[::1]/")
    end
  end

  describe "private_address?/1" do
    test "allows an ordinary public address" do
      refute LinkPreview.private_address?({93, 184, 216, 34})
      refute LinkPreview.private_address?({8, 8, 8, 8})
    end

    # 172.16.0.0/12 stops at 172.31 — 172.15 and 172.32 are public.
    test "does not over-reach on the 172 range" do
      refute LinkPreview.private_address?({172, 15, 0, 1})
      refute LinkPreview.private_address?({172, 32, 0, 1})
      assert LinkPreview.private_address?({172, 16, 0, 1})
      assert LinkPreview.private_address?({172, 31, 0, 1})
    end

    # 100.64.0.0/10 stops at 100.127 — 100.63 and 100.128 are public.
    test "does not over-reach on the CGNAT range" do
      refute LinkPreview.private_address?({100, 63, 0, 1})
      refute LinkPreview.private_address?({100, 128, 0, 1})
      assert LinkPreview.private_address?({100, 64, 0, 1})
      assert LinkPreview.private_address?({100, 127, 0, 1})
    end

    test "covers multicast and the reserved top of the space" do
      assert LinkPreview.private_address?({224, 0, 0, 1})
      assert LinkPreview.private_address?({240, 0, 0, 1})
      assert LinkPreview.private_address?({255, 255, 255, 255})
      refute LinkPreview.private_address?({223, 255, 255, 255})
    end
  end

  describe "metadata/2" do
    test "prefers OpenGraph over the title element" do
      html = """
      <html><head>
        <meta property="og:title" content="The OG one">
        <meta property="og:site_name" content="Example">
        <title>The title element</title>
      </head><body></body></html>
      """

      assert {:ok, meta} = LinkPreview.metadata(html, "https://example.com/page")
      assert meta.title == "The OG one"
      assert meta.site == "Example"
    end

    test "falls back to the title element, then to the host" do
      assert {:ok, with_title} =
               LinkPreview.metadata(
                 "<html><head><title>Fallback</title></head></html>",
                 "https://example.com/p"
               )

      assert with_title.title == "Fallback"
      assert with_title.site == "example.com"

      assert {:ok, bare} = LinkPreview.metadata("<html></html>", "https://example.com/p")
      assert bare.title == "example.com"
    end

    test "resolves a relative og:image against the page" do
      html = ~s(<html><head><meta property="og:image" content="/img/hero.png"></head></html>)

      assert {:ok, meta} = LinkPreview.metadata(html, "https://example.com/a/b")
      assert meta.image == "https://example.com/img/hero.png"
    end

    test "clips a runaway title rather than carrying it onto the card" do
      html = "<html><head><title>#{String.duplicate("x", 500)}</title></head></html>"

      assert {:ok, meta} = LinkPreview.metadata(html, "https://example.com/p")
      assert String.length(meta.title) == 121
      assert String.ends_with?(meta.title, "…")
    end
  end

  describe "scene/1 + svg/1" do
    test "renders a card of the declared size" do
      meta = %{
        title: "Hello",
        description: "",
        site: "example.com",
        image: nil,
        url: "https://example.com"
      }

      svg = meta |> LinkPreview.scene() |> LinkPreview.svg()

      assert svg =~ ~s(width="640")
      assert svg =~ ~s(height="480")
      assert svg =~ "Hello"
    end

    # The title comes off somebody else's page and lands in an SVG the client
    # rasterises. open_fresco escapes it; this is the assertion that says so.
    test "escapes markup carried in from the fetched page" do
      meta = %{
        title: "</text><script>alert(1)</script>",
        description: "",
        site: "example.com",
        image: nil,
        url: "https://example.com"
      }

      svg = meta |> LinkPreview.scene() |> LinkPreview.svg()

      refute svg =~ "<script>"
      assert svg =~ "&lt;script&gt;"
    end
  end
end
