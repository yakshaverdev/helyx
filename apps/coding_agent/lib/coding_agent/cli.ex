defmodule CodingAgent.CLI do
  @default_model "opencode-go/kimi-k2"

  # The usage lines, for the moduledoc and `--help`.
  @usage """
  helyx [directory] [--model provider/model] [--resume]
  helyx [directory] [--model provider/model | --resume] -p prompt
  helyx --session id [-p prompt]
  helyx --list [--all] [directory]
  helyx --version | --help
  """

  @moduledoc """
  The command line of the coding agent, for the `helyx` release and for
  `mix helyx`:

  #{String.replace(@usage, ~r/^/m, "    ")}
  `directory` is the session's working directory and defaults to the current
  one. `--model` defaults to `#{@default_model}`, which needs
  `OPENCODE_API_KEY`. `fake/echo` runs without a key. `--resume` continues
  the most recent session for the directory that has a message, and
  `--session` the session with that id, in the folder of its header. Both
  keep the saved model, so they do not combine with `--model`. `--list`
  prints the sessions of the directory, or of every folder with `--all`,
  one line each, newest first, and starts nothing. `--help` (`-h`) prints
  the usage, the switches, and the exit statuses. `-p` (`--print`) runs
  the one prompt with no TUI (`CodingAgent.Print`), in a new session, or
  with `--resume` or `--session` in the session they pick. The
  design is in `docs/features/local-release.md`,
  `docs/features/session-list.md`, and `docs/features/print-mode.md`.
  """

  alias CodingAgent.Print
  alias Helyx.Session.File.Scan
  alias Helyx.TUI.SessionList

  # Each switch once, with its type, its form, and its help line: the parse,
  # the option list of an error, and `--help` read this list.
  @switches [
    model: {:string, "--model provider/model", "the model, default #{@default_model}"},
    resume:
      {:boolean, "--resume", "continue the newest session of the directory that has a message"},
    session: {:string, "--session id", "continue the session with this id, in its folder"},
    list: {:boolean, "--list", "print the sessions of the directory, newest first"},
    all: {:boolean, "--all", "with --list, the sessions of every folder"},
    print: {:string, "-p prompt", "run one prompt with no TUI and print the answer (--print)"},
    version: {:boolean, "--version", "print the version"},
    help: {:boolean, "--help", "print this help (-h)"}
  ]

  @types for {name, {type, _form, _text}} <- @switches, do: {name, type}
  @forms for {_name, {_type, form, _text}} <- @switches, do: form
  @options "the options are #{Enum.join(Enum.drop(@forms, -1), ", ")}, and #{List.last(@forms)}"

  @help """
  usage: #{String.replace(@usage, "\nhelyx", "\n       helyx")}
  options:
  #{for {_name, {_type, form, text}} <- @switches, into: "", do: "  #{String.pad_trailing(form, 24)}#{text}\n"}
  exit status: 0 on success and 1 on an error. With -p, 0 when the turn ends normally,
  1 when it fails, is aborted, or stops at the output limit, 143 on SIGTERM, and 129 on SIGHUP.
  """

  # The options that do not combine, with the reason. `:directory` is the
  # directory argument.
  @conflicts [
    {:model, :resume, "; a resumed session keeps its saved model"},
    {:model, :session, "; a resumed session keeps its saved model"},
    {:directory, :session, "; the session runs in the folder of its header"},
    {:resume, :session, ""},
    {:list, :model, ""},
    {:list, :resume, ""},
    {:list, :session, ""},
    {:print, :list, ""},
    {:directory, :all, ""}
  ]

  @doc """
  Runs the agent with the command line `argv` until the user quits, and
  returns the exit status. A bad argument prints one line on stderr and
  returns 1. Without `-p`, so does a failed start or a session that stops
  while the agent runs. `--version` prints the version and returns 0, and
  so does `--list` after its lines. `-p` runs print mode
  (`CodingAgent.Print.main/2`) once the options and their combination are
  checked; it checks the directory and the session of `--session`
  itself, ends with `halt` and its status, and does not return. Tests pass their own `halt`.
  """
  @spec main([String.t()], Print.halt()) :: term()
  def main(argv, halt \\ &:erlang.halt(&1, flush: false)) do
    release_version = System.get_env("RELEASE_VSN")
    System.put_env(command_env(System.get_env()))

    case start(argv, release_version, halt) do
      :ok ->
        0

      status when is_integer(status) ->
        status

      {:error, text} ->
        IO.puts(:stderr, "helyx: " <> text)
        1
    end
  end

  @doc false
  # The changes, for System.put_env/1, that give a command of the agent the
  # environment of the user's shell (docs/features/local-release.md).
  @spec command_env(%{String.t() => String.t()}) :: [{String.t(), String.t() | nil}]
  def command_env(env) do
    deleted =
      for {name, _value} <- env,
          String.starts_with?(name, "RELEASE_") or name in ~w(ROOTDIR BINDIR EMU PROGNAME),
          do: {name, nil}

    [{"PATH", command_path(env)} | deleted]
  end

  defp command_path(%{"PATH" => path, "RELEASE_ROOT" => root}) do
    path
    |> String.split(":")
    |> Enum.drop_while(&(&1 == root or String.starts_with?(&1, root <> "/")))
    |> case do
      [] -> nil
      rest -> Enum.join(rest, ":")
    end
  end

  defp command_path(env), do: env["PATH"]

  defp start(argv, release_version, halt) do
    with {:ok, opts, args} <- parse(argv) do
      cond do
        opts[:help] -> IO.write(@help)
        opts[:version] -> IO.puts("helyx " <> version(release_version))
        true -> start_agent(opts, args, halt)
      end
    end
  end

  defp version(nil), do: "#{Application.spec(:coding_agent, :vsn)} (source)"
  defp version(release_version), do: release_version

  defp start_agent(opts, args, halt) do
    with :ok <- check_combination(opts, args), do: command(opts, args, halt)
  end

  defp command(opts, args, halt) do
    cond do
      opts[:list] ->
        list(opts[:all], args)

      opts[:print] ->
        Print.main(fn -> print(opts, args) end, halt)

      true ->
        with {:ok, run} <- run_opts(opts, args), do: launch(opts, run)
    end
  end

  defp check_combination(opts, args) do
    given = for {name, value} <- opts, value, do: name
    given = if args == [], do: given, else: [:directory | given]

    case Enum.find(@conflicts, fn {a, b, _reason} -> a in given and b in given end) do
      {a, b, reason} ->
        {:error, "#{switch(a)} does not combine with #{switch(b)}#{reason}"}

      nil ->
        if :all in given and :list not in given, do: {:error, "--all needs --list"}, else: :ok
    end
  end

  defp switch(:directory), do: "a directory argument"
  defp switch(name), do: "--#{name}"

  # `--session` runs in the folder of the session header, which the resume
  # finds after the tool checks (docs/features/server-management.md, "Order
  # of the checks").
  defp run_opts(opts, args) do
    if opts[:session],
      do: {:ok, []},
      else: with({:ok, cwd} <- cwd(args), do: {:ok, [cwd: cwd]})
  end

  defp cwd([]), do: check_dir(File.cwd!())
  defp cwd([directory]), do: check_dir(Path.expand(directory))
  defp cwd(args), do: {:error, "expected at most one directory argument, got: #{inspect(args)}"}

  defp check_dir(cwd) do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, "not a directory: #{inspect(cwd)}"}
  end

  defp list(all?, args) do
    with {:ok, scope} <- if(all?, do: {:ok, :all}, else: cwd(args)) do
      for summary <- Scan.list(sessions_dir(), scope),
          do: IO.puts(SessionList.line(summary, all?))

      :ok
    end
  end

  # Application env so that a test points the agent at its own directory.
  defp sessions_dir,
    do: Application.get_env(:coding_agent, :sessions_dir) || Path.expand("~/.helyx/sessions")

  # The piped input is read before any application starts.
  defp print(opts, args) do
    with {:ok, run} <- run_opts(opts, args),
         {:ok, prompt} <- Print.prompt(opts[:print]),
         do: launch(opts, [prompt: prompt] ++ run)
  end

  defp launch(opts, extra) do
    result =
      with {:ok, _apps} <- Application.ensure_all_started(:coding_agent) do
        CodingAgent.run(
          [
            model: Keyword.get(opts, :model, @default_model),
            resume: opts[:session] || Keyword.get(opts, :resume, false),
            sessions_dir: sessions_dir()
          ] ++ extra
        )
      end

    case result do
      {:error, reason} -> {:error, error_text(reason, opts[:session])}
      result -> result
    end
  end

  # The find of the `--session` id names the id.
  defp error_text(:invalid_id, id) when is_binary(id),
    do: CodingAgent.clean_line("not a session id: #{inspect(id)}")

  defp error_text(:not_found, id) when is_binary(id),
    do: CodingAgent.clean_line("no session #{inspect(id)}")

  defp error_text(reason, _id), do: CodingAgent.error_text(reason)

  # The command line is a boundary: every argument in an error shows through
  # inspect/1, and parse!/2 would put the raw switch name in its error. The
  # UTF-8 check keeps inspect/1 output readable and stops the
  # UnicodeConversionError that OptionParser raises on such a short switch.
  defp parse(argv) do
    if bad = Enum.find(argv, &(not String.valid?(&1))) do
      {:error, "an argument is not UTF-8: #{inspect(bad, binaries: :as_strings)}"}
    else
      case OptionParser.parse(join_values(argv), strict: @types, aliases: [p: :print, h: :help]) do
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

  # A session id and a prompt can start with "-", and OptionParser reads a
  # value that starts with "-" as switches. The joined form keeps it a value.
  defp join_values(["--" | _] = rest), do: rest
  defp join_values(["--session", id | rest]), do: ["--session=" <> id | join_values(rest)]

  defp join_values([switch, text | rest]) when switch in ["-p", "--print"],
    do: ["--print=" <> text | join_values(rest)]

  defp join_values([arg | rest]), do: [arg | join_values(rest)]
  defp join_values([]), do: []

  defp option_text({name, nil}), do: inspect(name)
  defp option_text({name, value}), do: "#{inspect(name)}=#{inspect(value)}"
end
