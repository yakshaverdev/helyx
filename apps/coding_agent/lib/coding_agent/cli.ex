defmodule CodingAgent.CLI do
  @default_model "opencode-go/kimi-k2"

  @moduledoc """
  The command line of the coding agent, for the `helyx` release and for
  `mix helyx`:

      helyx [directory] [--model provider/model] [--resume] [--version]
      helyx [directory] [--model provider/model | --resume] -p prompt
      helyx --session id -p prompt
      helyx --session id
      helyx --list [--all] [directory]

  `directory` is the session's working directory and defaults to the current
  one. `--model` defaults to `#{@default_model}`, which needs
  `OPENCODE_API_KEY`. `fake/echo` runs without a key. `--resume` continues
  the most recent session for the directory that has a message, and
  `--session` the session with that id, in the folder of its header. Both
  keep the saved model, so they do not combine with `--model`. `--list`
  prints the sessions of the directory, or of every folder with `--all`,
  one line each, newest first, and starts nothing. `-p` (`--print`) runs
  the one prompt with no TUI (`CodingAgent.Print`), in a new session, or
  with `--resume` or `--session` in the session they pick. The
  design is in `docs/features/local-release.md`,
  `docs/features/session-list.md`, and `docs/features/print-mode.md`.
  """

  alias CodingAgent.Print
  alias Helyx.Session.File.Scan

  @options "the options are --model provider/model, --resume, --session id, --list, --all, " <>
             "-p prompt, and --version"

  @switches [
    model: :string,
    resume: :boolean,
    session: :string,
    list: :boolean,
    all: :boolean,
    print: :string,
    version: :boolean
  ]

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

  # The widths of the file text on a line of --list, in code points.
  @prompt_width 60
  @model_width 40
  @folder_width 80

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

    # The release script exports RELEASE_* variables to the VM. A command
    # that the agent runs must not inherit them: a `helyx` of another build
    # started there would boot with the version folder of this one.
    for {"RELEASE_" <> _ = name, _value} <- System.get_env(), do: System.delete_env(name)

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

  defp start(argv, release_version, halt) do
    with {:ok, opts, args} <- parse(argv) do
      if opts[:version],
        do: IO.puts("helyx " <> version(release_version)),
        else: start_agent(opts, args, halt)
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
        with {:ok, cwd} <- run_cwd(opts, args), do: launch(opts, cwd)
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

  # `--session` runs in the folder of the session header.
  defp run_cwd(opts, args), do: if(id = opts[:session], do: session_cwd(id), else: cwd(args))

  defp cwd([]), do: check_dir(File.cwd!())
  defp cwd([directory]), do: check_dir(Path.expand(directory))
  defp cwd(args), do: {:error, "expected at most one directory argument, got: #{inspect(args)}"}

  defp check_dir(cwd) do
    if File.dir?(cwd), do: {:ok, cwd}, else: {:error, "not a directory: #{inspect(cwd)}"}
  end

  # The id is checked before it becomes part of a path (`Scan.find/2`). The
  # folder of the header must be an absolute path to a directory. It comes
  # from the file, so its error text gets the clean pass and the width of a
  # list line.
  defp session_cwd(id) do
    case Scan.find(sessions_dir(), id) do
      {:ok, _path, %{"cwd" => cwd}} ->
        if Path.type(cwd) == :absolute and File.dir?(cwd),
          do: {:ok, cwd},
          else: {:error, ~s(not a directory: "#{folder_text(cwd)}")}

      {:error, :invalid_id} ->
        {:error, "not a session id: #{inspect(id)}"}

      {:error, :not_found} ->
        {:error, "no session #{inspect(id)}"}

      {:error, reason} ->
        {:error, CodingAgent.error_text(reason)}
    end
  end

  defp list(all?, args) do
    with {:ok, scope} <- if(all?, do: {:ok, :all}, else: cwd(args)) do
      for summary <- Scan.list(sessions_dir(), scope), do: IO.puts(line(summary, all?))
      :ok
    end
  end

  # The folder, the model, and the prompt come from the file, so each gets
  # the clean pass before it reaches the terminal. The end of a folder tells
  # folders apart.
  defp line(summary, all?) do
    folder =
      if all?,
        do: [folder_text(summary.cwd)],
        else: []

    model = summary.model |> CodingAgent.one_line() |> take(@model_width)
    prompt = summary.prompt |> CodingAgent.one_line() |> take(@prompt_width)
    Enum.join([summary.id, time(summary.mtime)] ++ folder ++ [model, prompt], "  ")
  end

  defp folder_text(cwd), do: cwd |> CodingAgent.one_line() |> take(-@folder_width)

  # A width counts code points, not graphemes: one grapheme can hold any
  # number of combining marks. A negative count takes the end.
  defp take(text, count), do: text |> String.to_charlist() |> Enum.take(count) |> List.to_string()

  defp time(mtime) do
    mtime
    |> :calendar.system_time_to_local_time(:second)
    |> NaiveDateTime.from_erl!()
    |> NaiveDateTime.to_string()
  end

  # Application env so that a test points the agent at its own directory.
  defp sessions_dir,
    do: Application.get_env(:coding_agent, :sessions_dir) || Path.expand("~/.helyx/sessions")

  # The piped input is read before any application starts.
  defp print(opts, args) do
    with {:ok, cwd} <- run_cwd(opts, args),
         {:ok, prompt} <- Print.prompt(opts[:print]),
         do: launch(opts, cwd, prompt: prompt)
  end

  defp launch(opts, cwd, extra \\ []) do
    result =
      with {:ok, _apps} <- Application.ensure_all_started(:coding_agent) do
        CodingAgent.run(
          [
            model: Keyword.get(opts, :model, @default_model),
            cwd: cwd,
            resume: opts[:session] || Keyword.get(opts, :resume, false),
            sessions_dir: sessions_dir()
          ] ++ extra
        )
      end

    case result do
      {:error, reason} -> {:error, CodingAgent.error_text(reason)}
      result -> result
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
      case OptionParser.parse(join_values(argv), strict: @switches, aliases: [p: :print]) do
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
