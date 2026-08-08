defmodule PhoenixKitBoards.MixProject do
  use Mix.Project

  @version "0.3.0"
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
      extra_applications: [:logger, :phoenix_kit]
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
      # 1.7.189, not a bare `~> 1.7`: `Board` does `use PhoenixKit.SchemaPrefix`
      # and the migration calls
      # `PhoenixKit.Migrations.Postgres.Helpers.uuid_v7_call/1` — both first
      # shipped in core 1.7.189, and neither is guarded. `~> 1.7` admits
      # 1.7.0, which resolves a core with no such module: a compile error in
      # the consumer's build, not a degraded feature. (`PhoenixKit.Module`
      # needs 1.7.46, `PubSubHelper` 1.7.28, `Dashboard.Tab` 1.7.21 — all
      # covered by the same floor.)
      pk_dep(:phoenix_kit, "~> 1.7.189"),
      {:phoenix_live_view, "~> 1.1"},

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
      # rather than relying on the guard.
      pk_dep(:fresco, "~> 0.11"),
      pk_dep(:etcher, "~> 0.11"),

      # Link previews: fetch the page (req), read its OpenGraph tags (floki),
      # draw the card (open_fresco). open_fresco emits SVG by itself and
      # needs a rasterizer for PNG — the HOST supplies that, either the
      # `{:resvg, "~> 0.5"}` NIF or a resvg / rsvg-convert / magick binary on
      # PATH. Without one an unfurl fails and a pasted link stays text, so
      # this is a soft requirement rather than a dependency here.
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
