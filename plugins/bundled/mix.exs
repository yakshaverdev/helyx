defmodule Helyx.Plugins.MixProject do
  use Mix.Project

  def project do
    [
      app: :helyx_plugins,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The test helpers in test/support call ExUnit.Assertions; :ex_unit is
      # not in the default PLT.
      dialyzer: [plt_add_apps: [:ex_unit]] ++ dialyzer_paths(:helyx_plugins)
    ]
  end

  # A change to a path dependency never triggers a PLT check, so the path
  # dependencies stay out of the PLT and their beams are analyzed on each
  # run. The projects run Dialyzer in parallel, and Dialyxir writes a core
  # PLT with no lock, so each project has its own core PLT folder.
  defp dialyzer_paths(app) do
    path_deps = for {dep, opts} <- deps(), is_list(opts), opts[:path], do: dep

    [
      plt_core_path: Path.join(Mix.Utils.mix_home(), "dialyxir/#{app}"),
      plt_ignore_apps: path_deps,
      paths: for(a <- [app | path_deps], do: "_build/#{Mix.env()}/lib/#{a}/ebin")
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # The root's test helpers that need only Core, shared so that each has
  # one copy.
  defp elixirc_paths(:test),
    do: ["lib", "test/support", Path.expand("../../test/support/shared", __DIR__)]

  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:helyx, path: "../.."},
      {:req, "~> 0.5"},
      # Optional: a Rust NIF that only the TUI needs. Helyx.TUI is defined
      # only when it is loaded; a product that wants the TUI lists it (ADR 0005).
      {:ex_ratatui, "~> 0.14", optional: true},
      {:plug, "~> 1.16", only: :test},
      {:stream_data, "~> 1.2", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
