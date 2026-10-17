defmodule Helyx.Provider.Codex.Tools do
  @moduledoc false
  # The Helyx tools of `Helyx.Provider.Codex`. It gives what to send, and
  # Codex writes it.
  #
  # `specs` are the Helyx tool specs to offer. `requests` maps the call id
  # of each open `item/tool/call` to its request id.
  defstruct specs: [], requests: %{}

  alias Helyx.HarnessIO
  alias Helyx.Message

  def initialize_params([]), do: %{clientInfo: %{name: "helyx", version: "0"}}

  def initialize_params(_specs),
    do: Map.put(initialize_params([]), :capabilities, %{experimentalApi: true})

  # The stored id of the thread (`HarnessIO.session_id/2`) must pass
  # `Message.resume_id?/1`.
  def storable?(thread), do: Message.resume_id?(HarnessIO.session_id(thread, []))

  # The `dynamicTools` of `thread/start`.
  def specs(specs) do
    for tool <- specs,
        do: %{
          type: "function",
          name: tool.name,
          description: tool.description,
          inputSchema: tool.parameters
        }
  end

  # The admission of an `item/tool/call`, with the provider state as a map:
  # the call maps to an open `dynamicToolCall` item of the running turn,
  # which puts it in the transcript, and names a tool that the program was
  # given. Core checks the arguments (`Helyx.Session.Stream.check/1`). The
  # session owns the call ids of the turn (#369). Gives `{:ok,
  # tool_request}` or `{:error, text}` for the error answer, and the tools.
  def call(%{tools: tools} = state, rpc_id, params) do
    if tool_call?(params, state) do
      %{"callId" => call_id, "tool" => tool} = params
      requests = Map.put(tools.requests, call_id, rpc_id)
      {{:ok, {:tool_request, call_id, tool, params["arguments"]}}, %{tools | requests: requests}}
    else
      {{:error, "the call does not map to a tool use"}, tools}
    end
  end

  # Items of the running turn only: `items` and `turn` reset at its end.
  # Only a tool that the program was given maps.
  defp tool_call?(%{"threadId" => thread, "turnId" => turn, "callId" => id} = params, state),
    do:
      thread == state.thread and turn == state.turn and state.items.open[id] == "dynamicToolCall" and
        Enum.any?(state.tools.specs, &(&1.name == params["tool"]))

  defp tool_call?(_params, _state), do: false
end
