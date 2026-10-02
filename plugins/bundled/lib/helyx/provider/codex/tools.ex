defmodule Helyx.Provider.Codex.Tools do
  @moduledoc false
  # The Helyx tools of `Helyx.Provider.Codex`. It gives what to send, and
  # Codex writes it.
  #
  # `specs` are the Helyx tool specs to offer, `[]` when the program did
  # not take `experimentalApi`; `notice` is the text for the next turn,
  # or nil. `requests` maps the call id of each open `item/tool/call` to
  # its request id; `used` holds every call id of the running turn's
  # `item/tool/call` requests, answered or not.
  defstruct specs: [], notice: nil, requests: %{}, used: MapSet.new()

  alias Helyx.HarnessIO
  alias Helyx.Message

  @tools_off "the Helyx tools are off for Codex: the program did not accept the experimental API"
  @unmapped "the call does not map to a tool use"
  # The hex digits of the tool set digest in a stored id.
  @digest_hex 16

  # The tools after the program did not take `experimentalApi`.
  def off, do: %__MODULE__{notice: @tools_off}

  def initialize_params([]), do: %{clientInfo: %{name: "helyx", version: "0"}}

  def initialize_params(_specs),
    do: Map.put(initialize_params([]), :capabilities, %{experimentalApi: true})

  # The stored id names the thread and the digest of its Helyx tools. A
  # thread whose tool set is not the session's is not resumed: its tool
  # set is fixed (research note), so a new thread starts with the replay.
  def resumable(nil, _specs), do: nil

  def resumable(id, specs) do
    case String.split(id, "#", parts: 2) do
      [thread, digest] -> if digest == digest(specs), do: thread
      [thread] -> if specs == [], do: thread
    end
  end

  # The stored id can add `#` and the digest to the thread id, so the
  # thread id must pass `Message.resume_id?/1` with that room kept free.
  def storable?(thread),
    do: Message.resume_id?(thread <> "#" <> String.duplicate("0", @digest_hex))

  def session_id(thread, []), do: thread
  def session_id(thread, specs), do: thread <> "#" <> digest(specs)

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

  defp digest([]), do: nil
  defp digest(specs), do: HarnessIO.hex_digest(JSON.encode!(specs(specs)), @digest_hex)

  # The admission of an `item/tool/call`, with the provider state as a map.
  # Gives `{:ok, tool_request}` or `{:error, text}` for the error answer,
  # and the tools. The call id of the running turn is recorded in `used`
  # before any check that answers it, so an id that got any answer never
  # runs later in the turn.
  def call(%{turn_id: nil, tools: tools}, _rpc_id, _params),
    do: {{:error, "no Helyx turn is running"}, tools}

  def call(%{tools: tools} = state, rpc_id, %{"callId" => call_id} = params)
      when is_binary(call_id) do
    used? = MapSet.member?(tools.used, call_id)
    tools = %{tools | used: MapSet.put(tools.used, call_id)}

    cond do
      used? ->
        {{:error, "the call id was used before in this turn"}, tools}

      tool_call?(params, state) ->
        request = {:tool_request, call_id, params["tool"], params["arguments"]}
        {{:ok, request}, %{tools | requests: Map.put(tools.requests, call_id, rpc_id)}}

      true ->
        {{:error, @unmapped}, tools}
    end
  end

  def call(%{tools: tools}, _rpc_id, _params), do: {{:error, @unmapped}, tools}

  # The call maps to an open `dynamicToolCall` item of the running turn,
  # which puts it in the transcript, and has the shape of the schema.
  defp tool_call?(%{"threadId" => thread, "turnId" => turn, "callId" => id} = params, state),
    do:
      thread == state.thread and turn == state.turn and state.items.open[id] == "dynamicToolCall" and
        is_binary(params["tool"]) and is_map(params["arguments"])

  defp tool_call?(_params, _state), do: false
end
