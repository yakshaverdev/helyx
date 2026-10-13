defmodule CodingAgent do
  @moduledoc """
  The terminal coding agent: Core with the bundled plugins, one session, and
  the TUI. Started by `CodingAgent.CLI`, from the `helyx` release or `mix helyx`.
  """

  @plugins [
    Helyx.Provider.OpenAI.Go,
    Helyx.Provider.OpenAI.Zen,
    Helyx.Provider.Fake,
    Helyx.Provider.ClaudeCode,
    Helyx.Provider.Codex,
    Helyx.ModelContext.Default,
    Helyx.Compaction.None,
    Helyx.Tool.Read,
    Helyx.Tool.Bash,
    Helyx.Tool.Edit,
    Helyx.Tool.Write
  ]

  # The bound of the error line, the one of `Helyx.Reason.text/1`.
  @max_line_bytes 4000

  @doc "The plugins the agent runs with."
  @spec plugins() :: [module()]
  def plugins, do: @plugins

  @doc """
  Starts Core and a session, then runs the TUI until the user quits. The
  session is written under `:sessions_dir`, which is required. With
  `resume: true` the most recent session for `:cwd` that has a message is
  resumed, and with `resume: id` the session with that id, whose header must
  name `:cwd`. A resumed session keeps its saved model. Returns `{:error, reason}` when the model ref, the
  plugin list, or the resume is rejected. Core stops before `run/1` returns
  or raises.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
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
        Helyx.TUI.run(
          session: session,
          resumed: Keyword.get(opts, :resume, false) != false,
          cwd: Keyword.fetch!(opts, :cwd)
        )
      after
        # The abort comes before Core stops, so a turn that the quit or a
        # failed TUI left open ends and the hands release its resources. A
        # session that died returns `{:error, :session_not_found}`.
        _ = Helyx.Session.abort(session)
      end
    end
  end

  @doc """
  Returns the one line that tells the user about an error from `run/1`.
  A session that ended while the TUI ran (`{:session_down, reason}`) gives
  its sentence; any other error is a failed start, and its sentence comes
  after `could not start the agent: `. There is a clause for every shape of `t:Helyx.Session.File.error/0`,
  for the model ref and provider errors, for a bad working directory
  (`:invalid_cwd`), for a tool that is not available, and for the end of
  the session. The `:too_large`
  text is a sentence already and passes unchanged. An error with no clause
  prints through `Helyx.Reason.text/1`, so it holds no stacktrace. Every
  result gets one clean pass: a whitespace run becomes one space, and a
  control character or a byte that is not UTF-8 becomes `?`. The line then
  has at most 4000 bytes of valid UTF-8, the prefix included; a character
  cut in half is dropped.
  """
  @spec error_text(term()) :: String.t()
  def error_text(reason), do: reason |> line() |> one_line() |> cut()

  @doc """
  The clean pass of a text for the terminal: a whitespace run becomes one
  space, whitespace at the ends goes, and a control or format character or
  a byte that is not UTF-8 becomes `?`. The result has no length bound.
  """
  @spec one_line(String.t()) :: String.t()
  def one_line(text) do
    text
    |> String.replace_invalid("?")
    |> String.split()
    |> Enum.join(" ")
    |> String.replace(~r/\p{C}/u, "?")
  end

  # A clause can hold plugin text or a value from the session file, so the
  # cap is on the whole line.
  defp cut(line),
    do:
      line |> binary_part(0, min(@max_line_bytes, byte_size(line))) |> String.replace_invalid("")

  defp line({:session_down, _reason} = reason), do: sentence(reason)
  defp line(reason), do: "could not start the agent: " <> sentence(reason)

  defp sentence(:not_found),
    do: "no saved session for this directory; start one without --resume"

  defp sentence(:not_regular), do: "the session file is not a regular file"
  defp sentence(:invalid_id), do: "not a session id"
  defp sentence(:duplicate_id), do: "more than one session file has this id"
  defp sentence({:too_large, text}) when is_binary(text), do: text

  # The text can be an exception message, and some of those have many lines.
  defp sentence({:invalid_file, text}) when is_binary(text),
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

  defp sentence({:tool_unavailable, name, reason}) when is_binary(name) and is_binary(reason),
    do: "the #{name} tool is not available: #{reason}"

  defp sentence({:terminal_init_failed, text}) when is_binary(text),
    do: "the terminal did not start: " <> text

  defp sentence(:invalid_cwd), do: "the directory is not UTF-8 or holds a NUL byte"

  # The exit of the TUI when its session ends (`Helyx.Session.end_reason/1`),
  # or when the session is gone before the TUI subscribes.
  defp sentence({:session_down, :crashed}), do: "the session crashed and stopped"
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
    cwd = Keyword.fetch!(opts, :cwd)
    dir = Keyword.fetch!(opts, :sessions_dir)

    case Keyword.get(opts, :resume, false) do
      false ->
        Helyx.Session.start(core,
          model: Keyword.fetch!(opts, :model),
          cwd: cwd,
          sessions_dir: dir
        )

      true ->
        Helyx.Session.resume(core, sessions_dir: dir, cwd: cwd)

      id ->
        Helyx.Session.resume(core, sessions_dir: dir, cwd: cwd, id: id)
    end
  end
end
