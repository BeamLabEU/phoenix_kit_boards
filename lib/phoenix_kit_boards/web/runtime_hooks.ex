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
            // Forget the failure so a later mount can try again. Memoizing it
            // would turn one bad response — a blip, a restart mid-deploy —
            // into a tab that stays non-collaborative until it is reloaded,
            // and navigating between boards would never retry.
            window.__phoenixKitBoardsLoad = null;
            explain(SRC);
            resolve();
          };
          document.head.appendChild(el);
        });

        return window.__phoenixKitBoardsLoad;
      }

      // Say WHY, not just that it failed.
      //
      // A script element's error event carries no status, so the message alone
      // could not distinguish a 404 from a 403 from a login page — and a 403
      // from CSRF's cross-origin-script guard is exactly the sort of thing
      // that is obvious the moment you see the number and baffling until you
      // do. Refetching costs one request on a path that has already failed.
      function explain(src) {
        var base =
          "[phoenix_kit_boards] could not load " + src +
          "; this board will not be collaborative";

        if (typeof fetch !== "function") {
          console.error(base);
          return;
        }

        fetch(src, { credentials: "same-origin" })
          .then(function (response) {
            console.error(
              base + " (HTTP " + response.status + ")" +
                (response.status === 403
                  ? " — a 403 here is usually CSRF's cross-origin-script guard;" +
                    " the route must skip forgery protection"
                  : "")
            );
          })
          .catch(function () {
            console.error(base);
          });
      }

      function forward(ctx, callback) {
        load().then(function () {
          // A script that loads without defining anything is the failure this
          // whole mechanism exists to remove — the board renders, local edits
          // save, and only collaboration is missing, which reads as a broken
          // feature rather than a missing file. It happens if the request is
          // answered by something other than the bundle: an auth redirect
          // resolving to a login page, a proxy error page, a CSP that blocked
          // it. Say so once rather than leaving it to be discovered.
          if (!window.PhoenixKitBoardsHooks) {
            if (!window.__phoenixKitBoardsWarned) {
              window.__phoenixKitBoardsWarned = true;
              console.error(
                "[phoenix_kit_boards] " + SRC + " loaded but defined no hooks — " +
                  "this board will not be collaborative. Check that the URL returns " +
                  "the hook bundle rather than a redirect or an error page."
              );
            }
            return;
          }

          var hook = window.PhoenixKitBoardsHooks[NAME];
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
