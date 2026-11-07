defmodule Helyx.Session.Server.Sources do
  @moduledoc false
  # The tool sources of a session in the session process: their start
  # after the hands, the record of each source process, the calls of
  # `Helyx.Tool.announce/1` and `put_tools/2`, and the end of a source
  # (docs/features/mcp-client.md). Each change of the registry sends the
  # tool map to the hands before any context can hold it: both go from this
  # process, the map first.

  alias Helyx.Session.Hands
  alias Helyx.Session.Server.{Events, State}
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

  # The new registry, its tool map to the hands when it changed, and the
  # notices.
  defp sync(state, registry, notices) do
    if registry.tools != state.registry.tools,
      do: Hands.Sources.tools(state.hands, ToolRegistry.modules(registry))

    state = %{state | registry: registry}
    Enum.reduce(notices, state, &Events.emit(&2, nil, :notice, %{text: &1}))
  end
end
