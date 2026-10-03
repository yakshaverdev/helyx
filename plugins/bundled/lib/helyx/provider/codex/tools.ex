defmodule Helyx.Provider.Codex.Tools do
  @moduledoc false
  # The Helyx tools of `Helyx.Provider.Codex`. It gives what to send, and
  # Codex writes it.
  #
  # `specs` are the Helyx tool specs to offer. `requests` maps the call id
  # of each open `item/tool/call` to its request id; `used` holds every
  # call id of the running turn's `item/tool/call` requests, answered or
  # not.
  defstruct specs: [], requests: %{}, used: MapSet.new()

  alias Helyx.HarnessIO
  alias Helyx.Message

  # The hex digits of the tool set digest in a stored id.
  @digest_hex 16

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
  # and the tools. The admission (`Helyx.HarnessIO.admit/4`) records the
  # call id of the running turn in `used` first.
  def call(%{tools: tools} = state, rpc_id, params) do
    call_id = call_id(params)
    running? = state.turn_id != nil

    {answer, used} =
      HarnessIO.admit(running?, tools.used, call_id, fn -> tool_call?(params, state) end)

    tools = %{tools | used: used}

    case answer do
      :ok ->
        request = {:tool_request, call_id, params["tool"], params["arguments"]}
        {{:ok, request}, %{tools | requests: Map.put(tools.requests, call_id, rpc_id)}}

      {:error, text} ->
        {{:error, text}, tools}
    end
  end

  defp call_id(%{"callId" => call_id}) when is_binary(call_id), do: call_id
  defp call_id(_params), do: nil

  # The call maps to an open `dynamicToolCall` item of the running turn,
  # which puts it in the transcript, and has the shape of the schema.
  defp tool_call?(%{"threadId" => thread, "turnId" => turn, "callId" => id} = params, state),
    do:
      thread == state.thread and turn == state.turn and state.items.open[id] == "dynamicToolCall" and
        is_binary(params["tool"]) and is_map(params["arguments"])

  defp tool_call?(_params, _state), do: false
end
