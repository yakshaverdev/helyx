defmodule CodingAgent.CLI do
  @default_model "opencode-go/kimi-k2"

  # The usage lines, for the moduledoc and `--help`.
  @usage """
  helyx [directory] [--model provider/model] [--new | --resume]
  helyx [directory] [--model provider/model | --resume] -p prompt
  helyx --session id [-p prompt]
  helyx --list [--all] [directory]
  helyx serve [--host ip] [--port n] [--public host:port] [--model provider/model]
  helyx pair --runner name
  helyx hands --pair <link> [--folder dir]
  helyx hands --name <name> [--folder dir]
  helyx --version | --help
  """

  @moduledoc """
  The command line of the coding agent, for the `helyx` release and for
  `mix helyx`:

  #{String.replace(@usage, ~r/^/m, "    ")}
  `directory` is the session's working directory and defaults to the current
  one. `--model` names the model of a new session, and a new session with no
  `--model` takes the default model of the server, `#{@default_model}` unless a
  `helyx serve` sets another; `fake/echo` runs without a key. `--resume` and
  `--session` keep the saved model, so they do not combine with `--model`.
  Every command is a client of the server of the data folder. Without `-p`,
  `helyx` runs the TUI over the wire when a server runs, and reattaches to
  the newest session of the directory, as `--resume` picks it
  (`CodingAgent.attach/3`); `--new` and `--model` start one. With no server,
  the `helyx` of the release starts `helyx serve` in the background and
  attaches to it; `mix helyx` runs the server in its own VM. `-p`
  (`--print`) runs one prompt over the wire with no TUI, and `serve` runs the
  headless server. `hands` pairs a runner with a link, or reconnects it with
  its saved key. The design is in `docs/features/local-release.md`, and
  the rest in `docs/features/session-list.md`, `docs/features/print-mode.md`,
  `docs/features/serve.md`, `docs/features/remote-hands.md`, and
  `docs/features/tui-attach.md`.
  """

  alias CodingAgent.CLI.{Hands, Pair}
  alias CodingAgent.Lease
  alias CodingAgent.Print
  alias Helyx.Tool.Bash
  alias Helyx.TUI.SessionList
  alias Helyx.TUI.Wire.Connection

  # Each switch once, with its type, its form, and its help line: the parse,
  # the option list of an error, and `--help` read this list.
  @switches [
    model: {:string, "--model provider/model", "the model, default #{@default_model}"},
    resume:
      {:boolean, "--resume", "continue the newest session of the directory that has a message"},
    new: {:boolean, "--new", "start a new session, not the newest of the directory on a server"},
    session: {:string, "--session id", "continue the session with this id, in its folder"},
    list: {:boolean, "--list", "print the sessions of the directory, newest first"},
    all: {:boolean, "--all", "with --list, the sessions of every folder"},
    print: {:string, "-p prompt", "run one prompt with no TUI and print the answer (--print)"},
    host: {:string, "--host ip", "with serve, the address to listen on, default 127.0.0.1"},
    port: {:integer, "--port n", "with serve, the port, 0 to 65535; default 0, a free port"},
    public:
      {:string, "--public host:port",
       "with serve, a second listener of the wire with TLS, the address a link carries"},
    runner:
      {:string, "--runner name",
       "with pair, the name of the runner, 1 to 64 bytes of a-z, 0-9, and _"},
    pair: {:string, "--pair link", "with hands, the helyx-pair link of the runner"},
    name: {:string, "--name name", "with hands, the paired runner to connect with its saved key"},
    folder:
      {:string, "--folder dir", "with hands, the folder of the runner, default the current one"},
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
  serve runs until SIGTERM (or, through the launcher, any signal that ends a process but a
  fault signal) and then exits 0; 1 when it does not start, when a server holds the data
  folder or runs in the VM, or when the server stops by a failure or a closed output.
  hands runs until SIGTERM and then exits 0; 1 for a bad link, a refused key, a wrong pin,
  a missing or unreadable runner state, or a folder that is not a directory.
  """

  # The options that do not combine, with the reason. `:directory` is the
  # directory argument.
  @conflicts [
    {:model, :resume, "; a resumed session keeps its saved model"},
    {:model, :session, "; a resumed session keeps its saved model"},
    {:directory, :session, "; the session runs in the folder of its header"},
    {:resume, :session, ""},
    {:new, :resume, ""},
    {:new, :session, ""},
    {:list, :new, ""},
    {:list, :model, ""},
    {:list, :resume, ""},
    {:list, :session, ""},
    {:print, :list, ""},
    {:directory, :all, ""}
  ]

  # A switch that needs another switch, or a command, which this path never
  # has (`serve`, `pair`, and `hands` run before the check).
  @needs [
    all: :list,
    host: :serve,
    port: :serve,
    public: :serve,
    runner: :pair,
    pair: :hands,
    name: :hands,
    folder: :hands
  ]

  @doc """
  Runs the agent with the command line `argv` until the user quits, and
  returns the exit status. A bad argument prints one line on stderr and
  returns 1. Without `-p`, so does a failed start or a session that stops
  while the agent runs. `--version` prints the version and returns 0, and
  so does `--list` after its lines. `-p` runs print mode (`CodingAgent.Print.main/2`)
  and does not return. Tests pass their own `halt`.
  """
  @spec main([String.t()], Print.halt()) :: term()
  def main(argv, halt \\ &:erlang.halt(&1, flush: false)) do
    release_version = System.get_env("RELEASE_VSN")
    launcher = System.get_env("HELYX_LAUNCHER")

    case Lease.acquire(System.get_env()) do
      {:ok, lease} ->
        System.put_env(command_env(System.get_env()))
        # Print mode ends the VM itself, so the lease goes before its halt;
        # every other end returns from `start/4` and runs the `after`.
        halt = fn status ->
          Lease.release(lease)
          halt.(status)
        end

        try do
          result(start(argv, release_version, launcher, halt))
        after
          Lease.release(lease)
        end

      {:error, text} ->
        result({:error, text})
    end
  end

  defp result(:ok), do: 0
  defp result(status) when is_integer(status), do: status

  defp result({:error, text}) do
    IO.puts(:stderr, "helyx: " <> text)
    1
  end

  @doc false
  # The changes, for System.put_env/1, that give a command of the agent the
  # environment of the user's shell (docs/features/local-release.md).
  @spec command_env(%{String.t() => String.t()}) :: [{String.t(), String.t() | nil}]
  def command_env(env) do
    deleted =
      for {name, _value} <- env,
          String.starts_with?(name, "RELEASE_") or
            name in ~w(ROOTDIR BINDIR EMU PROGNAME HELYX_LAUNCHER),
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

  # `serve`, `pair`, and `hands` are the first argument only, as in the
  # launcher of the release.
  defp start(argv, release_version, launcher, halt) do
    {command, argv} =
      case argv do
        [command | rest] when command in ["serve", "pair", "hands"] -> {command, rest}
        argv -> {nil, argv}
      end

    with {:ok, opts, args} <- parse(argv) do
      cond do
        opts[:help] -> IO.write(@help)
        opts[:version] -> IO.puts("helyx " <> version(release_version))
        command == "serve" -> serve(opts, args)
        command == "pair" -> Pair.run(opts, args, sessions_dir())
        command == "hands" -> hands(opts, args)
        true -> start_agent(opts, args, launcher, halt)
      end
    end
  end

  defp version(nil), do: "#{Application.spec(:coding_agent, :vsn)} (source)"
  defp version(release_version), do: release_version

  defp start_agent(opts, args, launcher, halt) do
    with :ok <- check_combination(opts, args), do: command(opts, args, launcher, halt)
  end

  defp command(opts, args, launcher, halt) do
    cond do
      opts[:list] ->
        list(opts[:all] == true, args, launcher)

      opts[:print] ->
        Print.main(fn -> print(opts, args, launcher) end, halt)

      true ->
        with {:ok, run} <- run_opts(opts, args), do: launch(opts, run, launcher)
    end
  end

  defp check_combination(opts, args) do
    given = for {name, value} <- opts, value, do: name
    given = if args == [], do: given, else: [:directory | given]

    with nil <- Enum.find(@conflicts, fn {a, b, _reason} -> a in given and b in given end),
         nil <- Enum.find(@needs, fn {a, b} -> a in given and b not in given end) do
      :ok
    else
      {a, b, reason} -> {:error, "#{switch(a)} does not combine with #{switch(b)}#{reason}"}
      {a, b} -> {:error, "#{switch(a)} needs #{switch(b)}"}
    end
  end

  defp serve(opts, []) do
    with :ok <- serve_switches(opts),
         {:ok, ip} <- ip(Keyword.get(opts, :host, "127.0.0.1")),
         {:ok, port} <- port(Keyword.get(opts, :port, 0)),
         {:ok, public} <- Pair.public_option(opts[:public]),
         {:ok, _apps} <- Application.ensure_all_started(:coding_agent) do
      result =
        CodingAgent.Serve.run(
          sessions_dir: sessions_dir(),
          model: Keyword.get(opts, :model, @default_model),
          ip: ip,
          port: port,
          public: public
        )

      # The folder in a line comes from the configuration.
      with {:error, text} <- result, do: {:error, CodingAgent.clean_line(text)}
    end
  end

  defp serve(_opts, args),
    do: {:error, "serve takes no directory argument, got: #{inspect(args)}"}

  # The runner state lives under the root of the default data folder:
  # `sessions_dir/1` is `<home>/sessions` unless a test sets its own.
  defp hands(opts, args) do
    result = Hands.run(opts, args, Path.dirname(sessions_dir()))
    with {:error, text} <- result, do: {:error, CodingAgent.clean_line(text)}
  end

  defp serve_switches(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in [:host, :port, :model, :public])) do
      nil -> :ok
      name -> {:error, "#{switch(name)} does not combine with serve"}
    end
  end

  defp ip(host) do
    with {:error, _} <- :inet.parse_address(String.to_charlist(host)),
         do: {:error, "--host takes an IP address, got: #{inspect(host)}"}
  end

  defp port(port) when port in 0..65_535, do: {:ok, port}
  defp port(port), do: {:error, "--port takes 0 to 65535, got: #{port}"}

  defp switch(:directory), do: "a directory argument"
  defp switch(:serve), do: "serve"
  defp switch(:pair), do: "pair"
  defp switch(:hands), do: "hands"
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

  # The list is one page of the server of the data folder: 256 is the most
  # that a scan reads, and the largest page of the wire
  # (docs/features/session-list.md).
  defp list(all?, args, launcher) do
    result =
      with {:ok, scope} <- list_scope(all?, args),
           {:ok, _apps} <- Application.ensure_all_started(:coding_agent) do
        # The log of a server of this VM goes to stderr, so stdout holds
        # only the list lines.
        _ = log_to_stderr()
        opts = [limit: 256] ++ if(scope == :all, do: [], else: [cwd: scope])

        with_server([sessions_dir: sessions_dir()], launcher, fn
          {:ok, socket, ws} -> sessions(socket, ws, opts, all?)
          {:error, text} -> {:error, {:attach, text}}
        end)
      end

    with {:error, reason} <- result, do: {:error, error_text(reason, nil)}
  end

  defp list_scope(true, _args), do: {:ok, :all}
  defp list_scope(false, args), do: cwd(args)

  defp sessions(socket, ws, opts, all?) do
    {:ok, conn, ref} = Connection.open(socket, ws)

    try do
      with {:ok, items, _next} <- Connection.list_saved(conn, opts),
           do: Enum.each(items, &IO.puts(SessionList.line(&1, all?)))
    after
      Process.exit(conn, :kill)
      Process.demonitor(ref, [:flush])
    end
  end

  # Application env so that a test points the agent at its own directory.
  defp sessions_dir,
    do: Application.get_env(:coding_agent, :sessions_dir) || Path.expand("~/.helyx/sessions")

  # The piped input is read before any application starts.
  defp print(opts, args, launcher) do
    with {:ok, run} <- run_opts(opts, args),
         {:ok, prompt} <- Print.prompt(opts[:print]),
         do: launch(opts, [prompt: prompt] ++ run, launcher)
  end

  defp launch(opts, extra, launcher) do
    run = [resume: opts[:session] || Keyword.get(opts, :resume, false)] ++ extra

    result =
      with {:ok, _apps} <- Application.ensure_all_started(:coding_agent),
           do: start_or_attach(opts, [sessions_dir: sessions_dir()] ++ run, launcher)

    case result do
      {:error, reason} -> {:error, error_text(reason, opts[:session])}
      result -> result
    end
  end

  # Both commands are clients of the server of the data folder
  # (docs/features/tui-attach.md, and docs/features/print-mode.md).
  defp start_or_attach(opts, run, launcher) do
    if run[:prompt],
      do: print_over_wire(opts, run, launcher),
      else: find_server(opts, run, launcher)
  end

  # With no `--model`, print mode sends no model, and the server gives its
  # default one, as for the TUI.
  defp print_over_wire(opts, run, launcher),
    do: with_server(run, launcher, &answer(opts, run, &1))

  defp answer(opts, run, {:ok, socket, ws}),
    do: CodingAgent.print(socket, ws, Keyword.take(opts, [:model]) ++ run)

  defp answer(_opts, _run, {:error, text}), do: {:error, {:attach, text}}

  # The TUI holds the log of the VM in `tui.log` while it runs, and while a
  # server of this VM runs with it (docs/features/tui-attach.md, decisions 9
  # and 12). The hold makes the data folder for its log file, so the look
  # for a server, and the tool check, come first: a folder that the hold
  # made is no evidence of a server.
  defp find_server(opts, run, launcher) do
    dir = run[:sessions_dir]

    case connect(dir) do
      {:error, text} -> {:error, {:attach, text}}
      found -> with :ok <- perl(found), do: held_server(found, dir, launcher, opts, run)
    end
  end

  # One VM has one set of log handlers: the log of the VM, and of a server
  # that it runs, goes to `tui.log` while the TUI runs.
  defp held_server(found, dir, launcher, opts, run) do
    CodingAgent.LogFile.run(Path.join(dir, "tui.log"), fn held ->
      server(found, dir, launcher, &attach(opts, [held: held] ++ run, &1))
    end)
  end

  # The one way to the server of the data folder for print mode and the
  # list: a running one (decision 1), one that the launcher starts in the
  # background (decision 10), or, with no launcher, one in this VM until
  # `fun` returns (decision 12). `fun` gets `{:ok, socket, ws}` or
  # `{:error, text}` and returns the result of the command.
  defp with_server(run, launcher, fun) do
    dir = run[:sessions_dir]

    case connect(dir) do
      {:error, text} ->
        fun.({:error, text})

      found ->
        with :ok <- perl(found), do: server(found, dir, launcher, fun)
    end
  end

  defp connect(dir), do: CodingAgent.Attach.connect(dir)

  defp server({:ok, socket, ws}, _dir, _launcher, fun), do: fun.({:ok, socket, ws})
  defp server(:none, dir, nil, fun), do: CodingAgent.Attach.serve(dir, @default_model, fun)
  defp server(:none, dir, launcher, fun), do: fun.(CodingAgent.Attach.start(dir, launcher))

  # A server needs perl, as the tools do: with none on the PATH, no server
  # starts and the line is that of the tool check
  # (docs/features/tui-attach.md, decision 12). A server that runs needs no
  # check: the start of its own process made it.
  defp perl(:none), do: available()
  defp perl(_found), do: :ok

  defp available do
    with {:error, reason} <- Bash.check(),
         do: {:error, {:tool_unavailable, Bash.name(), reason}}
  end

  # The `:default` handler of a server of this VM writes on stdout, which
  # holds only the list lines. Print mode sends the log to stderr as its
  # first step (`CodingAgent.Print`).
  defp log_to_stderr do
    with {:ok, log} <- :logger.get_handler_config(:default) do
      :ok = :logger.remove_handler(:default)
      :ok = :logger.add_handler(:default, :logger_std_h, put_in(log.config.type, :standard_error))
    end
  end

  defp attach(opts, run, {:ok, socket, ws}),
    do: CodingAgent.attach(socket, ws, Keyword.take(opts, [:model]) ++ reattach(opts, run))

  defp attach(_opts, _run, {:error, text}), do: {:error, {:attach, text}}

  # On a server, `helyx` reattaches to the newest session of its folder;
  # `--new` and `--model` start one (docs/features/tui-attach.md, decision 16).
  defp reattach(opts, run) do
    if opts[:new] || opts[:model] || run[:resume],
      do: run,
      else: Keyword.put(run, :resume, :reattach)
  end

  # A find that the server does not accept names the id on its own line.
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
