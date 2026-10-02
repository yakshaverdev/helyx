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
  # parallel. Preparation is serial because Hex writes one shared registry
  # cache without a lock (#296). Prepared projects check in parallel (#295).
  # Each step is its own `mix` process with its own Mix state. Each project
  # has its own `_build`, so no two steps write the same files. deps.get
  # runs first in every project, so a fresh worktree or a rebase that brings
  # a new project needs no manual fetch. --check-locked makes a lock file that
  # lacks an entry, or holds a version the requirement rejects, fail the
  # run instead of being rewritten by it. Credo covers plugin and app
  # sources from the root via .credo.exs. Dialyzer cannot: they depend on
  # the root, not the reverse, so each project runs its own. The prepare
  # step also checks the PLT: Dialyxir's PLT check calls compile even with
  # --no-compile, which can rewrite protocols while tests read them (#296).
  # --no-check skips only that completed check, not the analysis. The tests
  # wait on timers, so the static checks run at a lower priority.
  defp precommit(_args) do
    # No preparation in this checkout may rewrite _build while earlier checks read it.
    # The key is the directory identity, not the path: a MIX_EXS alias gives another __DIR__.
    stat = File.stat!(__DIR__)
    key = "helyx:precommit:#{stat.major_device}:#{stat.inode}"
    Mix.Sync.Lock.with_lock(key, &run_precommit/0)
  end

  defp run_precommit do
    prepare =
      "mix do deps.get --check-locked + format + compile --warnings-as-errors + dialyzer --plt"

    checks = [
      "nice mix do loadpaths --no-deps-check + dialyzer --no-compile --no-check",
      "mix test --no-compile --no-deps-check"
    ]

    projects =
      [{".", ["nice mix do loadpaths --no-deps-check + credo --strict" | checks]}] ++
        Enum.map(projects(), &{&1, checks})

    results =
      projects
      |> Enum.map(fn {dir, checks} ->
        # Mix's OS-process lock also protects other worktrees using this runner.
        case Mix.Sync.Lock.with_lock("helyx:hex-registry", fn -> run(dir, prepare) end) do
          {_, 0} = prepared -> Task.async(fn -> [prepared | parallel(checks, &run(dir, &1))] end)
          failed -> Task.completed([failed])
        end
      end)
      |> Enum.flat_map(&Task.await(&1, :infinity))

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
          env: [
            {"MIX_ENV", "test"},
            {"MIX_EXS", nil},
            # Several VMs run together. Idle schedulers sleep instead of spinning.
            {"ERL_FLAGS", System.get_env("ERL_FLAGS", "+sbwt none +sbwtdcpu none +sbwtdio none")}
          ],
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
