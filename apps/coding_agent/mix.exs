defmodule CodingAgent.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :coding_agent,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [helyx: &release/0],
      # The Mix task calls Mix.Task.run/1 and Mix.raise/1, and the shared
      # test helpers call ExUnit.Assertions; neither app is in the default
      # PLT.
      dialyzer: [plt_add_apps: [:mix, :ex_unit]] ++ dialyzer_paths(:coding_agent)
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

  # The root's test helpers that need only Core, shared so that each has
  # one copy.
  defp elixirc_paths(:test), do: ["lib", Path.expand("../../test/support/shared", __DIR__)]
  defp elixirc_paths(_), do: ["lib"]

  def cli, do: [preferred_envs: ["helyx.install": :prod]]

  # A function, so git runs only when a release builds. The version names
  # the commit of the build, and `helyx --version` prints it.
  defp release do
    git = ~w(describe --always --abbrev=7 --dirty=-dirty --exclude=*)

    case System.cmd("git", git, stderr_to_stdout: true) do
      {commit, 0} -> [version: "#{@version}+#{String.trim(commit)}"]
      {text, _} -> Mix.raise("the helyx release needs a git checkout: #{String.trim(text)}")
    end
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
end
