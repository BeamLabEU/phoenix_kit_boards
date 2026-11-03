defmodule PhoenixKitBoards.ComponentsAttrsTest do
  @moduledoc """
  The function component is what the docs tell a host to write, and it declares
  its attributes: one it does not declare is a compile warning in the HOST's
  template — a failed build under `--warnings-as-errors` — even though the
  value still reaches the panel. `paste` and `script_nonce` shipped that way.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitBoards.Web.{BoardsPanel, Components}

  defp documented_attributes do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(BoardsPanel)
    [_, section] = String.split(doc, "## Attributes", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)

    for [_, name] <- Regex.scan(~r/^\s*\* `(\w+)`/m, section), do: String.to_atom(name)
  end

  test "boards_panel/1 declares every attribute the panel documents" do
    declared = Enum.map(Components.__components__().boards_panel.attrs, & &1.name)
    documented = documented_attributes()

    assert :paste in documented and :script_nonce in documented
    assert documented -- declared == []
  end
end
