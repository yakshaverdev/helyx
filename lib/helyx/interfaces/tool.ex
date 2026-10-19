defmodule Helyx.Tool do
  @moduledoc """
  A tool the model can call. The hands run it in the session's working
  directory.

  A tool plugin implements this behaviour. `name/0` is what the model calls.
  `parameters/0` is a JSON schema map with string keys. `run/2` gets the
  decoded argument map and the working directory, and returns the text the
  model sees. `{:error, text}` marks the result as an error; a tool that
  raises is reported the same way. The hands make every result text valid
  UTF-8 and cut a text over `Helyx.Message.max_result_bytes/0` to a notice
  line, its head, a marker line, and its tail (`Helyx.Message.cut_result/1`).

  The optional `check/0` runs once per session start or resume, in the
  caller, before any file or process is created (`check_available/1`). A
  tool that needs something from the system, an executable for example,
  reports it missing there. Then the session fails to start with a clear
  error, and no call fails later for that reason.

  A tool that creates an OS resource, a process group for example, holds it
  with `hold/1` before the external work starts, and implements the
  optional `release/3`. The hands call `release(handles, mode, deadline)`
  with the handles of a call when it delivers (`:deliver`), and when its
  turn is aborted (`:cancel`). `deadline` is absolute, in
  `System.monotonic_time(:millisecond)` on the node of the hands. The return
  value is the handles still held; `[]` means every one is released. The
  callback must not wait past the deadline. The tool must also free the
  resource by itself when its Task dies with no release, because the hands
  can die first and drop a late `hold/1` (ADR 0004).

  `context/0` gives a call its Core, its session, the tool names of the
  session, its call id, the model of its turn, and the provider options of
  the session, for a tool that starts a session of its own.

  The optional `concurrent?/0` returns `true` for a tool whose calls can
  run at the same time as other calls of concurrent tools: a tool that
  only reads, for example. A call of any other tool runs alone. At most 8
  calls run at once in a turn (`docs/features/concurrent-tool-calls.md`).

  A call can go on in the background: the tool takes a place with
  `background/0` before the external work starts, gives its start answer
  with `started/1`, and keeps running. Its return value is then the end of
  the run, which reaches the session as a user message. An abort of the
  turn does not end it; the stop of the session does
  (`docs/features/background-bash.md`).
  """

  use Helyx.Interface, mode: :multi

  @type spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback run(arguments :: map(), cwd :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  @callback check() :: :ok | {:error, String.t()}
  @callback concurrent?() :: boolean()
  @callback release(
              handles :: [term()],
              mode :: :deliver | :cancel,
              deadline :: integer()
            ) ::
              [term()]

  @optional_callbacks check: 0, concurrent?: 0, release: 3

  @doc """
  Builds the spec of each registered tool plugin, checks it, and returns
  the tools sorted by name. The session calls this once at start, so the
  callbacks `name/0`, `description/0`, and `parameters/0` run once per
  session, and every provider call uses the checked value.

  A spec is accepted when `name` is a non-empty string of valid UTF-8,
  `description` is a string of valid UTF-8, and `parameters` is a map with
  string keys at the top level that `Helyx.Message.encoded_size/1` accepts.
  Otherwise the result is `{:error, {:bad_tool_spec, label}}`: the label is
  the name when the name is accepted, else the module name. Plugin code that
  raises, throws, or exits while a spec is built is not contained. Two tools
  with one name give `{:error, {:duplicate_tool_name, name}}`. With a list
  `only`, the result keeps only the tools that it names, after the checks.
  """
  @spec specs(Helyx.Core.name(), [String.t()] | nil) ::
          {:ok, [{module(), spec()}]}
          | {:error, {:bad_tool_spec, String.t()} | {:duplicate_tool_name, String.t()}}
  def specs(core, only \\ nil) do
    result =
      Enum.reduce_while(Helyx.Core.plugins(core, __MODULE__), {:ok, []}, fn tool, {:ok, acc} ->
        case checked_spec(tool) do
          {:ok, spec} -> {:cont, {:ok, [{tool, spec} | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, tools} <- result,
         :ok <- check_unique(tools),
         do: {:ok, Enum.sort_by(keep(tools, only), fn {_tool, spec} -> spec.name end)}
  end

  defp keep(tools, nil), do: tools
  defp keep(tools, only), do: Enum.filter(tools, fn {_tool, spec} -> spec.name in only end)

  defp checked_spec(tool) do
    spec = %{name: tool.name(), description: tool.description(), parameters: tool.parameters()}

    cond do
      not text?(spec.name) or spec.name == "" ->
        {:error, {:bad_tool_spec, inspect(tool)}}

      not text?(spec.description) or not parameters?(spec.parameters) ->
        {:error, {:bad_tool_spec, spec.name}}

      true ->
        {:ok, spec}
    end
  end

  @doc """
  Runs the optional `check/0` of each tool that `specs/1` returned, in that
  order, and stops at the first failure. `{:error, reason}` with a reason
  of valid UTF-8 gives `{:error, {:tool_unavailable, name, reason}}`, where
  `name` is the checked spec name. Any other value but `:ok` raises in the
  caller, as a `check/0` that raises, throws, or exits does: Core does not
  contain it.
  """
  @spec check_available([{module(), spec()}]) ::
          :ok | {:error, {:tool_unavailable, String.t(), String.t()}}
  def check_available(tools) do
    Enum.find_value(tools, :ok, fn {tool, spec} ->
      case run_check(tool) do
        :ok -> nil
        {:error, reason} -> {:error, {:tool_unavailable, spec.name, reason}}
      end
    end)
  end

  defp run_check(tool) do
    if function_exported?(tool, :check, 0), do: checked_result(tool.check()), else: :ok
  end

  @doc """
  The names of the tools that `specs/1` returned whose optional
  `concurrent?/0` returns `true`; a tool without it is not concurrent.
  The session calls this once per session start or resume, in the
  caller, after `check_available/1` and before it creates any file. A
  return other than a boolean raises there, as a `concurrent?/0`
  that raises, throws, or exits does: Core does not contain it.
  """
  @spec concurrent([{module(), spec()}]) :: MapSet.t(String.t())
  def concurrent(tools),
    do: MapSet.new(for {tool, spec} <- tools, concurrent?(tool), do: spec.name)

  defp concurrent?(tool) do
    if function_exported?(tool, :concurrent?, 0) do
      concurrent? = tool.concurrent?()
      true = is_boolean(concurrent?)
      concurrent?
    else
      false
    end
  end

  defp checked_result(:ok), do: :ok

  defp checked_result({:error, reason} = error) when is_binary(reason) do
    true = String.valid?(reason)
    error
  end

  defp check_unique(tools) do
    names = Enum.map(tools, fn {_tool, spec} -> spec.name end)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [dup | _] -> {:error, {:duplicate_tool_name, dup}}
    end
  end

  defp text?(value), do: is_binary(value) and String.valid?(value)

  defp parameters?(value) when is_map(value),
    do: Enum.all?(Map.keys(value), &is_binary/1) and Helyx.Message.encoded_size(value) != :error

  defp parameters?(_value), do: false

  @doc """
  Holds an opaque handle of a resource that a tool call or a provider
  process created, with the hands that run it. The hands keep the handle
  outside the Task and give it to the `release/3` of the tool or the
  provider. They release the handle of a tool call when the call delivers,
  or when its turn ends while the call runs. They release the handle of a
  provider process when the process ends. Once a release leaves a handle
  unconfirmed, the hands refuse every later tool call
  (`docs/features/tool-resource-release.md`). When the hands stop first,
  no release runs: the tool or the provider must free the resource when
  its own process dies (ADR 0004).
  Returns only when the hands hold the handle, so work that starts after it
  is never unheld. Exits when the caller runs outside the hands, such as
  `stream/3` in the model Task of `Helyx.Provider.Loop`: a provider holds
  only from the callbacks of its provider process. Raises when the tool or
  the provider does not implement `release/3`.
  """
  @spec hold(term()) :: :ok
  def hold(handle) do
    case GenServer.call(Process.get(:helyx_hands), {:hold, handle}, :infinity) do
      :ok -> :ok
      :no_release -> raise ArgumentError, "a tool without release/3 cannot hold a resource"
    end
  end

  @doc """
  Ends the hold of handles whose resources the caller released itself
  with its own `release/3`, such as the program of a provider process that
  another program replaced. Only a handle that the release confirmed may
  go: the hands then do not release it again. A handle that the caller
  does not hold changes nothing. Exits outside the hands, as `hold/1`.
  """
  @spec unhold([term()]) :: :ok
  def unhold(handles) when is_list(handles) do
    # An improper list fails here, in the caller, and not in the hands.
    false = List.improper?(handles)
    GenServer.call(Process.get(:helyx_hands), {:unhold, handles}, :infinity)
  end

  @doc """
  The context of the calling tool call: its Core, the id of its session,
  the tool names of the session, the name of the called tool, its call id,
  the model ref of its turn, as `provider/model`, and the `:provider_opts`
  of the session (`Helyx.Session.start/2`). The hands set it when the
  call's Task starts, so it needs no call to them.
  Raises in any other process (`docs/features/agent-tool.md`).
  """
  @spec context() :: %{
          core: Helyx.Core.name(),
          session_id: String.t(),
          tools: [String.t()],
          tool: String.t(),
          call_id: String.t(),
          model: String.t(),
          provider_opts: keyword()
        }
  def context do
    case Process.get(:helyx_call) do
      %{} = context -> context
      nil -> raise ArgumentError, "context/0 runs only in a tool call"
    end
  end

  # The most bytes of the JSON of a request to `ask/1`.
  @max_request_bytes 65_536

  @doc """
  Asks the clients of the session and waits for the first answer: a JSON
  object that a client gave with `Helyx.Session.answer/3`. The session
  emits `request`, a JSON object of valid UTF-8 whose JSON is at most
  #{@max_request_bytes} bytes, in an `:ask` event with a new ask id, the
  call id, and the tool name. `{:error, :no_client}` at once when no
  subscriber can answer (`Helyx.Session.subscribe/2`, `answers: true`),
  and `{:error, :not_running}` when the call is not a running call of the
  current turn, such as a background run. The wait has no timeout: the end of the turn
  ends it, and the hands kill the call. Raises on any other request and
  outside a tool call (`docs/features/question-tool.md`).
  """
  @spec ask(map()) :: {:ok, map()} | {:error, :no_client | :not_running}
  def ask(request) do
    %{core: core, session_id: id, call_id: call_id, tool: tool} = context()

    if Helyx.Session.Input.json_object(request, @max_request_bytes) != :ok,
      do: raise(ArgumentError, "an ask request is a JSON object of at most 64 KiB")

    GenServer.call(Helyx.Session.Server.via(core, id), {:ask, call_id, tool, request}, :infinity)
  end

  @doc """
  Returns the messages of the session that runs the calling Task of the
  hands, as the session holds them when it answers: from the first message
  that its stored summary keeps (`Helyx.Summary.kept/2`), or all of them with no
  summary. A tool result reaches the transcript through the provider's own
  events, so the result of an earlier call of the same assistant message
  can be missing. The call has no deadline, because the session never waits
  for a Task of the hands, and it exits when the session ends
  (`docs/features/skills.md`). Exits outside the hands, as `hold/1` does.
  """
  @spec transcript() :: [Helyx.Message.t()]
  def transcript, do: GenServer.call(Process.get(:helyx_session), :transcript, :infinity)

  @doc """
  Takes a place for a background run of the calling tool call, before its
  external work starts. Returns the id of the run and the background
  folder of the session, mode `0700`, which the session deletes at its
  stop; a tool keeps its files there, named by the id. `{:error, text}`
  with no place: the session's 16 places are taken, the folder cannot be
  made, or the caller is a Task of the hands that is no tool call. A
  second call gives a new id in the same place. A run that gave its start
  answer keeps its place until a turn takes its end; any other call frees
  it when its Task ends. Exits outside the hands, as `hold/1` does.
  """
  @spec background() :: {:ok, %{id: String.t(), dir: String.t()}} | {:error, String.t()}
  def background, do: GenServer.call(Process.get(:helyx_hands), :background, :infinity)

  @doc """
  Gives the start answer of a background run: `text` becomes the result of
  the call at once, and the tool's Task leaves its turn. The Task then
  runs on; its return value, or its crash, is the end of the run. Raises
  in a Task that is no tool call of a turn, such as a run that gave its
  start answer, and in a tool call that took no place with
  `background/0`. Exits outside the hands, as `hold/1` does.
  """
  @spec started(String.t()) :: :ok
  def started(text) when is_binary(text) do
    case GenServer.call(Process.get(:helyx_hands), {:started, text}, :infinity) do
      :ok -> :ok
      :no_place -> raise ArgumentError, "started/1 needs a place from background/0"
    end
  end
end
