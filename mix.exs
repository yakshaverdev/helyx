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
      # :ex_unit is not in the default PLT.
      dialyzer: [plt_add_apps: [:ex_unit]]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
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
    # No glob and no command string: a glob character in the checkout path or a
    # quote in a directory name made earlier forms pass while skipping a project.
    projects =
      for parent <- ["plugins", "apps"],
          root = Path.join(__DIR__, parent),
          File.dir?(root),
          name <- Enum.sort(File.ls!(root)),
          dir = Path.join(root, name),
          File.regular?(Path.join(dir, "mix.exs")) do
        fn _ ->
          # A child that inherits MIX_EXS loads this project again and recurses.
          System.delete_env("MIX_EXS")
          # A failure in a child does not say which project it was.
          Mix.shell().info("==> precommit #{Path.relative_to(dir, __DIR__)}")
          Mix.Task.run("cmd", ["--cd", dir, "mix", "precommit"])
        end
      end

    # deps.get runs first here and in every project, so a fresh worktree or a
    # rebase that brings a new project needs no manual fetch. --check-locked
    # makes a lock file that lacks an entry, or holds a version the requirement
    # rejects, fail the run instead of being rewritten by it.
    # Credo covers plugin and app sources from the root via .credo.exs.
    # Dialyzer cannot: they depend on the root, not the reverse, so each
    # project's precommit runs its own, with a forced PLT check because a path
    # dependency never changes the lock file that triggers one.
    [
      precommit:
        [
          "deps.get --check-locked",
          "format",
          "compile --warnings-as-errors",
          "credo --strict",
          "dialyzer",
          "test"
        ] ++
          projects
    ]
  end
end
