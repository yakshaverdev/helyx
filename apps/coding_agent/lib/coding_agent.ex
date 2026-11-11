defmodule CodingAgent do
  @moduledoc """
  The terminal coding agent: the TUI and print mode, both clients of the
  server of the data folder over the wire. `attach/3` runs the TUI
  (`docs/features/tui-attach.md`) and `print/3` runs one prompt
  (`docs/features/print-mode.md`). Started by `CodingAgent.CLI`, from the
  `helyx` release or `mix helyx`. The server is `CodingAgent.Serve`.
  """

  alias Helyx.TUI.Link
  alias Helyx.TUI.Wire.Connection

  require Link

  @plugins [
    Helyx.Provider.OpenAI.Go,
    Helyx.Provider.Fake,
    Helyx.Provider.ClaudeCode,
    Helyx.Provider.Codex,
    Helyx.ModelContext.Default,
    Helyx.Compaction.Summary,
    Helyx.Tool.Read,
    Helyx.Tool.Grep,
    Helyx.Tool.Find,
    Helyx.Tool.Bash,
    Helyx.Tool.Edit,
    Helyx.Tool.Write,
    Helyx.Tool.WebFetch,
    Helyx.Tool.Agent,
    Helyx.Tool.Skill,
    Helyx.Tool.Question,
    Helyx.Tool.ToolSearch,
    Helyx.Tool.MCP
  ]

  @doc "The plugins the agent runs with."
  @spec plugins() :: [module()]
  def plugins, do: @plugins

  @doc """
  Runs print mode over the wire (`docs/features/print-mode.md`). `socket`
  and `ws` are from `CodingAgent.Attach.connect/1`, which the caller owns
  and which the connection takes for this run. The options are `:prompt`,
  which is required; `:cwd`; `:model`, optional, so that a new session
  takes the default model of the server; and `:resume`: `false`, `true`
  for the newest session of `:cwd`, or the id of a session. The result is
  the exit status of `CodingAgent.Print.run/5`, or `{:error, reason}` for
  a failed open or prompt, with the errors of the wire. A session that
  this run opened stops at its end, also at a signal; a session that was
  live before keeps running and only gets its turn aborted.
  """
  @spec print(:gen_tcp.socket(), term(), keyword()) ::
          CodingAgent.Print.status() | {:error, term()}
  def print(socket, ws, opts) do
    {:ok, conn, ref} = Connection.open(socket, ws)

    try do
      run_prompt(conn, ref, opts)
    after
      # The connection ends with the run, as it does with the TUI (attach/3).
      Process.exit(conn, :kill)
      Process.demonitor(ref, [:flush])
    end
  end

  defp run_prompt(conn, ref, opts) do
    with {:ok, live_before} <- Connection.list_live(conn),
         {:ok, id} <- open(conn, opts),
         {:ok, cwd} <- session_cwd(conn, id),
         {:ok, cwd} <- directory(cwd) do
      # A session that was live before this run belongs to another client:
      # it keeps running, so a print run next to a TUI joins it.
      own? = not Enum.any?(live_before, &(&1.id == id))
      home = Application.get_env(:coding_agent, :home, System.user_home!())
      prompt = CodingAgent.Print.skills(Keyword.fetch!(opts, :prompt), cwd, home)

      try do
        CodingAgent.Print.run(conn, ref, id, prompt, end_session(conn, id, own?))
      after
        _ = stop_session(conn, id, own?)
      end
    end
  end

  # `resume: id` takes no `:cwd`: the session runs in the folder of its
  # header (`docs/features/session-list.md`).
  defp open(conn, opts) do
    case Keyword.get(opts, :resume, false) do
      false -> Connection.start(conn, Keyword.take(opts, [:cwd, :model]))
      true -> Connection.resume(conn, cwd: Keyword.fetch!(opts, :cwd))
      id -> Connection.resume(conn, id: id)
    end
  end

  # The folder of the session as the server has it. The session of a start
  # or a resume may find its folder gone since.
  defp session_cwd(conn, id) do
    with {:ok, live} <- Connection.list_live(conn) do
      case Enum.find(live, &(&1.id == id)) do
        nil -> {:error, :session_not_found}
        %{cwd: cwd} -> {:ok, cwd}
      end
    end
  end

  # The server keeps at most 64 live sessions and evicts none, so a script
  # that runs print mode many times must not leave one idle session for
  # each run. A session that was live before stays.
  defp stop_session(conn, id, true), do: Connection.stop(conn, id)
  defp stop_session(conn, id, false), do: Connection.abort(conn, id)

  # The signal of print mode ends the session as the end of the run does.
  defp end_session(conn, id, true), do: fn -> Connection.stop(conn, id) end
  defp end_session(conn, id, false), do: fn -> Connection.abort(conn, id) end

  defp directory(cwd) do
    if Path.type(cwd) == :absolute and File.dir?(cwd),
      do: {:ok, cwd},
      else: {:error, {:not_a_directory, cwd}}
  end

  @doc """
  Runs the TUI over the wire until the user quits
  (`docs/features/tui-attach.md`, decisions 8 and 9). `socket` and `ws` are
  from `CodingAgent.Attach.connect/1`, which the caller owns and gives to
  the connection (`Helyx.TUI.Wire.Connection`); the TUI takes the connection
  and ends it at its quit. The options are `:cwd`, `:resume`, and `:model`
  as for `print/3` with no `:prompt`; `:model` is optional: with none, a new
  session gets the default model of the server; `resume: id` takes no
  `:cwd`; and `resume: :reattach` resumes the newest session of `:cwd`, or
  starts one (decision 16). `:held` is the result of the log hold of
  `CodingAgent.LogFile.run/2`. The session runs on after the quit, which
  aborts nothing. After a lost connection the TUI connects again and
  subscribes with `after` (decision 11). Returns `{:error, reason}` as
  `print/3` does, with the errors of the wire.
  """
  @spec attach(:gen_tcp.socket(), term(), keyword()) :: :ok | {:error, term()}
  def attach(socket, ws, opts) do
    {:ok, conn, ref} = Connection.open(socket, ws)

    try do
      with {:ok, id, cwd, resumed} <- loading(fn -> open_remote(conn, opts) end) do
        dir = Keyword.fetch!(opts, :sessions_dir)

        Helyx.TUI.run(
          session: %Link{conn: conn, id: id},
          resumed: resumed,
          cwd: cwd,
          reconnect: reconnect(dir),
          notices: notices(Keyword.fetch!(opts, :held))
        )
      end
    after
      # The connection ended with the TUI that took it; one that no TUI
      # took ends here.
      Process.exit(conn, :kill)
      Process.demonitor(ref, [:flush])
    end
  end

  # The open has no deadline in the client (docs/features/tui-attach.md,
  # decision 17): the answer, the end of the connection, or Ctrl+C ends it.
  # An open that has not answered in this time gets one line on stderr.
  @loading_ms 500

  defp loading(open) do
    {:ok, notice} =
      :timer.apply_after(@loading_ms, IO, :puts, [:stderr, "helyx: loading the session..."])

    try do
      open.()
    after
      :timer.cancel(notice)
    end
  end

  # A `tui.log` that does not open: the TUI runs with no file log.
  defp notices(:ok), do: []
  defp notices({:error, notice}), do: [notice]

  # After a lost connection the TUI attaches again to the server of the
  # data folder, and starts none (docs/features/tui-attach.md, decision 11).
  defp reconnect(dir) do
    fn ->
      with :none <- CodingAgent.Attach.connect(dir),
           do: {:error, "no server runs for #{dir}"}
    end
  end

  # The session over the wire, and its folder. `--session` resumes the id
  # and runs in the folder that the server has for it, so the client reads
  # no file of the data folder. The folder is checked before the TUI draws.
  defp open_remote(conn, opts) do
    case Keyword.get(opts, :resume, false) do
      id when is_binary(id) ->
        with {:ok, id} <- Connection.resume(conn, id: id),
             {:ok, cwd} <- session_cwd(conn, id),
             {:ok, cwd} <- folder(cwd),
             do: {:ok, id, cwd, true}

      resume ->
        with {:ok, cwd} <- folder(opts[:cwd]),
             {:ok, id, resumed} <- start_or_resume(conn, resume, opts),
             do: {:ok, id, cwd, resumed}
    end
  end

  # A folder that is not UTF-8 has no JSON form, and a start refuses a NUL
  # byte: the answers of the wire, in its order.
  defp folder(cwd) do
    if String.valid?(cwd) and not String.contains?(cwd, <<0>>),
      do: directory(cwd),
      else: {:error, :invalid_cwd}
  end

  defp start_or_resume(conn, false, opts) do
    with {:ok, id} <- Connection.start(conn, Keyword.take(opts, [:cwd, :model])),
         do: {:ok, id, false}
  end

  defp start_or_resume(conn, true, opts) do
    with {:ok, id} <- Connection.resume(conn, cwd: opts[:cwd]), do: {:ok, id, true}
  end

  # A newest session that does not resume (its file, its lock, or its saved
  # model) names `--new`. The wire gives a `{code, text}` for those, and for
  # a few causes outside the session (tui-attach.md, Accepted holes).
  defp start_or_resume(conn, :reattach, opts) do
    case start_or_resume(conn, true, opts) do
      {:error, :not_found} -> start_or_resume(conn, false, opts)
      {:error, {_code, _text} = reason} -> {:error, {:reattach, reason}}
      result -> result
    end
  end

  @doc """
  Returns the one line that tells the user about an error of a command. A
  session that ended while the TUI ran (`{:session_down, reason}`) gives
  its sentence; any other error is a failed start, and its sentence comes
  after `could not start the agent: `; `{:not_a_directory, cwd}`,
  `{:attach, text}`, and `{:connection_down, reason}` are whole lines with
  no prefix. The errors of the wire are texts of `Helyx.TUI.Link`, and
  `{:start_failed, text}` is the text of the server. An error with no
  clause prints through `Helyx.Reason.text/1`, so it holds no stacktrace.
  Every result gets the clean pass of `clean_line/1`.
  """
  @spec error_text(term()) :: String.t()
  def error_text(reason), do: reason |> line() |> clean_line()

  @doc """
  The clean pass of `Helyx.TUI.SessionList.one_line/1`, then the cut of `Helyx.Reason.text/1`: at
  most 4000 bytes of valid UTF-8; a character cut in half is dropped.
  """
  @spec clean_line(String.t()) :: String.t()
  def clean_line(text), do: text |> Helyx.TUI.SessionList.one_line() |> Helyx.Reason.text()

  defp line({:session_down, _reason} = reason), do: sentence(reason)

  # The folder of a session, as the CLI shows a directory argument that is
  # not one.
  defp line({:not_a_directory, _cwd} = reason), do: sentence(reason)

  # A line of `CodingAgent.Attach.connect/1`, and the end of the connection
  # of a TUI over the wire: whole lines, with no prefix.
  defp line({:attach, text}), do: text
  defp line({:connection_down, reason}), do: Link.down_text(reason)

  # The way out comes first: the cut of the line keeps it.
  defp line({:reattach, reason}),
    do: "could not reattach to the newest session (helyx --new starts one): " <> sentence(reason)

  defp line(reason), do: "could not start the agent: " <> sentence(reason)

  defp sentence(:not_found),
    do: "no saved session for this directory; start one without --resume"

  # The ref stays out, as in the TUI notice: only a valid ref has a bound.
  defp sentence({:invalid_model_ref, _ref}), do: "the model ref is not valid; use provider/model"
  defp sentence({:unknown_provider, id}), do: "no provider has the id #{inspect(id)}"
  # The default model of `helyx serve`, an option of Core.
  defp sentence({:invalid_option, :model}), do: sentence({:invalid_model_ref, nil})

  defp sentence({:tool_unavailable, name, reason}),
    do: "the #{name} tool is not available: #{reason}"

  defp sentence({:terminal_init_failed, text}), do: "the terminal did not start: " <> text

  # The folder comes from the file, so it gets the clean pass and the width
  # of a list line.
  defp sentence({:not_a_directory, cwd}),
    do: ~s(not a directory: "#{Helyx.TUI.SessionList.folder(cwd)}")

  defp sentence(:invalid_cwd), do: "the directory is not UTF-8 or holds a NUL byte"

  # The errors of a start or a resume over the wire.
  defp sentence(:too_many_sessions), do: "the server runs as many sessions as it can"
  defp sentence({:start_failed, text}), do: text
  defp sentence(reason) when Link.wire_error?(reason), do: Link.error_text(reason)

  # The exit of the TUI when its session ends, or of print mode when the
  # session ends under it.
  defp sentence({:session_down, :crashed}), do: "the session crashed and stopped"
  # The session ended the subscription past its credits (docs/features/replay-ring.md).
  defp sentence({:session_down, :slow}), do: "the client fell behind the session events"
  defp sentence({:session_down, _reason}), do: "the session stopped"

  # A POSIX code gets its system text. Any other atom is not one.
  defp sentence(reason) when is_atom(reason) do
    case :file.format_error(reason) do
      ~c"unknown POSIX error" ++ _ -> inspect(reason)
      text -> to_string(text)
    end
  end

  defp sentence(reason), do: Helyx.Reason.text(reason)
end
