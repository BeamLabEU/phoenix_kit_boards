defmodule PhoenixKitBoards.Web.RuntimeHooks do
  @moduledoc """
  Delivers this module's LiveView hooks without the host wiring anything.

  A hook used to have to be in the host's `LiveSocket` at construction time,
  which is why `js_sources/0` and core's `:phoenix_kit_js_sources` compiler
  exist. Since LiveView 1.1 that is no longer so: `getHookDefinition/1`
  resolves a name lazily, and its last resort is a `<script
  data-phx-runtime-hook="Name">` anywhere in the document, whose
  `window.phx_hook_Name()` returns the callbacks. LiveView re-creates such a
  script when it arrives in a patch, so this works on a board rendered over
  the socket rather than in the first HTML.

  The host's own registration still wins — `getHookDefinition` checks
  `liveSocket.hooks` before it looks for a runtime hook — so a host that does
  run the compiler is unaffected, and there is never a second copy.

  ## Why a shim rather than the bundle inline

  Inlining would be simpler, but it puts 40 KB of uncacheable script in every
  board page. Instead each hook resolves to a small object that forwards to
  the real one once `AssetController` has served the bundle. The forwarding is
  what the shape of LiveView's API forces: `getHookDefinition` is
  synchronous, so something has to be returned immediately, before the bundle
  can possibly have loaded.

  The load is shared by both hooks and by every element using them, so the
  bundle is requested once per page however many hooks mount.
  """
  use Phoenix.Component

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBoards.Web.AssetController

  @hooks ~w(BoardSync BoardCursors)

  @doc "Where the bundle is served from, digest included so it can be cached forever."
  def bundle_url, do: Routes.path("/admin/boards/assets/hooks.js?v=#{AssetController.digest()}")

  attr(:nonce, :string,
    default: nil,
    doc: """
    CSP nonce for the emitted scripts. Required only by hosts that enforce a
    Content-Security-Policy — without one those hosts would block the script
    and lose collaboration with nothing but a console warning to say why.
    """
  )

  @doc """
  The runtime-hook scripts. Render before any element that uses them.
  """
  def scripts(assigns) do
    src = bundle_url()
    assigns = assign(assigns, :hooks, Enum.map(@hooks, &{&1, body(&1, src)}))

    # `<%= %>`, not `{}`: HEEx treats the body of a `<script>` as literal text
    # and leaves `{...}` in the output untouched.
    ~H"""
    <script :for={{hook, body} <- @hooks} data-phx-runtime-hook={hook} nonce={@nonce}>
      <%= Phoenix.HTML.raw(body) %>
    </script>
    """
  end

  # Built here rather than templated so the JS is plain text with two values
  # substituted, both JSON-encoded — nothing in it depends on HEEx's rules for
  # what may appear inside a `<script>`.
  defp body(hook, src) do
    """
    window[#{Jason.encode!("phx_hook_" <> hook)}] = (function () {
      var NAME = #{Jason.encode!(hook)};
      var SRC = #{Jason.encode!(src)};

      // One request per page, shared by both hooks and by every element using
      // them, and reused across re-mounts.
      function load() {
        if (window.__phoenixKitBoardsLoad) return window.__phoenixKitBoardsLoad;

        window.__phoenixKitBoardsLoad = new Promise(function (resolve) {
          if (window.PhoenixKitBoardsHooks) return resolve();

          var el = document.createElement("script");
          el.src = SRC;
          // Resolved either way. A bundle that never arrives leaves the board
          // working on its own — which is where it was before any of this —
          // rather than leaving callbacks pending for the life of the page.
          el.onload = resolve;
          el.onerror = function () {
            console.error(
              "[phoenix_kit_boards] could not load " + SRC +
                "; this board will not be collaborative"
            );
            resolve();
          };
          document.head.appendChild(el);
        });

        return window.__phoenixKitBoardsLoad;
      }

      function forward(ctx, callback) {
        load().then(function () {
          var hook = (window.PhoenixKitBoardsHooks || {})[NAME];
          if (!hook || typeof hook[callback] !== "function") return;

          // The element can be gone before the bundle lands. Running `mounted`
          // then would attach listeners and timers nothing will ever tear
          // down, and `destroyed` would run against a hook that never set any
          // of it up.
          var state = ctx.__pkbState || {};
          if (callback === "destroyed" ? !state.mounted : state.destroyed) return;
          if (callback === "mounted") state.mounted = true;

          try {
            hook[callback].call(ctx);
          } catch (error) {
            console.error("[phoenix_kit_boards] " + NAME + "." + callback + " failed", error);
          }
        });
      }

      return function () {
        return {
          mounted: function () {
            this.__pkbState = { mounted: false, destroyed: false };
            forward(this, "mounted");
          },
          updated: function () { forward(this, "updated"); },
          disconnected: function () { forward(this, "disconnected"); },
          reconnected: function () { forward(this, "reconnected"); },
          destroyed: function () {
            if (this.__pkbState) this.__pkbState.destroyed = true;
            forward(this, "destroyed");
          }
        };
      };
    })();
    """
  end
end
