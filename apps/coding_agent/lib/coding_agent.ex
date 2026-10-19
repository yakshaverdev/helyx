defmodule CodingAgent do
  @moduledoc """
  The terminal coding agent: Core with the bundled plugins, one session, and
  the TUI. Started by `CodingAgent.CLI`, from the `helyx` release or `mix helyx`.
  """

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
  Starts Core and a session, then runs the TUI until the user quits. With
  `:prompt`, print mode (`CodingAgent.Print.run/2`) runs that one prompt in
  place of the TUI, and its exit status is the result. The
  session is written under `:sessions_dir`, which is required. With
  `resume: true` the most recent session for `:cwd` that has a message is
  resumed, and with `resume: id` the session with that id, whose header must
  name `:cwd`. With `resume: id` and no `:cwd`, the session runs in the
  folder of its header, which must be an absolute path to a directory; the
  resume finds the id after the tool checks
  (`docs/features/server-management.md`, "Order of the checks"). A resumed
  session keeps its saved model. Returns `{:error, reason}` when the model
  ref, the plugin list, the resume, or the folder of the header is rejected.
  Core stops before `run/1` returns or raises.
  """
  @spec run(keyword()) :: :ok | CodingAgent.Print.status() | {:error, term()}
  def run(opts) do
    with {:ok, core} <- Helyx.Core.start_link(plugins: @plugins) do
      try do
        run_session(opts)
      after
        :ok = Supervisor.stop(core)
      end
    end
  end

  defp run_session(opts) do
    with {:ok, session} <- start_session(opts) do
      try do
        with {:ok, cwd} <- session_cwd(session, opts[:cwd]),
             do: client(session, Keyword.put(opts, :cwd, cwd))
      after
        # The abort comes before Core stops, so a turn that the quit or a
        # failed TUI left open ends and the hands release its resources. A
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
      nil ->
        {:error, :session_not_found}

      %{cwd: cwd} ->
        if Path.type(cwd) == :absolute and File.dir?(cwd),
          do: {:ok, cwd},
          else: {:error, {:not_a_directory, cwd}}
    end
  end

  defp session_cwd(_session, cwd), do: {:ok, cwd}

  defp client(session, opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, prompt} ->
        prompt = CodingAgent.Print.skills(prompt, Keyword.fetch!(opts, :cwd))
        CodingAgent.Print.run(session, prompt)

      :error ->
        log_to_file(Path.join(Keyword.fetch!(opts, :sessions_dir), "tui.log"), fn ->
          Helyx.TUI.run(
            session: session,
            resumed: Keyword.get(opts, :resume, false) != false,
            cwd: Keyword.fetch!(opts, :cwd),
            sessions_dir: Keyword.fetch!(opts, :sessions_dir)
          )
        end)
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
  that is not available, and for the end of the session. The `:too_large`
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
  wiring without the terminal. `:core` defaults to `Helyx.Core`.
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
