defmodule PhoenixKitBoards.RuntimeHooksTest do
  @moduledoc """
  The markup that delivers this module's hooks.

  It has to match what LiveView looks for exactly — a
  `script[data-phx-runtime-hook="Name"]` and a `window.phx_hook_Name` — because
  a mismatch is silent: the board renders, local edits save, and only the
  inbound half of collaboration is missing. That is the failure this whole
  mechanism exists to prevent, so it is worth pinning literally.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.AssetController
  alias PhoenixKitBoards.Web.RuntimeHooks

  defp render(assigns \\ %{nonce: nil}) do
    assigns
    |> Map.put(:__changed__, nil)
    |> RuntimeHooks.scripts()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  describe "the emitted scripts" do
    test "carry the attribute LiveView queries for" do
      html = render()

      # `maybeRuntimeHook` does
      # `document.querySelector('script[data-phx-runtime-hook="NAME"]')`.
      for hook <- ~w(BoardSync BoardCursors) do
        assert html =~ ~s(data-phx-runtime-hook="#{hook}")
      end
    end

    test "define the global LiveView then calls" do
      html = render()

      # `window["phx_hook_" + name]`, and it must be a function.
      for hook <- ~w(BoardSync BoardCursors) do
        assert html =~ ~s(window["phx_hook_#{hook}"])
      end
    end

    test "name every hook the board actually uses" do
      # A hook rendered on the page but missing here would take collaboration
      # down without a word, which is exactly the bug this replaced.
      board = File.read!("lib/phoenix_kit_boards/web/board_live.ex")

      used =
        Regex.scan(~r/phx-hook="([A-Za-z]+)"/, board)
        |> Enum.map(fn [_, name] -> name end)
        |> Enum.uniq()

      html = render()

      for hook <- used do
        assert html =~ ~s(data-phx-runtime-hook="#{hook}"),
               "#{hook} is used on the board but not delivered"
      end
    end

    test "the body is not HTML-escaped" do
      html = render()

      # The JS contains quotes, `&&`, `<` and `!==`. Escaped, it is a syntax
      # error the browser reports only in the console.
      refute html =~ "&quot;"
      refute html =~ "&amp;"
      assert html =~ ~s(typeof hook[callback] !== "function")
    end

    test "nothing inside closes the tag early" do
      # A literal `</script>` in the body would end the tag and dump the rest
      # as page text.
      assert render() |> String.split("</script>") |> length() == 3
    end
  end

  describe "the bundle URL" do
    test "carries the content digest" do
      # So the response can be cached indefinitely and still be replaced the
      # moment the module is upgraded.
      assert RuntimeHooks.bundle_url() =~ "?v=#{AssetController.digest()}"
    end

    test "goes through the prefix helper rather than being hardcoded" do
      # `Routes.path/1` applies the host's URL prefix and locale; a hardcoded
      # path 404s on any install that sets one.
      assert RuntimeHooks.bundle_url() =~ "/admin/boards/assets/hooks.js"
      refute String.starts_with?(RuntimeHooks.bundle_url(), "/admin/")
    end

    test "the digest is stable and content-derived" do
      assert AssetController.digest() == AssetController.digest()
      assert String.match?(AssetController.digest(), ~r/\A[0-9a-f]{16}\z/)
    end
  end

  describe "the CSP nonce" do
    test "is absent unless the host supplies one" do
      # An empty `nonce=""` is worse than none: under a CSP it matches nothing
      # and the script is blocked.
      #
      # Scoped to the opening tags rather than the whole render: the body is
      # 4 KB of JavaScript that is free to mention the word, and matching
      # against all of it fails on a comment.
      for tag <- Regex.scan(~r/<script[^>]*>/, render(%{nonce: nil})) do
        refute hd(tag) =~ "nonce="
      end
    end

    test "is carried through when it is" do
      assert render(%{nonce: "r4nd0m"}) =~ ~s(nonce="r4nd0m")
    end
  end
end
