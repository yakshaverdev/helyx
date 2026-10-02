defmodule Helyx.MixProject do
  use Mix.Project

  def project do
    [
      app: :helyx,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      # The shared test helpers in test/support call ExUnit.Assertions;
      # :ex_unit is not in the default PLT. The projects run Dialyzer in
      # parallel, and Dialyxir writes a core PLT with no lock, so each
      # project has its own core PLT folder.
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_core_path: Path.join(Mix.Utils.mix_home(), "dialyxir/helyx")
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [precommit: &precommit/1]
  end

  # Every project fetches, formats, and compiles, then runs its checks in
  # parallel; the projects run in parallel too (#295). Each step is its own
  # `mix` process with its own Mix state, and each project has its own
  # `_build`, so no two steps write the same files. deps.get runs first in
  # every project, so a fresh worktree or a rebase that brings a new
  # project needs no manual fetch. --check-locked makes a lock file that
  # lacks an entry, or holds a version the requirement rejects, fail the
  # run instead of being rewritten by it. Credo covers plugin and app
  # sources from the root via .credo.exs. Dialyzer cannot: they depend on
  # the root, not the reverse, so each project runs its own. The prepare
  # step compiled, and a compile in Dialyzer would wait for the build lock
  # that the test step holds. The tests wait on timers, so the static checks
  # run at a lower priority and leave the CPU to them.
  defp precommit(_args) do
    prepare = "mix do deps.get --check-locked + format + compile --warnings-as-errors"
    checks = ["nice mix dialyzer --no-compile", "mix test"]

    projects =
      [{".", ["nice mix credo --strict" | checks]}] ++ Enum.map(projects(), &{&1, checks})

    results =
      projects
      |> parallel(fn {dir, checks} ->
        case run(dir, prepare) do
          {_, 0} = prepared -> [prepared | parallel(checks, &run(dir, &1))]
          failed -> [failed]
        end
      end)
      |> Enum.concat()

    failed = for {name, status} <- results, status != 0, do: name
    if failed != [], do: Mix.raise("precommit failed: " <> Enum.join(failed, ", "))
  end

  # No glob and no command string: a glob character in the checkout path or a
  # quote in a directory name made earlier forms pass while skipping a project.
  defp projects do
    for parent <- ["plugins", "apps"],
        root = Path.join(__DIR__, parent),
        File.dir?(root),
        name <- Enum.sort(File.ls!(root)),
        dir = Path.join(root, name),
        File.regular?(Path.join(dir, "mix.exs")),
        do: Path.relative_to(dir, __DIR__)
  end

  defp parallel(items, fun) do
    items
    |> Task.async_stream(fun, timeout: :infinity, max_concurrency: length(items))
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp run(dir, step) do
    [command | argv] = OptionParser.split(step)

    {micros, {output, status}} =
      :timer.tc(fn ->
        System.cmd(command, argv,
          cd: Path.join(__DIR__, dir),
          # A child that inherits MIX_EXS loads this project again and
          # recurses.
          env: [{"MIX_ENV", "test"}, {"MIX_EXS", nil}],
          stderr_to_stdout: true
        )
      end)

    name = "#{dir}: #{step} (#{Float.round(micros / 1_000_000, 1)} s)"
    # A step prints when it ends, so a step that hangs leaves the output of
    # the others. One write keeps the output below its own line, and the
    # last such line above an error names the project and the step.
    IO.write(["==> precommit ", name, "\n", output])
    {name, status}
  end
end
