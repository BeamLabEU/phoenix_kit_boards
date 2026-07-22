defmodule PhoenixKitBoards.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      pk_dep(:phoenix_kit, "~> 1.7"),
      {:phoenix_live_view, "~> 1.1"},

      # The infinite-canvas engine + annotation layer. Constraints match
      # PhoenixKit core so the host's resolution is never in conflict; the
      # host already loads their JS + hooks (the media annotation feature).
      pk_dep(:fresco, "~> 0.6"),
      pk_dep(:etcher, "~> 0.7"),
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
      source_ref: "v#{@version}"
    ]
  end
end
