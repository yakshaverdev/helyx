defmodule Helyx.Tool.MCP do
  @moduledoc """
  A tool source of the MCP servers that the user names in
  `~/.helyx/mcp.json`, or the file of the app env `:mcp_config` of
  `helyx_plugins` (`docs/features/mcp-client.md`).

  Its source process reads the config at each session start and resume,
  starts each server that passes the checks over stdio under the perl
  watchdog, and puts its tools as one deferred group per server, named
  `<server>__<tool>`; `tool_search` finds and activates them. A server
  that does not list its tools within 30 s, exits, or breaks the protocol
  is failed: its tools leave the session and a search names the reason.
  `run/2` sends a call to the server of the called tool. perl is required.
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

  @impl true
  defdelegate release(handles, mode, deadline), to: Helyx.Watchdog.Group
end
