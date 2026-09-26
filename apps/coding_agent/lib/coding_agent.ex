defmodule CodingAgent do
  @moduledoc """
  The terminal coding agent: Core with the bundled plugins, one session, and
  the TUI. Started with `mix helyx`.
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

  @doc "The plugins the agent runs with."
  @spec plugins() :: [module()]
  def plugins, do: @plugins

  @doc """
  Starts Core and a session, then runs the TUI until the user quits. The
  session is written under `:sessions_dir` (default `~/.helyx/sessions`);
  with `resume: true` the most recent session for `:cwd` is resumed and
  keeps its saved model. Returns `{:error, reason}` when the model ref, the
  plugin list, or the resume is rejected.
  """
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts) do
    with {:ok, _core} <- Helyx.Core.start_link(plugins: @plugins),
         {:ok, session} <- start_session(opts) do
      result = Helyx.TUI.run(session: session, resumed: opts[:resume] == true)

      # Quitting mid-turn must not leave shell process groups running after
      # the VM stops; only abort makes the hands kill them and wait. A
      # session that died has no turn for abort to reach (ticket #45), and
      # the abort returns `{:error, :session_not_found}`.
      _ = Helyx.Session.abort(session)

      result
    end
  end

  @doc """
  Returns one sentence on one line that tells the user about an error from
  `run/1`. It has a clause for every shape of `t:Helyx.Session.File.error/0`,
  for the model ref and provider errors, for a bad working directory
  (`:invalid_cwd`), and for a tool that is not available. The `:too_large`
  text is a sentence already and passes unchanged. An error with no clause
  prints through `inspect/1`. Every result gets one clean pass: a whitespace
  run becomes one space, and a control character or a byte that is not UTF-8
  becomes `?`.
  """
  @spec error_text(term()) :: String.t()
  def error_text(reason) do
    reason
    |> sentence()
    |> String.replace_invalid("?")
    |> String.split()
    |> Enum.join(" ")
    |> String.replace(~r/\p{C}/u, "?")
  end

  defp sentence(:not_found),
    do: "no saved session for this directory; start one without --resume"

  defp sentence(:not_regular), do: "the session file is not a regular file"
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
  defp sentence({:bad_provider_turn, id}), do: "the provider #{inspect(id)} has a bad turn/0"

  defp sentence({:tool_unavailable, name, reason}) when is_binary(name) and is_binary(reason),
    do: "the #{name} tool is not available: #{reason}"

  defp sentence({:terminal_init_failed, text}) when is_binary(text),
    do: "the terminal did not start: " <> text

  defp sentence(:invalid_cwd), do: "the directory is not UTF-8 or holds a NUL byte"

  # A POSIX code gets its system text. Any other atom is not one.
  defp sentence(reason) when is_atom(reason) do
    case :file.format_error(reason) do
      ~c"unknown POSIX error" ++ _ -> inspect(reason)
      text -> to_string(text)
    end
  end

  defp sentence(reason), do: inspect(reason)

  @doc """
  Starts or resumes the session `run/1` uses. Public so tests can drive the
  wiring without the terminal. `:core` defaults to `Helyx.Core`.
  """
  @spec start_session(keyword()) :: {:ok, Helyx.Session.t()} | {:error, term()}
  def start_session(opts) do
    core = Keyword.get(opts, :core, Helyx.Core)
    cwd = Keyword.fetch!(opts, :cwd)
    dir = opts[:sessions_dir] || Path.expand("~/.helyx/sessions")

    if opts[:resume] do
      Helyx.Session.resume(core, sessions_dir: dir, cwd: cwd)
    else
      Helyx.Session.start(core,
        model: Keyword.fetch!(opts, :model),
        cwd: cwd,
        sessions_dir: dir
      )
    end
  end
end
