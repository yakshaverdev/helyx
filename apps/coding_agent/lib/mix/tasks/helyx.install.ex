defmodule Mix.Tasks.Helyx.Install do
  @shortdoc "Builds the helyx release and installs it"
  @moduledoc """
  Builds the `helyx` release of the current checkout and installs it, so
  that `helyx` starts the coding agent in any folder.

      mix helyx.install [--prefix DIR] [--bin-dir DIR]

  The build goes to `<prefix>/releases/<commit>` (default prefix
  `~/.helyx`), `<prefix>/current` points at it, and `<bin-dir>/helyx`
  (default `~/.local/bin`) starts it. An existing build folder is never
  replaced.
  The install keeps the build that `current` pointed at before and deletes
  the older ones. The task runs in `prod`. The design is in
  `docs/features/local-release.md`.
  """

  use Mix.Task

  @usage "usage: mix helyx.install [--prefix DIR] [--bin-dir DIR]"

  @impl true
  def run(argv) do
    opts = parse(argv)
    prefix = Path.expand(opts[:prefix] || "~/.helyx")
    releases = Path.join(prefix, "releases")
    File.mkdir_p!(releases)
    # The OS pid keeps the folder of one install apart from another's.
    build = Path.join(releases, ".build-#{System.pid()}")

    try do
      Mix.Task.run("release", ["helyx", "--path", build, "--quiet"])
      install(build, prefix, Path.expand(opts[:bin_dir] || "~/.local/bin"))
    after
      File.rm_rf!(build)
    end
  end

  @doc false
  # Moves the release in `build` into place. Public so that a test installs
  # a fake build without a release build.
  @spec install(Path.t(), Path.t(), Path.t()) :: :ok
  def install(build, prefix, bin_dir) do
    releases = Path.join(prefix, "releases")
    current = Path.join(prefix, "current")
    previous = previous(current)

    [_erts, version] =
      build |> Path.join("releases/start_erl.data") |> File.read!() |> String.split()

    [_app_version, commit] = String.split(version, "+", parts: 2)
    name = free_name(releases, commit, 1)
    File.rename!(build, Path.join(releases, name))
    # The launcher names `current`, not the build, so it is written before
    # the swap.
    write_launcher(Path.join(current, "bin/helyx"), bin_dir)

    # A rename over the old link, so a start finds the old or the new build.
    link = Path.join(releases, ".current-#{System.pid()}")
    _ = File.rm(link)
    File.ln_s!(Path.join("releases", name), link)
    File.rename!(link, current)
    Mix.shell().info("installed #{version} in #{Path.join(releases, name)}")

    # The swap is the commit point: a raise before it leaves `current` and
    # the kept builds as they were. The deletion after it only warns, and the
    # next install tries again.
    for entry <- entries(releases), entry not in [name, previous] do
      with {:error, reason, file} <- File.rm_rf(Path.join(releases, entry)) do
        Mix.shell().error("could not delete #{file}: #{:file.format_error(reason)}")
      end
    end

    :ok
  end

  defp entries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names

      {:error, reason} ->
        Mix.shell().error("could not list #{dir}: #{:file.format_error(reason)}")
        []
    end
  end

  # The command line is a boundary. The usage text shows no argument, so no
  # argument needs escaping.
  defp parse(argv) do
    case OptionParser.parse(argv, strict: [prefix: :string, bin_dir: :string]) do
      {opts, [], []} -> opts
      _ -> Mix.raise(@usage)
    end
  rescue
    # OptionParser raises on "-=" and on a switch that is not UTF-8.
    _ in [ArgumentError, UnicodeConversionError] -> Mix.raise(@usage)
  end

  defp previous(current) do
    case File.read_link(current) do
      {:ok, target} ->
        Path.basename(target)

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        Mix.raise("cannot read the link #{current}: #{:file.format_error(reason)}")
    end
  end

  defp free_name(releases, commit, k) do
    name = if k == 1, do: commit, else: "#{commit}-#{k}"

    case File.lstat(Path.join(releases, name)) do
      {:error, :enoent} -> name
      _ -> free_name(releases, commit, k + 1)
    end
  end

  # The launcher keeps the folder and the arguments of the user, and adds no
  # wait and no retry. The release script resolves `current` once, at start.
  defp write_launcher(script, bin_dir) do
    File.mkdir_p!(bin_dir)
    launcher = Path.join(bin_dir, "helyx")
    # One fixed name: the next install replaces a file that a failed one left.
    tmp = Path.join(bin_dir, ".helyx-install")

    File.write!(tmp, """
    #!/bin/sh
    exec #{sh_quote(script)} eval 'System.halt(CodingAgent.CLI.main(System.argv()))' "$@"
    """)

    File.chmod!(tmp, 0o755)
    File.rename!(tmp, launcher)
  end

  defp sh_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"
end
