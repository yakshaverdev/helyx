defmodule CodingAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :coding_agent,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # The Mix task calls Mix.Task.run/1 and Mix.raise/1, and the shared
      # test helpers call ExUnit.Assertions; neither app is in the default
      # PLT.
      dialyzer: [plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  # The root's test helpers that need only Core, shared so that each has
  # one copy.
  defp elixirc_paths(:test), do: ["lib", Path.expand("../../test/support/shared", __DIR__)]
  defp elixirc_paths(_), do: ["lib"]

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:helyx, path: "../.."},
      {:helyx_plugins, path: "../../plugins/bundled"},
      # Optional in helyx_plugins; listing it here makes Helyx.TUI exist.
      {:ex_ratatui, "~> 0.14"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "deps.get --check-locked",
        "format",
        "compile --warnings-as-errors",
        "dialyzer --force-check",
        "test"
      ]
    ]
  end
end
