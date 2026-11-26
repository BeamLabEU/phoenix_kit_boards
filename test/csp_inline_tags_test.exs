defmodule PhoenixKitBoards.CSPInlineTagsTest do
  @moduledoc """
  The module's markup works under a nonce Content-Security-Policy
  (`script-src 'self' 'nonce-…'`, see core's `guides/content-security-policy.md`):
  no inline event handler (no nonce covers an attribute), and no inline
  `<script>` / `<style>` without the host's nonce. Modelled on core's
  `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  # The module's own JS: the hook bundle `AssetController` serves, and the
  # three panel hooks `BoardsPanel` renders inline as runtime hooks.
  @bundles Path.wildcard("priv/static/assets/*.js")

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s
  @tag_opening ~r/<(script|style)\b[^>]*>/s

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces
  # around `=` for the events a browser knows (a bare `on\w+ =` would also
  # match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!("\\son[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]")
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  # Every inline tag takes a nonce, and the value goes through
  # `PhoenixKitBoards.Web.CSP.script_nonce/1`: what the host passed, else the
  # nonce core knows for the page (nil on a core without `PhoenixKitWeb.CSP`).
  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          source = File.read!(path),
          {opening, number} <- tag_openings(path),
          not String.contains?(opening, "src="),
          not (opening =~ "nonce={" and source =~ "CSP.script_nonce("),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce resolved by `PhoenixKitBoards.Web.CSP.script_nonce/1`:\n" <>
             Enum.join(offenders, "\n")
  end

  test "the scan sees the module's inline scripts" do
    for {path, count} <- [
          {"lib/phoenix_kit_boards/web/boards_panel.ex", 3},
          {"lib/phoenix_kit_boards/web/board_live.ex", 1},
          {"lib/phoenix_kit_boards/web/runtime_hooks.ex", 1}
        ] do
      assert length(tag_openings(path)) == count, path
    end
  end

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          handler?(line) or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding, " <>
             "`Phoenix.LiveView.JS` or a hook):\n" <> Enum.join(offenders, "\n")
  end

  test "the module's JS builds no markup with an inline event handler" do
    offenders =
      for file <- @bundles,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not (line =~ ~r{^\s*(//|\*)}),
          line =~ ~r/\son[a-z]+=\\?["']/ or line =~ ~r/javascript:/i,
          do: "#{file}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # A `<style>`/`<script>` created from JS is checked against the page's
  # policy like any other: it is stamped with the page's nonce
  # (`PhoenixKitInternals.adoptStyle`, when the core has it) before insertion,
  # and never written as a string for `innerHTML`, where a nonce is not applied.
  test "the module's JS creates no unstamped <style> or <script>" do
    offenders =
      for file <- @bundles,
          lines = file |> File.read!() |> String.split("\n"),
          {line, index} <- Enum.with_index(lines),
          not (line =~ ~r{^\s*(//|\*)}),
          problem = created_tag_problem(line, Enum.slice(lines, index + 1, 4)),
          do: "#{file}:#{index + 1} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "the handler pattern sees what it must and leaves Elixir alone" do
    for bad <- [
          ~s|<img onerror="this.remove()" />|,
          ~s|<input onfocus={@js} />|,
          ~s|<a onclick = 'go()'>|
        ],
        do: assert(handler?(bad))

    for fine <- [
          ~s|only = "x"|,
          ~s|<div phx-click="go" data-paste="on">|,
          ~s|on_mount = {A, :b}|,
          ~s|<.item_table only={@only} />|
        ],
        do: refute(handler?(fine))

    assert ~s|<a href="javascript:void(0)">| =~ @js_url
  end

  # Component attributes that start with "on" and are no event: `only={…}`.
  @not_events ~r/\sonly=/

  defp handler?(line), do: String.replace(line, @not_events, " ") =~ @handler

  defp created_tag_problem(line, next_lines) do
    cond do
      line =~ ~r/createElement\(["'](?:style|script)["']\)/ and
          not Enum.any?(next_lines, &(&1 =~ ~r/adoptStyle/)) ->
        "creates a <style>/<script> that is not stamped in the next lines"

      line =~ ~r/["'`]<(?:style|script)\b/ ->
        "builds a <style>/<script> tag as a string"

      true ->
        nil
    end
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept:
  # documentation, HEEx comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  # Lines of the file with `@moduledoc`/`@doc` heredocs blanked: a tag in
  # documentation is an example, not markup.
  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
