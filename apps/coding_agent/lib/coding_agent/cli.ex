defmodule CodingAgent.CLI do
  @default_model "opencode-go/kimi-k2"

  @moduledoc """
  The command line of the coding agent, for the `helyx` release and for
  `mix helyx`:

      helyx [directory] [--model provider/model] [--resume] [--version]

  `directory` is the session's working directory and defaults to the current
  one. `--model` defaults to `#{@default_model}`, which needs
  `OPENCODE_API_KEY`. `fake/echo` runs without a key. `--resume` continues
  the most recent session for the directory and keeps its saved model, so it
  does not combine with `--model`. The design is in
  `docs/features/local-release.md`.
  """

  @options "the options are --model provider/model, --resume, and --version"

  @doc """
  Runs the agent with the command line `argv` until the user quits, and
  returns the exit status. A bad argument or a failed start prints one line
  on stderr and returns 1. `--version` prints the version and returns 0.
  """
  @spec main([String.t()]) :: 0 | 1
  def main(argv) do
    release_version = System.get_env("RELEASE_VSN")

    # The release script exports RELEASE_* variables to the VM. A command
    # that the agent runs must not inherit them: a `helyx` of another build
    # started there would boot with the version folder of this one.
    for {"RELEASE_" <> _ = name, _value} <- System.get_env(), do: System.delete_env(name)

    case start(argv, release_version) do
      :ok ->
        0

      {:error, text} ->
        IO.puts(:stderr, "helyx: " <> text)
        1
    end
  end

  defp start(argv, release_version) do
    with {:ok, opts, args} <- parse(argv) do
      if opts[:version],
        do: IO.puts("helyx " <> version(release_version)),
        else: start_agent(opts, args)
    end
  end

  defp version(nil), do: "#{Application.spec(:coding_agent, :vsn)} (source)"
  defp version(release_version), do: release_version

  defp start_agent(opts, args) do
    with :ok <- check_combination(opts), {:ok, cwd} <- cwd(args), do: launch(opts, cwd)
  end

  defp check_combination(opts) do
    if opts[:resume] && opts[:model],
      do:
        {:error,
         "--model does not combine with --resume; a resumed session keeps its saved model"},
      else: :ok
  end

  defp cwd([]), do: check_dir(File.cwd!())
  defp cwd([directory]), do: check_dir(Path.expand(directory))
  defp cwd(args), do: {:error, "expected at most one directory argument, got: #{inspect(args)}"}

  defp check_dir(cwd) do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, "not a directory: #{inspect(cwd)}"}
  end

  defp launch(opts, cwd) do
    with {:ok, _apps} <- Application.ensure_all_started(:coding_agent),
         :ok <-
           CodingAgent.run(
             model: Keyword.get(opts, :model, @default_model),
             cwd: cwd,
             resume: Keyword.get(opts, :resume, false),
             # Application env so that a test points the agent at its own directory.
             sessions_dir: Application.get_env(:coding_agent, :sessions_dir)
           ) do
      :ok
    else
      {:error, reason} ->
        {:error, "could not start the agent: " <> CodingAgent.error_text(reason)}
    end
  end

  # The command line is a boundary: every argument in an error shows through
  # inspect/1, and parse!/2 would put the raw switch name in its error. The
  # UTF-8 check keeps inspect/1 output readable and stops the
  # UnicodeConversionError that OptionParser raises on such a short switch.
  defp parse(argv) do
    if bad = Enum.find(argv, &(not String.valid?(&1))) do
      {:error, "an argument is not UTF-8: #{inspect(bad, binaries: :as_strings)}"}
    else
      case OptionParser.parse(argv, strict: [model: :string, resume: :boolean, version: :boolean]) do
        {opts, args, []} ->
          {:ok, opts, args}

        {_, _, invalid} ->
          {:error,
           "unknown option or bad value: #{Enum.map_join(invalid, ", ", &option_text/1)}; " <>
             @options}
      end
    end
  rescue
    # OptionParser raises on some UTF-8 switches too, such as "-=".
    ArgumentError -> {:error, "bad option in #{inspect(argv)}; #{@options}"}
  end

  defp option_text({name, nil}), do: inspect(name)
  defp option_text({name, value}), do: "#{inspect(name)}=#{inspect(value)}"
end
