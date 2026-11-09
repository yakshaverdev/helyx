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
  caller, before any file or process is created (`check_available/1`): a
  tool that needs something from the system reports it missing there, the
  session fails to start with a clear error, and no call fails later for it.
  The optional `concurrent?/0` returns `true` for a tool whose calls can run
  with other calls of concurrent tools; any other call runs alone, and at
  most 8 calls of a turn run at once (`concurrent-tool-calls.md`).

  A tool that creates an OS resource holds it with `hold/1` before the
  external work starts and implements the optional `release/3`: the hands
  call `release(handles, mode, deadline)` when a call delivers (`:deliver`)
  and when its turn is aborted (`:cancel`), with an absolute `deadline` in
  `System.monotonic_time(:millisecond)` on the node of the hands that the
  callback must not pass, and keep only the handles it returns. It also frees the
  resource when its Task dies with no release (ADR 0004). `context/0`,
  `ask/1`, `transcript/0`, and the background runs of `background/0` and
  `started/1` are for a call; a background run outlives the normal end of its
  turn, an abort or a failure of the turn revokes it, and the stop of the
  session ends it (`background-bash.md`, ADR 0014).

  A tool source exports `source/1` in place of `name/0`, `description/0`,
  and `parameters/0`: its source process puts the tools that it learns at
  run time (`announce/1`, `put_tools/2`, `launch/1`), and its `run/2` runs
  each of them. Its process traps exits, and Core kills it when its hands
  end; any other exit signal but a kill is a message, and the source must
  end at an `{:EXIT, pid, reason}` of a pid that is no server Task of its
  own. Core refuses any other plugin at its start with `{:invalid_tool_plugin,
  module}`. A tool call finds and activates the deferred tools of the sources
  with `deferred/2` and `activate/1` (`docs/features/mcp-client.md`).
  """

  use Helyx.Interface, mode: :multi

  alias Helyx.Session.ToolSpecs

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
  def specs(core, only \\ nil), do: ToolSpecs.specs(core, only)

  @doc false
  def source?(plugin), do: function_exported?(plugin, :source, 1)

  @doc """
  Runs the optional `check/0` of each tool in order and stops at the first
  failure: `{:error, {:tool_unavailable, name, reason}}`. Any other value
  but `:ok` raises in the caller (`docs/features/coding-agent.md`).
  """
  @spec check_available([{module(), spec()}]) ::
          :ok | {:error, {:tool_unavailable, String.t(), String.t()}}
  def check_available(tools), do: ToolSpecs.check_available(tools)

  @doc """
  The names of the tools whose optional `concurrent?/0` returns `true`; a
  tool without it is not concurrent. A return other than a boolean raises
  (`docs/features/concurrent-tool-calls.md`).
  """
  @spec concurrent([{module(), spec()}]) :: MapSet.t(String.t())
  def concurrent(tools), do: ToolSpecs.concurrent(tools)

  @doc false
  def name?(value), do: ToolSpecs.name?(value)

  @doc """
  Holds an opaque handle of a resource that a tool call or a provider
  process created, with the hands that run it: they keep it outside the
  Task and give it to the plugin's `release/3` when the call delivers, when
  its turn ends while it runs, when a provider process ends, and at the
  stop of the session. Once a release leaves a handle unconfirmed, the
  hands refuse every later tool call (`tool-resource-release.md`). When the
  hands die first, no release runs, and the plugin frees the resource when
  its own process dies (ADR 0004). Returns only when the hands hold the
  handle. Exits outside the hands, such as in `stream/3` in the model Task
  of `Helyx.Provider.Loop`; raises for a plugin with no `release/3`.
  """
  @spec hold(term()) :: :ok
  def hold(handle) do
    case GenServer.call(Process.get(:helyx_hands), {:hold, handle}, :infinity) do
      :ok -> :ok
      :no_release -> raise ArgumentError, "a tool without release/3 cannot hold a resource"
    end
  end

  @doc """
  Ends the hold of handles whose resources the caller released itself with
  its own `release/3`, such as the program of a provider process that
  another program replaced; only handles that the release confirmed go. A
  handle that the caller does not hold changes nothing. Exits outside the hands.
  """
  @spec unhold([term()]) :: :ok
  def unhold(handles) when is_list(handles) do
    # An improper list fails here, in the caller, and not in the hands.
    false = List.improper?(handles)
    GenServer.call(Process.get(:helyx_hands), {:unhold, handles}, :infinity)
  end

  @doc """
  The context of the calling tool call: its Core, the session id, the tool
  names of the session, the called tool, its call id, the model ref of its
  turn as `provider/model`, the session's `:provider_opts`, its ModelContext
  plugin or nil, and `source`, the pid of the source process of a source
  tool, else nil. The hands set it when the call's Task starts. A hook Task
  has the context of its call; a `before_settle` hook has no call, and its
  `tool` and `call_id` are nil (`before-settle.md`). Raises in any other
  process (`docs/features/agent-tool.md`).
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
  Asks the clients and waits for the first answer of
  `Helyx.Session.answer/3`, a JSON object. The session emits `request`, a
  JSON object of valid UTF-8 of at most #{Helyx.Session.Ask.max_request_bytes()} bytes, in an
  `:ask` event with a new ask id, the call id, and the tool name.
  `{:error, :no_client}` at once when no subscriber can answer
  (`answers: true`), and `{:error, :not_running}` for a call that is not a
  running call of the turn, or a caller that is not its own Task
  (`docs/features/hooks.md`), or a call whose result is in the transcript,
  which also ends an open ask. No timeout: the end of the turn ends it. A
  request with the key `"kind"` is an input UI block, such as a `form`, and
  must also pass `Helyx.UIBlock.envelope?/1`. Raises on another request and
  outside a call (`question-tool.md`, `ui-blocks.md`).
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
  Returns the messages of the session of the calling Task of the hands as
  the session holds them: from the first message that its stored summary
  keeps (`Helyx.Summary.kept/2`), or all of them. The result of an earlier
  call of the same assistant message can be missing. No deadline: the
  session never waits for a Task of the hands, and the call exits when the
  session ends or outside the hands (`docs/features/skills.md`).
  """
  @spec transcript() :: [Helyx.Message.t()]
  def transcript, do: GenServer.call(Process.get(:helyx_session), :transcript, :infinity)

  @doc """
  Takes a place for a background run of the calling tool call, before its
  external work starts: the id of the run and the session's background
  folder, mode `0700`, which the session deletes at its stop. `{:error,
  text}` when the 16 places are taken, the folder cannot be made, or the
  caller is no tool call. A second call gives a new id in the same place.
  A run that gave its start answer keeps its place until a turn takes its
  end; any other call frees it when its Task ends. Exits outside the hands.
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
  Gives the start answer of a background run: `text`, after the
  `after_tool` hooks, which can replace its text and its status (`hooks.md`),
  becomes the result of the call, and the Task leaves the calls of its turn;
  an abort or a failure of the turn still revokes it. It returns once the session took it, so a later ask
  of the run gets `{:error, :not_running}`; the Task runs on, and its
  return or crash ends the run. Raises in a Task that is no tool call of a
  turn and in a call with no place of `background/0`; exits outside the hands.
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
  its `hold/1` handles go to the plugin's `release/3` when it ends, then
  the source gets `{ref, :released, :ok | :unconfirmed}`. Exits outside a source.
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
  Returns `{:ok, kept}`, sorted: the room that earlier announces left of
  the session's 64 groups takes the first by name, and a notice names the
  rest that fit in it and counts all. A put of a group not kept, a second
  call, a bad list, and a call outside a source exit the caller.
  """
  @spec announce([String.t()]) :: {:ok, [String.t()]}
  def announce(groups), do: source_call({:announce, groups})

  @doc """
  Puts a group that the source kept: `:starting`, `{:ok, entries}`, or
  `{:error, text}`, which replaces its entries (`:starting` and an error
  leave none). An entry is `%{name:, description:, parameters:, exposure:
  :direct | :deferred}`; one that breaks a bound is left out with a notice,
  and a group whole when the session would hold more than 1,024 source
  entries (`mcp-client.md`, "Bounds"). Another value, a group not kept, and
  a call outside a source process exit the caller.
  """
  @spec put_tools(String.t(), :starting | {:ok, [map()]} | {:error, String.t()}) :: :ok
  def put_tools(group, value), do: source_call({:put_tools, group, value})

  @doc """
  From a source process: the session emits `text`, valid UTF-8, as a
  `:notice` event with no turn id, cut to 2,000 bytes, for what the source
  learns outside its groups, such as a config that it refused
  (`mcp-client.md`). Another value, and a call outside a source process,
  exit the caller.
  """
  @spec notice(String.t()) :: :ok
  def notice(text), do: source_call({:notice, text})

  @doc """
  From a tool call or a hook: the sources' tools `version`, their deferred
  `entries` (`name`, `description`, `parameters`, `group`), the `activated`
  names, the `groups` (`group`, `state`, `tools` count), and the `pending`
  sources. At once when the version is past `version`, it is nil, or 32
  callers wait; else at the next change, or after `wait_ms`, at most 30,000.
  """
  @spec deferred(non_neg_integer() | nil, non_neg_integer()) :: map()
  def deferred(version, wait_ms)
      when (is_nil(version) or is_integer(version)) and is_integer(wait_ms) and wait_ms >= 0 do
    context()
    request = {:deferred, version, min(wait_ms, 30_000)}
    GenServer.call(Process.get(:helyx_session), request, :infinity)
  end

  @doc """
  From a tool call or a hook: activates the registered deferred tools among
  `names`, best first, and returns the activated list; a change gives a
  `tools_change` entry and event. Past 32 names or 65,536 bytes of specs the
  oldest leave, and in one call the lowest ranked. Raises on anything but a
  list of at most 1,024 strings (`mcp-client.md`).
  """
  @spec activate([String.t()]) :: [String.t()]
  def activate(names) do
    context()

    unless is_list(names) and not List.improper?(names) and length(names) <= 1_024 and
             Enum.all?(names, &is_binary/1),
           do: raise(ArgumentError, "activate/1 takes a list of at most 1,024 names")

    GenServer.call(Process.get(:helyx_session), {:activate, names}, :infinity)
  end

  defp source_call(request) do
    source!()

    case GenServer.call(Process.get(:helyx_session), request, :infinity) do
      :error -> exit({:bad_source_call, elem(request, 0)})
      reply -> reply
    end
  end

  defp source!, do: if(Process.get(:helyx_source), do: :ok, else: exit(:not_a_tool_source))
end
