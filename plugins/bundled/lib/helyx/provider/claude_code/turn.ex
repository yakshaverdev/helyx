defmodule Helyx.Provider.ClaudeCode.Turn do
  @moduledoc false
  # The running turn of `Helyx.Provider.ClaudeCode`, and what reads and
  # writes only the turn. The functions give the turn's stream events,
  # which the provider sends with the turn id, and the new turn.
  #
  # `uuid` is the `uuid` of its user line. `messages` is its transcript
  # until the program started the line, and nil after: a lost session
  # sends it again to a fresh one. Only after the start do the turn's lines
  # and its `result` count (`started?/1`). `replay?` is true from the write
  # of a replay before its line until the program started the line.
  # `interrupt` is nil, or the pending `Interrupt`. `steers` holds each
  # written steer line that the program did not start yet, by its `uuid`:
  # its `steer_id`. `wait` is set from a `result` that could not end
  # the turn, because a steer was unresolved, until the start of a steer:
  # the ref of the timer of that wait. `chunks` holds the replay chunks
  # not written yet: each goes out at the `result` of the
  # replayed user line that ends the chunk before it, and the last one ends
  # with the turn's line, then any steers. `program?` marks a program turn
  # (#240): its `id` and `uuid` are one new UUID.
  @enforce_keys [:id, :uuid, :messages]
  defstruct [
    :id,
    :uuid,
    :messages,
    :interrupt,
    :wait,
    steers: %{},
    chunks: [],
    replay?: false,
    program?: false,
    usage: %{}
  ]

  alias Helyx.HarnessIO
  alias Helyx.Message

  # The program started the turn's line (`command_lifecycle` `started`).
  defguard started?(turn) when turn.messages == nil

  def delta(%{"type" => "text_delta", "text" => text}) when is_binary(text) and text != "",
    do: [{:text_delta, text}]

  def delta(%{"type" => "thinking_delta", "thinking" => text})
      when is_binary(text) and text != "",
      do: [{:thinking_delta, text}]

  def delta(_delta), do: []

  # The text of an assistant line already came as deltas; only its tool
  # calls and its usage are new.
  def assistant(turn, %{"content" => blocks} = message) do
    calls =
      for %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{} = input} <- blocks,
          do: {:tool_call, %Message.ToolCall{id: id, name: name, arguments: input}}

    usage = if is_map(message["usage"]), do: message["usage"], else: turn.usage
    {calls, %{turn | usage: usage}}
  end

  # The tool results of a user line. The session closes the assistant
  # message at the first result of one of its calls.
  def results(blocks) do
    for %{"type" => "tool_result", "tool_use_id" => id} = block <- blocks do
      status = if block["is_error"] == true, do: :error, else: :ok
      {:tool_result, id, {status, Helyx.Text.truncate(result_text(block["content"]), :tail)}}
    end
  end

  # The start of the steer line `uuid`, one of `steers`. A pending
  # interrupt now waits for the next `result`.
  def steer_start(turn, uuid) do
    {steer_id, steers} = Map.pop!(turn.steers, uuid)
    if turn.wait, do: :erlang.cancel_timer(turn.wait)
    interrupt = turn.interrupt && %{turn.interrupt | result?: false}
    {[{:user_message, steer_id}], %{turn | steers: steers, wait: nil, interrupt: interrupt}}
  end

  def errors(%{"errors" => errors}) when is_list(errors), do: Enum.filter(errors, &is_binary/1)
  def errors(_result), do: []

  def terminal(%{"is_error" => false, "subtype" => "success"} = result, turn) do
    stop = if result["stop_reason"] == "max_tokens", do: :max_tokens, else: :end_turn
    {:done, %{stop_reason: stop, usage: turn.usage}}
  end

  def terminal(result, _turn) do
    text = Enum.join(errors(result), "; ")
    text = if text == "" and is_binary(result["result"]), do: result["result"], else: text
    {:error, {:claude_code, HarnessIO.cap_error(result["subtype"]), HarnessIO.cap_error(text)}}
  end

  defp result_text(text) when is_binary(text), do: text

  defp result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => type} when is_binary(type) -> "[#{type}]"
      _ -> ""
    end)
  end

  defp result_text(_content), do: ""
end
