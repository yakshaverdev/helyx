defmodule CodingAgent do
  @moduledoc """
  The terminal coding agent: the TUI over the wire on the server of the
  data folder (`attach/2`), or print mode in the node, with Core, the
  bundled plugins, and one session (`run/1`). Started by `CodingAgent.CLI`,
  from the `helyx` release or `mix helyx`.
  """

  alias Helyx.Session.File.Scan
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
    Helyx.Tool.Bash,
    Helyx.Tool.Edit,
    Helyx.Tool.Write,
    Helyx.Tool.Agent,
    Helyx.Tool.Skill,
    Helyx.Tool.Question
  ]

  # The rotation threshold of the log file of a TUI run. The handler
  # writes a whole log record, then rotates when the file is over this
  # size, so a file can pass it by one record. It keeps one older file.
  @max_log_bytes 10_485_760

  @doc "The plugins the agent runs with."
  @spec plugins() :: [module()]
  def plugins, do: @plugins

  @doc """
  Starts Core and a session in the node, then runs print mode
  (`CodingAgent.Print.run/2`) on the prompt `:prompt`, which is required,
  and its exit status is the result; the TUI runs only over the wire
  (`attach/2`). The session is written under `:sessions_dir`, which is
  required. With `resume: true` the most recent session for `:cwd` that has
  a message is resumed, and with `resume: id` the session with that id,
  whose header must name `:cwd`. With `resume: id` and no `:cwd`, the
  session runs in the folder of its header, which must be an absolute path
  to a directory; the resume finds the id after the tool checks
  (`docs/features/server-management.md`, "Order of the checks"). A resumed
  session keeps its saved model. Returns `{:error, reason}` when the model
  ref, the plugin list, the resume, or the folder of the header is rejected.
  Core stops before `run/1` returns or raises.
  """
  @spec run(keyword()) :: CodingAgent.Print.status() | {:error, term()}
  def run(opts) do
    prompt = Keyword.fetch!(opts, :prompt)

    with {:ok, core} <- Helyx.Core.start_link(plugins: @plugins) do
      try do
        run_session(prompt, opts)
      after
        :ok = Supervisor.stop(core)
      end
    end
  end

  defp run_session(prompt, opts) do
    with {:ok, session} <- start_session(opts) do
      try do
        with {:ok, cwd} <- session_cwd(session, opts[:cwd]),
             do: CodingAgent.Print.run(session, CodingAgent.Print.skills(prompt, cwd))
      after
        # The abort comes before Core stops, so a turn that a signal or a
        # failed print left open ends and the hands release its resources. A
        # session that died returns `{:error, :session_not_found}`.
        _ = Helyx.Session.abort(session)
      end
    end
  end

  # With no `:cwd`, the folder is the one the session runs in. A folder of
  # a header comes from the file. A session that does not answer the live
  # list in time is left out of it.
  defp session_cwd(session, nil) do
    case Enum.find(Helyx.Sessions.list_live(session.core), &(&1.id == session.id)) do
      nil -> {:error, :session_not_found}
      %{cwd: cwd} -> directory(cwd)
    end
  end

  defp session_cwd(_session, cwd), do: {:ok, cwd}

  defp directory(cwd) do
    if Path.type(cwd) == :absolute and File.dir?(cwd),
      do: {:ok, cwd},
      else: {:error, {:not_a_directory, cwd}}
  end

  @doc """
  Runs the TUI over the wire until the user quits
  (`docs/features/tui-attach.md`, decisions 8 and 9). `socket` is the
  socket of `CodingAgent.Attach.connect/1`, which the caller owns and gives
  to the connection (`Helyx.TUI.Wire.Connection`); the TUI takes the
  connection and ends it at its quit. The options are those of `run/1`
  with no `:prompt`; `:model` is optional: with none, a new session gets
  the default model of the server; `resume: id` takes no `:cwd`; and
  `resume: :reattach` resumes the newest session of `:cwd`, or starts one
  when the folder has none (decision 16). The session starts or resumes in
  the server and runs on after the quit, which aborts nothing. After a
  lost connection the TUI connects again (`CodingAgent.Attach.connect/1`)
  and subscribes with `after` (decision 11). Returns
  `{:error, reason}` as `run/1` does, with the errors of the wire.
  """
  @spec attach(:gen_tcp.socket(), keyword()) :: :ok | {:error, term()}
  def attach(socket, opts) do
    {:ok, conn, ref} = Connection.open(socket)

    try do
      with {:ok, id, cwd, resumed} <- open_remote(conn, opts) do
        dir = Keyword.fetch!(opts, :sessions_dir)

        log_to_file(Path.join(dir, "tui.log"), fn ->
          Helyx.TUI.run(
            session: %Link{conn: conn, id: id},
            resumed: resumed,
            cwd: cwd,
            reconnect: reconnect(dir)
          )
        end)
      end
    after
      # The connection ended with the TUI that took it; one that no TUI
      # took ends here.
      Process.exit(conn, :kill)
      Process.demonitor(ref, [:flush])
    end
  end

  # After a lost connection the TUI attaches again to the server of the
  # data folder, and starts none (docs/features/tui-attach.md, decision 11).
  defp reconnect(dir) do
    fn ->
      with :none <- CodingAgent.Attach.connect(dir),
           do: {:error, "no server runs for #{dir}"}
    end
  end

  # The session over the wire, and its folder. `--session` finds the file
  # of the id as the node does (`Scan.find/2`), so its errors are those of
  # the node, and runs in the folder of its header, where the server
  # resumes it. The folder is checked before the open, so no session
  # starts in the server for a folder that the TUI refuses.
  defp open_remote(conn, opts) do
    case Keyword.get(opts, :resume, false) do
      id when is_binary(id) ->
        with {:ok, _path, header} <- Scan.find(Keyword.fetch!(opts, :sessions_dir), id),
             {:ok, cwd} <- folder(header["cwd"]),
             {:ok, id} <- Connection.resume(conn, id: id),
             do: {:ok, id, cwd, true}

      resume ->
        with {:ok, cwd} <- folder(opts[:cwd]),
             {:ok, id, resumed} <- start_or_resume(conn, resume, opts),
             do: {:ok, id, cwd, resumed}
    end
  end

  # A folder that is not UTF-8 has no JSON form, and a start refuses a NUL
  # byte: the answers of the node, in its order.
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

  @doc false
  # Runs `fun` with the `:default` log handler writing to the file `path`,
  # so that no log line draws on the terminal of the TUI, then puts the
  # earlier handler back. Public for its test.
  @spec log_to_file(Path.t(), (-> result)) :: result when result: term()
  def log_to_file(path, fun) do
    {:ok, default} = :logger.get_handler_config(:default)
    file = %{file: String.to_charlist(path), max_no_bytes: @max_log_bytes, max_no_files: 1}
    :ok = :logger.remove_handler(:default)

    try do
      :ok = :logger.add_handler(:default, :logger_std_h, %{default | config: file})
      fun.()
    after
      # The file handler is not there when its add failed.
      _ = :logger.remove_handler(:default)
      :ok = :logger.add_handler(:default, default.module, default)
    end
  end

  @doc """
  Returns the one line that tells the user about an error from `run/1`.
  A session that ended while the TUI ran (`{:session_down, reason}`) gives
  its sentence, and so does a session that another process has open
  (`{:session_locked, id}`); any other error is a failed start, and its sentence comes
  after `could not start the agent: `. There is a clause for every shape of `t:Helyx.Session.File.error/0`,
  for the model ref and provider errors, for a bad working directory
  (`:invalid_cwd`), for a header folder that is not a directory
  (`{:not_a_directory, cwd}`, a whole line with no prefix), for a tool
  that is not available, for the end of the session, and over the wire for
  a line of the attach (`{:attach, text}`) and the end of the connection
  (`{:connection_down, reason}`), whole lines with no prefix, for a newest
  session that does not reattach (`{:reattach, reason}`), and for the
  errors of the wire (`Helyx.TUI.Link.error_text/1`). The `:too_large`
  text is a sentence already and passes unchanged. An error with no clause
  prints through `Helyx.Reason.text/1`, so it holds no stacktrace. Every
  result gets one clean pass: a whitespace run becomes one space, and a
  control character or a byte that is not UTF-8 becomes `?`. The line then
  has at most 4000 bytes of valid UTF-8, the prefix included; a character
  cut in half is dropped.
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

  # The user opens a session that another process has open: the whole
  # line, with no prefix (docs/features/session-lock.md).
  defp line({:session_locked, _id} = reason), do: sentence(reason)

  # The folder of a session header, as the CLI shows a directory argument
  # that is not one.
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

  defp sentence(:not_regular), do: "the session file is not a regular file"
  defp sentence(:invalid_id), do: "not a session id"
  defp sentence(:duplicate_id), do: "more than one session file has this id"
  defp sentence({:too_large, text}), do: text

  # The text can be an exception message, and some of those have many lines.
  defp sentence({:invalid_file, text}),
    do: "the session file is damaged: " <> text

  defp sentence({:unknown_version, version}),
    do: "the session file has version #{inspect(version)}, which this build cannot read"

  defp sentence({:repair_failed, reason}),
    do: "could not repair the session file: " <> sentence(reason)

  defp sentence({:create_failed, reason}),
    do: "could not create the session file: " <> sentence(reason)

  # The ref stays out, as in the TUI notice: only a valid ref has a bound.
  defp sentence({:invalid_model_ref, _ref}), do: "the model ref is not valid; use provider/model"
  defp sentence({:unknown_provider, id}), do: "no provider has the id #{inspect(id)}"
  # The default model of `helyx serve`, an option of Core.
  defp sentence({:invalid_option, :model}), do: sentence({:invalid_model_ref, nil})

  defp sentence({:tool_unavailable, name, reason}),
    do: "the #{name} tool is not available: #{reason}"

  defp sentence({:terminal_init_failed, text}), do: "the terminal did not start: " <> text

  # The errors of the session lock (docs/features/session-lock.md).
  defp sentence({:session_locked, id}), do: "session #{id} is open in another process"
  defp sentence({:lock_failed, text}), do: "could not lock the session: " <> text
  defp sentence(:open_timeout), do: "the session file did not open in time"

  # The folder comes from the file, so it gets the clean pass and the width
  # of a list line.
  defp sentence({:not_a_directory, cwd}),
    do: ~s(not a directory: "#{Helyx.TUI.SessionList.folder(cwd)}")

  defp sentence(:invalid_cwd), do: "the directory is not UTF-8 or holds a NUL byte"

  # The errors of a start or a resume over the wire.
  defp sentence(:too_many_sessions), do: "the server runs as many sessions as it can"
  defp sentence({:start_failed, text}), do: text
  defp sentence(reason) when Link.wire_error?(reason), do: Link.error_text(reason)

  # The exit of the TUI when its session ends (`Helyx.Session.end_reason/1`),
  # or when the session is gone before the TUI subscribes.
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

  @doc """
  Starts or resumes the session `run/1` uses. Public so tests can drive the
  wiring on a Core of their own. `:core` defaults to `Helyx.Core`.
  """
  @spec start_session(keyword()) :: {:ok, Helyx.Session.t()} | {:error, term()}
  def start_session(opts) do
    core = Keyword.get(opts, :core, Helyx.Core)
    base = [sessions_dir: Keyword.fetch!(opts, :sessions_dir)] ++ Keyword.take(opts, [:cwd])

    case Keyword.get(opts, :resume, false) do
      false -> Helyx.Session.start(core, [model: Keyword.fetch!(opts, :model)] ++ base)
      true -> Helyx.Session.resume(core, base)
      id -> Helyx.Session.resume(core, [id: id] ++ base)
    end
  end
end
