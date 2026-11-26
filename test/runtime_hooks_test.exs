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

  # Absent from the cores below the first release with CSP nonces.
  @compile {:no_warn_undefined, PhoenixKitWeb.CSP}

  alias PhoenixKitBoards.Web.AssetController
  alias PhoenixKitBoards.Web.RuntimeHooks

  defp render(assigns \\ %{nonce: nil}) do
    assigns
    |> Map.put(:__changed__, nil)
    |> RuntimeHooks.scripts()
    |> Phoenix.LiveViewTest.rendered_to_string()
  end

  # Core keeps the page's nonces in the process: put them there the way a
  # LiveView's `on_mount` does, from a session — in a process of its own, so
  # nothing is left behind in this one.
  defp with_core_nonce(nonce, fun) do
    fn ->
      {:cont, _} =
        PhoenixKitWeb.CSP.on_mount(
          :default,
          %{},
          %{"phoenix_kit_csp_nonces" => %{"script" => nonce}},
          %Phoenix.LiveView.Socket{}
        )

      fun.()
    end
    |> Task.async()
    |> Task.await()
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

    # A host that tells core its nonce (`csp_nonce_assign_key`) passes nothing
    # here: the scripts take the page's nonce from core. Only a core with
    # `PhoenixKitWeb.CSP` can tell; on an older one there is still no attribute.
    test "falls back to the nonce core knows for the page" do
      if Code.ensure_loaded?(PhoenixKitWeb.CSP) do
        with_core_nonce("c0re", fn ->
          html = render(%{nonce: nil})

          for tag <- Regex.scan(~r/<script[^>]*>/, html), do: assert(hd(tag) =~ ~s(nonce="c0re"))
          # The bundle the shim loads inherits it too.
          assert html =~ ~s(var NONCE = "c0re";)

          # What the host passes still wins.
          assert render(%{nonce: "h0st"}) =~ ~s(nonce="h0st")
          refute render(%{nonce: "h0st"}) =~ "c0re"
        end)
      else
        assert PhoenixKitBoards.Web.CSP.nonce(:script) == nil
      end
    end

    test "an empty nonce from the host counts as none" do
      assert PhoenixKitBoards.Web.CSP.script_nonce("") == PhoenixKitBoards.Web.CSP.nonce(:script)
      assert PhoenixKitBoards.Web.CSP.script_nonce("abc") == "abc"
    end
  end
end
