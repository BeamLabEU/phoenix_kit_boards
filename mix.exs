defmodule PhoenixKitBoards.MixProject do
  use Mix.Project

  @version "0.8.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_boards"

  def project do
    [
      app: :phoenix_kit_boards,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Collaborative infinite-canvas boards for PhoenixKit — create boards in the admin, draw/write/place images together in real time, persisted to the database.",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit, :fresco, :etcher]],
      name: "PhoenixKitBoards",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    # `:phoenix_kit` in extra_applications is REQUIRED for ModuleDiscovery to
    # find this module's `.beam` at host startup.
    [
      extra_applications: [:logger, :gettext, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit resolves from Hex by default; export PHOENIX_KIT_PATH=../phoenix_kit
  # for cross-repo work against a local checkout. Unset => the published pin.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # Floor 3.6.0. 3.5.0 is the ecosystem-wide minimum core, but it pins
      # `fresco ~> 0.15.0` / `etcher ~> 0.24.0`, which cannot sit next to the
      # fresco 0.16 / etcher 0.25 this module needs below. A floor that admits
      # it promises a combination no host can resolve. 3.6.0 is the first core
      # that allows them, and it serves etcher 0.26's JS, which the laser
      # measure needs. The ceiling is open through core 3.x. The core APIs
      # this module calls (`SchemaPrefix`, `Storage.ResourceFolders`,
      # `Scope.can?/2`, ...) are unguarded, so a core without one is a compile
      # or runtime error in the host.
      pk_dep(:phoenix_kit, ">= 3.6.0 and < 4.0.0"),
      {:phoenix_live_view, "~> 1.1"},
      # The label and description of `boards.manage` in the admin permissions
      # matrix are translated through this module's own backend.
      {:gettext, "~> 1.0"},

      # The infinite-canvas engine + annotation layer. The host already loads
      # their JS + hooks (the media annotation feature), so these constraints
      # exist to agree with PhoenixKit core rather than to pull anything new.
      #
      # Both are deliberately tighter than core's, because this module calls
      # things core never does and an older release would degrade rather than
      # fail — which is the worst shape for a missing dependency to take.
      # Narrower is still compatible: a two-part `~>` runs to the next major,
      # so core admits everything this asks for.
      #
      # fresco 0.11: `setGridVisible` (the background-dots preference), and
      # the exemption that stops the canvas cancelling `dragstart` over an
      # overlay — without it the toolbar's customise dialog cannot be dragged.
      #
      # etcher 0.11: `onShapesMoving` / `applyShapesMoving`, which is how a
      # peer's drag is visible while it happens rather than only once they let
      # go, and `toolBadge`, which is how a cursor shows what its owner is
      # holding. All three are called through `typeof` guards, so an older
      # etcher loses live drags and tool cursors silently — hence pinning
      # rather than relying on the guard. 0.12 is additive on those APIs; the
      # lock tracks it, the constraint does not need to move.
      #
      # fresco 0.13.1 is the floor for two fingers. A board stamps
      # `data-fresco-no-capture` on the drawing overlay, and until 0.13.1 the
      # viewer took that to mean it should ignore the finger entirely — so a
      # second finger had nothing to pinch against and fed the stroke
      # instead, which on a phone is a line whipping between two fingers.
      # Written as a `>=` rather than `~> 0.13`, which would admit 0.13.0 and
      # lose it silently.
      #
      # etcher 0.18 is the floor for live drawing: `onDrawing`,
      # `applyDrawing` and `applyDrawingEnd`, which is how a peer watches a
      # stroke appear rather than waiting out the length of it. Guarded by
      # `typeof` like the drag APIs above, and pinned for the same reason —
      # an older etcher loses it without saying so.
      #
      # fresco 0.15 and etcher 0.23 are the current floors: the releases core
      # 3.0 itself requires (`~> 0.15.0` / `~> 0.23.0`), so a host can never
      # resolve anything older next to it, and the board gets what came with
      # them — the selection frame that scales and turns a group or a drawn
      # stroke, a text box worked on while it is typed into, live size
      # samples beside the panel's thickness and size controls, and the
      # caret placed where a double-click lands.
      #
      # fresco 0.16 and etcher 0.25 are the floors now. The board page passes
      # fresco's `pdf_export`, `nav_style: :bar`, `nav_reverse` and
      # `actual_size`, and the widget's "Export as PDF" calls
      # `handle.exportPdf`; the shapes reach the PDF through fresco's export
      # layers, which etcher 0.25 fills, and the widget waits on
      # `Etcher.layerFor(id).isReady()` (0.25). The page also asks etcher for
      # `nav_buttons: [:modes]`, the View | Annotate switch. On older ones the
      # host's compile warns about the attributes and the export comes out
      # without the drawing.
      #
      # fresco 0.17 and etcher 0.28 are the floors for offline boards
      # (`config :phoenix_kit, offline_annotations: true`): the board passes
      # etcher's `offline` and `offline_sw`, its saves answer etcher's
      # `saved: false` contract, and the page is rebuilt with no connection
      # from the copy of the canvas element fresco 0.17 keeps. Etcher 0.26
      # (the laser measure, `:measure` in `tools/0`) and 0.27 (the placing
      # loupe) come with it. On older ones the host's compile warns about the
      # attributes, and a board opened offline stays a spinner.
      pk_dep(:fresco, ">= 0.17.0 and < 1.0.0"),
      pk_dep(:etcher, "~> 0.28"),

      # Link previews: fetch the page (req), read its OpenGraph tags (floki),
      # draw the card (open_fresco). Cards are emitted as SVG and rasterized
      # by the browser, so the host needs no NIF or rasterizer executable.
      {:req, "~> 0.5"},
      {:floki, ">= 0.34.0"},
      pk_dep(:open_fresco, "~> 0.2"),
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # priv/ ships the collab JS hook bundle (declared via js_sources/0).
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitBoards",
      # Tags in this repo are v-prefixed (`git tag -a v0.1.0`), matching phoenix_kit
      # core and the rest of the umbrella. Tagging a bare version number instead
      # would 404 every HexDocs source link — keep the two in step.
      source_ref: "v#{@version}"
    ]
  end
end
