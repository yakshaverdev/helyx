defmodule Helyx.Provider.ClaudeCode.Turn do
  @moduledoc false
  # The turn of `Helyx.Provider.ClaudeCode`, and what reads and writes only
  # the turn. The functions give the turn's stream events, which the
  # provider sends with the turn id, and the new turn.
  # The phases and the interrupt are in
  # docs/features/long-lived-harness.md, "Turn phases"; the `compact` field
  # in docs/features/harness-compaction.md. `steers` maps the `uuid` of each
  # written steer line that the program did not start yet to its `steer_id`.
  defstruct [:id, :uuid, :interrupt, phase: :idle, steers: %{}, compact: nil]

  alias Helyx.{Message, ProviderError}
  alias Helyx.Provider.ClaudeCode
  alias Helyx.Provider.ClaudeCode.{Mcp, Meter}

  # The turn of a `{:turn, ...}` or a `{:compact, ...}` request.
  def new(:turn, id, uuid, %Helyx.Context{messages: messages}),
    do: %__MODULE__{id: id, uuid: uuid, phase: {:queued, messages, [], false}}

  def new(:compact, id, uuid, text) do
    line = String.trim_trailing("/compact " <> text)

    %__MODULE__{
      id: id,
      uuid: uuid,
      phase: {:queued, [Message.user(line)], [], false},
      compact: :asked
    }
  end

  # The program started the turn's line. A program turn has no
  # `command_lifecycle`, so a start line of its own uuid keeps its phase;
  # so does one of a turn whose line started before.
  def start(%__MODULE__{phase: :program} = turn), do: turn
  def start(%__MODULE__{phase: :started} = turn), do: turn
  def start(%__MODULE__{phase: {:steer_wait, _ref}} = turn), do: turn
  def start(%__MODULE__{phase: {:queued, _, _, _}} = turn), do: %{turn | phase: :started}

  # The turn with the steer line written. A steer during a held replay goes
  # out after the turn's line, so it extends the last held chunk. Gives
  # whether the line goes out at once.
  def steer(%__MODULE__{phase: {:queued, _messages, [], _replay?}} = turn, _line),
    do: {true, turn}

  def steer(%__MODULE__{phase: {:queued, messages, chunks, replay?}} = turn, line),
    do:
      {false,
       %{turn | phase: {:queued, messages, List.update_at(chunks, -1, &[&1, line]), replay?}}}

  def steer(turn, _line), do: {true, turn}

  # The start of the steer line `uuid`, one of `steers`. A pending
  # interrupt now waits for the next `result`.
  def steer_start(%__MODULE__{phase: :program} = turn, uuid),
    do: steer_start(turn, uuid, :program)

  def steer_start(%__MODULE__{} = turn, uuid), do: steer_start(turn, uuid, :started)

  defp steer_start(turn, uuid, phase) do
    {steer_id, steers} = Map.pop!(turn.steers, uuid)
    interrupt = interrupt_unseen(turn.interrupt, :result)

    {[{:user_message, steer_id}], %{turn | steers: steers, phase: phase, interrupt: interrupt}}
  end

  # The turn with the pending interrupt of `from`. A turn that waits for a
  # steer already gave its `result`.
  def interrupt(%__MODULE__{phase: {:steer_wait, _ref}} = turn, from),
    do: %{turn | interrupt: {:pending, from, MapSet.new([:result])}}

  def interrupt(turn, from), do: %{turn | interrupt: {:pending, from, MapSet.new()}}

  # The turn with `key` (`:response` or `:result`) seen by its interrupt.
  def interrupt_seen(%__MODULE__{interrupt: interrupt} = turn, key),
    do: %{turn | interrupt: seen(interrupt, key)}

  # The interrupt is done when its control response and the turn's `result`
  # came, or, before its write, when the turn's `result` came: the turn
  # ended before Helyx wrote the interrupt.
  def interrupt_done?(%__MODULE__{interrupt: {:pending, _from, seen}}),
    do: MapSet.member?(seen, :result)

  def interrupt_done?(%__MODULE__{interrupt: {:sent, _from, _id, seen}}),
    do: MapSet.size(seen) == 2

  def interrupt_from(%__MODULE__{interrupt: {:pending, from, _seen}}), do: from
  def interrupt_from(%__MODULE__{interrupt: {:sent, from, _id, _seen}}), do: from

  defp seen({:pending, from, seen}, key), do: {:pending, from, MapSet.put(seen, key)}
  defp seen({:sent, from, id, seen}, key), do: {:sent, from, id, MapSet.put(seen, key)}

  defp interrupt_unseen(nil, _key), do: nil

  defp interrupt_unseen({:pending, from, seen}, key),
    do: {:pending, from, MapSet.delete(seen, key)}

  defp interrupt_unseen({:sent, from, id, seen}, key),
    do: {:sent, from, id, MapSet.delete(seen, key)}

  # The program started the turn's line (`command_lifecycle` `started`).
  # The atom phases fail `elem/2`, so only `{:steer_wait, ref}` reaches it.
  defguard started?(turn)
           when turn.phase == :started or turn.phase == :program or
                  elem(turn.phase, 0) == :steer_wait

  # A `compact_boundary` gives the compaction event, in any turn. A failed
  # compaction gives its `compact_error` on a `status` line; one in a model
  # turn is the program's own, and the turn goes on. Every other line of a
  # compaction turn is dropped: the summary, and the text of a failure.
  def compaction(turn, %{"subtype" => "compact_boundary", "compact_metadata" => %{} = meta}) do
    compact = if turn.compact, do: :compacted
    event = {:compaction, tokens(meta["pre_tokens"]), tokens(meta["post_tokens"])}
    {[event], %{turn | compact: compact}}
  end

  def compaction(%{compact: :asked} = turn, %{"subtype" => "status", "compact_error" => error})
      when is_binary(error),
      do: {[], %{turn | compact: ProviderError.cap(error)}}

  def compaction(turn, _line), do: {[], turn}

  # The wire bound of a token count; a count outside it is not known.
  defp tokens(n) when is_integer(n) and n >= 0 and n <= 1_000_000_000, do: n
  defp tokens(_n), do: nil

  def delta(%{"type" => "text_delta", "text" => text}) when is_binary(text) and text != "",
    do: [{:text_delta, text}]

  def delta(%{"type" => "thinking_delta", "thinking" => text})
      when is_binary(text) and text != "",
      do: [{:thinking_delta, text}]

  def delta(_delta), do: []

  # The text of an assistant line already came as deltas; only its tool
  # calls are new.
  def assistant(blocks) do
    # The model sees a Helyx tool as `mcp__helyx__<name>`; the transcript
    # has its Helyx name, as with any provider.
    for %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{} = input} <- blocks,
        do:
          {:tool_call,
           %Message.ToolCall{
             id: id,
             name: Mcp.helyx_name(name),
             arguments: input
           }}
  end

  # The tool results of a user line. The session closes the assistant
  # message at the first result of one of its calls.
  def results(blocks) do
    for %{"type" => "tool_result", "tool_use_id" => id} = block <- blocks do
      status = if block["is_error"] == true, do: :error, else: :ok
      {:tool_result, id, {status, Helyx.Text.truncate(result_text(block["content"]), :tail)}}
    end
  end

  def errors(%{"errors" => errors}) when is_list(errors), do: Enum.filter(errors, &is_binary/1)
  def errors(_result), do: []

  # The terminal of the turn, and the meter after it: a `done` starts a
  # new usage sum, and an error keeps it for the next `done`. A compaction
  # turn keeps it too: no message holds its usage, so the cost of the
  # compaction call goes into the next `done` of the program
  # (docs/features/harness-compaction.md).
  def terminal(%{"is_error" => false, "subtype" => "success"}, %{compact: error}, meter)
      when is_binary(error) do
    empty = {:compaction_failed, ""}
    {{:error, ProviderError.reason(ClaudeCode.id(), :compaction_failed, error, empty)}, meter}
  end

  def terminal(%{"is_error" => false, "subtype" => "success"} = result, turn, meter) do
    {usage, meter} = if turn.compact, do: {nil, meter}, else: Meter.done(meter)
    {{:done, %{stop_reason: stop_reason(result["stop_reason"]), usage: usage}}, meter}
  end

  def terminal(result, _turn, meter) do
    text = Enum.join(errors(result), "; ")
    text = if text == "" and is_binary(result["result"]), do: result["result"], else: text
    subtype = ProviderError.cap(result["subtype"])

    error = ProviderError.reason(ClaudeCode.id(), subtype, text, {:claude_code, subtype, ""})
    {{:error, error}, meter}
  end

  # The wire values: docs/research/stop-reasons.md.
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("refusal"), do: :refused
  defp stop_reason(_stop), do: :end_turn

  # The content of a tool result: a string, or a list of blocks, with a
  # placeholder for a block that is not text. Any other shape is a contract
  # break: the clause match fails, the provider stops, and the turn fails.
  defp result_text(text) when is_binary(text), do: text
  defp result_text(blocks) when is_list(blocks), do: Enum.map_join(blocks, "\n", &block_text/1)

  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp block_text(%{"type" => type}) when is_binary(type) and type != "text", do: "[#{type}]"
end
