defmodule Helyx.Session.Server.Sources do
  @moduledoc false
  # The tool sources of a session in the session process: their start
  # after the hands, the record of each source process, the calls of
  # `Helyx.Tool.announce/1` and `put_tools/2`, and the end of a source
  # (docs/features/mcp-client.md). Each change of the registry sends the
  # tool map to the hands before any context can hold it: both go from this
  # process, the map first.

  alias Helyx.Session.Hands
  alias Helyx.Session.Server.{Events, Records, State}
  alias Helyx.Session.ToolRegistry

  # The source processes of the session's tool sources, none for a session
  # that names its tools (`Helyx.Session.Input.tools/2`).
  def start(%State{} = state) do
    info = %{core: state.core, session_id: state.id, cwd: state.cwd}
    Enum.each(state.registry.sources, &Hands.Sources.start(state.hands, &1, info))
    state
  end

  # A source process that the hands started: its record, then its go.
  def started(%State{} = state, pid, plugin) do
    send(pid, :helyx_go)
    %{state | sources: Map.put(state.sources, pid, plugin)}
  end

  # The end of a source process, after the release of its handles.
  # The hands sent its start before it, so the record is there.
  def down(%State{} = state, pid) do
    {plugin, sources} = Map.pop!(state.sources, pid)
    {registry, notices} = ToolRegistry.remove(state.registry, plugin)
    sync(%{state | sources: sources}, registry, notices)
  end

  # A call of a source process and its reply; any other caller, and a
  # contract break, get `:error`, which exits the caller (`Helyx.Tool`).
  def call(%State{} = state, pid, request) do
    with {:ok, plugin} <- Map.fetch(state.sources, pid),
         {:ok, registry, notices, reply} <- apply_call(state.registry, plugin, request) do
      {:ok, reply, sync(state, registry, notices)}
    end
  end

  defp apply_call(registry, plugin, {:announce, groups}),
    do: ToolRegistry.announce(registry, plugin, groups)

  defp apply_call(registry, plugin, {:put_tools, group, value}),
    do: ToolRegistry.put(registry, plugin, group, value)

  # The waiting callers of `Helyx.Tool.deferred/2`: each a live Task of
  # the hands that holds a call context, of which at most 8 calls, 8 hooks,
  # and 16 background runs live at once. A waiter whose process ended goes
  # before the count, so only live callers fill it.
  @max_waiters 32

  # `Helyx.Tool.deferred/2`: the view at once when the version of the
  # registry is past `version`, or `version` is nil, or no wait is asked,
  # or 32 live callers wait; else the caller waits for the next change or
  # for its timer of `wait_ms`.
  def deferred(%State{registry: registry} = state, from, version, wait_ms) do
    waiters = live(registry.waiters)
    state = %{state | registry: %{registry | waiters: waiters}}

    if version == nil or registry.version > version or wait_ms == 0 or
         map_size(waiters) >= @max_waiters do
      {:reply, view(state), state}
    else
      ref = make_ref()
      timer = :erlang.start_timer(wait_ms, self(), {:deferred, ref})
      waiters = Map.put(waiters, ref, {from, timer})
      {:noreply, %{state | registry: %{state.registry | waiters: waiters}}}
    end
  end

  defp live(waiters) do
    {live, dead} =
      Map.split_with(waiters, fn {_ref, {{pid, _tag}, _timer}} -> Process.alive?(pid) end)

    Enum.each(dead, fn {_ref, {_from, timer}} -> :erlang.cancel_timer(timer) end)
    live
  end

  # The timer of a waiting caller; a caller that a change answered first
  # is gone.
  def timeout(%State{registry: registry} = state, ref) do
    case Map.pop(registry.waiters, ref) do
      {nil, _waiters} ->
        state

      {{from, _timer}, waiters} ->
        GenServer.reply(from, view(state))
        %{state | registry: %{registry | waiters: waiters}}
    end
  end

  # `Helyx.Tool.activate/1` of a tool call of the turn `turn_id`, or nil:
  # the activated list after it.
  def activate(%State{} = state, turn_id, names) do
    state = sync(state, ToolRegistry.activate(state.registry, names), [], turn_id)
    {state.registry.activated, state}
  end

  defp view(state) do
    pending =
      for {_pid, plugin} <- state.sources,
          not is_map_key(state.registry.announced, plugin),
          do: inspect(plugin)

    ToolRegistry.view(state.registry, Enum.sort(pending))
  end

  # The new registry: its tool map to the hands when it changed, before any
  # context can hold it; a `tools_change` when the activated list changed,
  # with the turn of an activation, or nil for the cap after a put; the
  # answer to every waiting caller when the version moved; and the notices.
  defp sync(state, registry, notices, turn_id \\ nil) do
    old = state.registry

    if registry.tools != old.tools,
      do: Hands.Sources.tools(state.hands, ToolRegistry.modules(registry))

    state = %{state | registry: registry}

    state =
      if registry.activated != old.activated,
        do: Records.tools_change(state, turn_id, registry.activated),
        else: state

    state = if registry.version != old.version, do: wake(state), else: state
    Enum.reduce(notices, state, &Events.emit(&2, nil, :notice, %{text: &1}))
  end

  defp wake(%State{registry: %{waiters: waiters}} = state) when map_size(waiters) == 0,
    do: state

  defp wake(%State{registry: registry} = state) do
    answer = view(state)

    for {_ref, {from, timer}} <- registry.waiters do
      :erlang.cancel_timer(timer)
      GenServer.reply(from, answer)
    end

    %{state | registry: %{registry | waiters: %{}}}
  end
end
