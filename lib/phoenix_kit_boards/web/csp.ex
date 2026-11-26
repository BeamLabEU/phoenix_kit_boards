defmodule PhoenixKitBoards.Web.CSP do
  @moduledoc """
  The host's Content-Security-Policy nonce for the module's inline scripts
  (the runtime hooks of `RuntimeHooks` and `BoardsPanel`, the offline loader
  of `BoardLive`).

  Core keeps the page's nonces in `PhoenixKitWeb.CSP`. The core versions this
  module supports include ones without it, so the call is feature-detected:
  on such a core `nonce/1` is `nil` and HEEx renders no attribute, as before.

  A nonce the host passes itself (`script_nonce` of the panel,
  `:script_csp_nonce` of the board page, `nonce` of `RuntimeHooks.scripts/1`)
  wins: `script_nonce/1` is that value, else what core knows.
  """

  # Absent from the cores below the first release with CSP nonces, so it is
  # only ever called after the check: the compiler is told not to
  # look for it.
  @compile {:no_warn_undefined, PhoenixKitWeb.CSP}
  @core PhoenixKitWeb.CSP

  @doc """
  The nonce of the current page for `kind`, or `nil` when the host set none
  or core cannot tell.
  """
  @spec nonce(:script | :style) :: String.t() | nil
  def nonce(kind) when kind in [:script, :style] do
    if Code.ensure_loaded?(@core) and function_exported?(@core, :nonce, 1) do
      case core().nonce(kind) do
        nonce when is_binary(nonce) and nonce != "" -> nonce
        _ -> nil
      end
    end
  end

  defp core, do: @core

  @doc """
  The script nonce to render: the one the host passed, else the page's.

  An empty string counts as none: `nonce=""` matches nothing under a policy.
  """
  @spec script_nonce(term()) :: String.t() | nil
  def script_nonce(given) when is_binary(given) and given != "", do: given
  def script_nonce(_given), do: nonce(:script)
end
