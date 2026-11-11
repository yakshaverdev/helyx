defmodule Helyx.Tool.MCP do
  @moduledoc """
  A tool source of the MCP servers that the user names in
  `~/.helyx/mcp.json`, or the file of the app env `:mcp_config` of
  `helyx_plugins` (`docs/features/mcp-client.md`).

  Its source process reads the config at each session start and resume,
  starts each server that passes the checks over stdio under the perl
  watchdog, and puts its tools as one deferred group per server, named
  `<server>__<tool>`; `tool_search` finds and activates them. `run/2` sends
  a call to the server of the called tool. perl is required.
  """

  @behaviour Helyx.Tool

  alias Helyx.Tool.MCP.Source

  @impl true
  def source(info), do: Source.run(info)

  @impl true
  def run(args, _cwd), do: Source.call(args)

  @impl true
  def check do
    if System.find_executable("perl"),
      do: :ok,
      else: {:error, "perl not found: MCP servers run under a perl watchdog"}
  end

  # The TERM grace of a server's groups (`docs/features/mcp-client.md`).
  @grace_ms 2_000

  # The groups of a server Task, and `{:mcp_call, handles}`, the copies of
  # its server's handles that a call Task holds. A delivered call stops no
  # group: the server Task still runs its server. An aborted one stops the
  # server's groups, which share their release records with the server
  # Task's handles, so the later release of those sends no signal. A
  # delivery of a server Task's groups TERMs first too, as the end of a
  # provider process does (`Helyx.HarnessIO`).
  @impl true
  def release(handles, mode, deadline) do
    {calls, groups} = Enum.split_with(handles, &match?({:mcp_call, _handles}, &1))
    calls = if mode == :cancel, do: calls, else: []
    inner = groups ++ Enum.flat_map(calls, fn {:mcp_call, handles} -> handles end)
    held = Helyx.Watchdog.Group.release(inner, :cancel, deadline, grace_ms: @grace_ms)
    held = MapSet.new(held, &elem(&1, 2))

    Enum.filter(groups, &(elem(&1, 2) in held)) ++
      for(
        {:mcp_call, handles} = call <- calls,
        Enum.any?(handles, &(elem(&1, 2) in held)),
        do: call
      )
  end
end
