defmodule Helyx.Tool do
  @moduledoc """
  A tool the model can call. The hands run it in the session's working
  directory.

  A tool plugin implements this behaviour. `name/0` is what the model calls.
  `parameters/0` is a JSON schema map with string keys. `run/2` gets the
  decoded argument map and the working directory, and returns the text the
  model sees. `{:error, text}` marks the result as an error; a tool that
  raises is reported the same way. `{:ok, text, ui_blocks}` and
  `{:error, text, ui_blocks}` add at most
  #{Helyx.UIBlock.max_result_blocks()} UI blocks for the clients
  (`Helyx.UIBlock`); the model never gets them. A list that fails
  `Helyx.UIBlock.check_list/1` is a return outside the contract
  (`docs/features/ui-blocks.md`). The hands make every result text valid
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

  A tool source exports `source/1` in place of `name/0`, `description/0`,
  and `parameters/0`: its source process puts the tools that it learns at
  run time (`announce/1`, `put_tools/2`, `launch/1`), and its `run/2` runs
  each of them. The source process traps exits: it ends at an `{:EXIT, pid,
  reason}` of a pid that is no server Task of its own, and Core kills it
  when its hands end. Core refuses any other plugin at its start with
  `{:invalid_tool_plugin, module}` (`docs/features/mcp-client.md`).

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
  @callback run(arguments :: map(), cwd :: String.t()) ::
              {:ok | :error, String.t()} | {:ok | :error, String.t(), [Helyx.UIBlock.t()]}
  @callback check() :: :ok | {:error, String.t()}
  @callback concurrent?() :: boolean()
  @callback release(handles :: [term()], mode :: :deliver | :cancel, deadline :: integer()) ::
              [term()]
  @callback source(%{core: Helyx.Core.name(), session_id: String.t(), cwd: String.t()}) :: term()

  @optional_callbacks name: 0, description: 0, parameters: 0, source: 1, check: 0
  @optional_callbacks concurrent?: 0, release: 3

  @doc """
  Builds the spec of each registered tool plugin, checks it, and returns
  the tools sorted by name. The session calls this once at start, so the
  callbacks `name/0`, `description/0`, and `parameters/0` run once per
  session, and every provider call uses the checked value.

  A spec is accepted when `name` is 1 to 52 bytes, each an ASCII letter, a
  digit, `_`, or `-`, `description` is a string of valid UTF-8, and `parameters` is a map with
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
      Enum.reduce_while(fixed(core), {:ok, []}, fn tool, {:ok, acc} ->
        case checked_spec(tool) do
          {:ok, spec} -> {:cont, {:ok, [{tool, spec} | acc]}}
          error -> {:halt, error}
        end
      end)

    with {:ok, tools} <- result,
         :ok <- check_unique(tools),
         do: {:ok, Enum.sort_by(keep(tools, only), fn {_tool, spec} -> spec.name end)}
  end

  defp fixed(core), do: Enum.reject(Helyx.Core.plugins(core, __MODULE__), &source?/1)

  @doc false
  # Whether `plugin` is a tool source (`source/1`).
  def source?(plugin), do: function_exported?(plugin, :source, 1)

  defp keep(tools, nil), do: tools
  defp keep(tools, only), do: Enum.filter(tools, fn {_tool, spec} -> spec.name in only end)

  defp checked_spec(tool) do
    spec = %{name: tool.name(), description: tool.description(), parameters: tool.parameters()}

    cond do
      not name?(spec.name) ->
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

  # The smallest name limit known among the providers is 64 bytes of this
  # set, and Claude Code shows a Helyx tool as `mcp__helyx__<name>`, 12 bytes
  # more (docs/features/mcp-client.md, decision 8).
  @name_pattern ~r/\A[A-Za-z0-9_-]{1,52}\z/

  @doc false
  def name?(value), do: is_binary(value) and Regex.match?(@name_pattern, value)

  defp parameters?(value) when is_map(value),
    do: Enum.all?(Map.keys(value), &is_binary/1) and Helyx.Message.encoded_size(value) != :error

  defp parameters?(_value), do: false

  @doc """
  Holds an opaque handle of a resource that a tool call or a provider
  process created, with the hands that run it. The hands keep the handle
  outside the Task and give it to the `release/3` of the tool or the
  provider. They release the handle of a tool call when the call delivers,
  or when its turn ends while the call runs. They release the handle of a
  provider process when the process ends, and the handles of every Task at
  the stop of the session. Once a release leaves a handle unconfirmed, the
  hands refuse every later tool call
  (`docs/features/tool-resource-release.md`). When the hands die first,
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
  the model ref of its turn, as `provider/model`, the `:provider_opts`
  of the session (`Helyx.Session.start/2`), and its ModelContext plugin,
  nil with none (`docs/features/session-model-context.md`), and `source`,
  the pid of the source process of a source tool, else nil. The hands set
  it when the call's Task starts, so it needs no call to them. A hook Task
  has the context of its call; a `before_settle` hook has no call, and
  its `tool` and `call_id` are nil (`docs/features/before-settle.md`).
  Raises in any other process (`docs/features/agent-tool.md`).
  """
  @spec context() :: %{
          core: Helyx.Core.name(),
          session_id: String.t(),
          tools: [String.t()],
          tool: String.t() | nil,
          call_id: String.t() | nil,
          model: String.t(),
          provider_opts: keyword(),
          model_context: module() | nil,
          source: pid() | nil
        }
  def context do
    case Process.get(:helyx_call) do
      %{} = context -> context
      nil -> raise ArgumentError, "context/0 runs only in a tool call"
    end
  end

  @doc """
  Asks the clients of the session and waits for the first answer: a JSON
  object that a client gave with `Helyx.Session.answer/3`. The session
  emits `request`, a JSON object of valid UTF-8 whose JSON is at most
  #{Helyx.Session.Ask.max_request_bytes()} bytes, in an `:ask` event with a new ask id, the
  call id, and the tool name. `{:error, :no_client}` at once when no
  subscriber can answer (`Helyx.Session.subscribe/2`, `answers: true`),
  and `{:error, :not_running}` when the call is not a running call of the
  current turn, such as a background run, or when the caller is not the
  call's own Task, such as a hook Task or a process that the tool started
  (`docs/features/hooks.md`), or when the call's result is already in the
  transcript, which also ends an open ask. The wait has no timeout: the end
  of the turn ends it, and the hands kill the call. A request with the key `"kind"` is
  an input UI block, such as a `form`: it must also pass
  `Helyx.UIBlock.envelope?/1`. Raises on any other request and
  outside a tool call (`docs/features/question-tool.md`,
  `docs/features/ui-blocks.md`).
  """
  @spec ask(map()) :: {:ok, map()} | {:error, :no_client | :not_running}
  def ask(request), do: Helyx.Session.Ask.ask(:tool, request)

  @doc """
  Shows a UI block during the calling tool call: the session emits it in a
  `:ui_block` event with the call id and `key`, valid UTF-8 of 1 to 64
  bytes. A later block with the same key replaces it; a client drops the
  blocks of the call at its result. The block is checked here with
  `Helyx.UIBlock.check/1`, and one over the bound is cut. Waits for the
  session: `:ok`; `{:error, :not_running}` when the caller is not the
  call's own Task of a running call of the current turn (a background run,
  a hook Task, or a process that the tool started), or when the call's
  result is already in the transcript; `{:error, :too_many_blocks}` for a
  new block when the turn holds #{Helyx.UIBlock.max_turn_blocks()} blocks, and
  for a call whose request came past the Helyx call ids of the turn.
  Raises on a bad key or block, on a new key past
  #{Helyx.UIBlock.max_keys()} for the call, and outside a tool call
  (`docs/features/ui-blocks.md`).
  """
  @spec show(String.t(), Helyx.UIBlock.t()) :: :ok | {:error, :not_running | :too_many_blocks}
  def show(key, block) do
    %{core: core, session_id: id, call_id: call_id} = context()

    if not Helyx.UIBlock.key?(key),
      do: raise(ArgumentError, "a UI block key is valid UTF-8 of 1 to 64 bytes")

    block =
      case Helyx.UIBlock.check(block) do
        {:ok, block} -> block
        :error -> raise ArgumentError, "show/2 needs a UI block"
      end

    request = {:ui_block, call_id, key, block}

    case GenServer.call(Helyx.Session.Server.via(core, id), request, :infinity) do
      :too_many ->
        raise ArgumentError, "a call shows at most #{Helyx.UIBlock.max_keys()} UI blocks"

      reply ->
        reply
    end
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
  def background do
    with {:ok, _place} = place <-
           GenServer.call(Process.get(:helyx_hands), :background, :infinity) do
      # The `after_tool` hooks of `started/1` run only with a place.
      Process.put(:helyx_place, true)
      place
    end
  end

  @doc """
  Gives the start answer of a background run: `text` becomes the result of
  the call once the `after_tool` hooks ran on it, which can replace its
  text and its status (`docs/features/hooks.md`), and the tool's Task
  leaves its turn. It returns once the session took the start answer, so
  an ask of the run after it gets `{:error, :not_running}`. The Task then
  runs on; its return value, or its crash, is the end of the run. Raises
  in a Task that is no tool call of a turn, such as a run that gave its
  start answer, and in a tool call that took no place with
  `background/0`. Exits outside the hands, as `hold/1` does.
  """
  @spec started(String.t()) :: :ok
  def started(text) when is_binary(text) do
    # The `after_tool` hooks run on the start answer, in the call Task
    # (docs/features/hooks.md).
    result = Helyx.Session.Hands.Chain.after_start({:ok, text})

    case GenServer.call(Process.get(:helyx_hands), {:started, result}, :infinity) do
      # The session took the start answer before it lets the run go on.
      :ok -> Helyx.Session.Ask.await_go()
      :no_place -> raise ArgumentError, "started/1 needs a place from background/0"
    end
  end

  @doc """
  Starts `fun` in a server Task of the hands, from a source process, and
  returns a ref at once. The hands answer `{ref, {:ok, pid}}`, or `{ref,
  {:error, :unconfirmed | :too_many_tasks}}` (16 server Tasks per source).
  The Task links to its source before `fun` runs and does not trap exits;
  its `hold/1` handles go to the plugin's `release/3` when it ends, and
  then the source gets `{ref, :released, :ok | :unconfirmed}`. Exits
  outside a source process (`docs/features/mcp-client.md`).
  """
  @spec launch((-> term())) :: reference()
  def launch(fun) when is_function(fun, 0) do
    source!()
    ref = make_ref()
    GenServer.cast(Process.get(:helyx_hands), {:source, {:launch, ref, self(), fun}})
    ref
  end

  @doc """
  Names every group of the calling source once, before `put_tools/2`: a
  list of distinct strings of 1 to 64 bytes of UTF-8, each `:starting`.
  Past 64 groups in the session the first by name order stay, and a notice
  names the rest. A second call, a bad list, and a call outside a source
  process exit the caller.
  """
  @spec announce([String.t()]) :: :ok
  def announce(groups), do: source_call({:announce, groups})

  @doc """
  Puts a group that the source announced: `:starting`, `{:ok, entries}`,
  or `{:error, text}`. Each replaces the group's entries; `:starting` and
  an error leave none. An entry is `%{name:, description:, parameters:,
  exposure: :direct}`; the session rejects one entry that breaks a bound
  with a notice, keeps the rest, and rejects a group whole when the
  session would hold more than 1,024 source entries. The bounds are in
  `docs/features/mcp-client.md`, "Bounds". Any other value, a group that
  was not kept, and a call outside a source process exit the caller.
  """
  @spec put_tools(String.t(), :starting | {:ok, [map()]} | {:error, String.t()}) :: :ok
  def put_tools(group, value), do: source_call({:put_tools, group, value})

  defp source_call(request) do
    source!()

    case GenServer.call(Process.get(:helyx_session), request, :infinity) do
      :ok -> :ok
      :error -> exit({:bad_source_call, elem(request, 0)})
    end
  end

  defp source!, do: if(Process.get(:helyx_source), do: :ok, else: exit(:not_a_tool_source))
end
