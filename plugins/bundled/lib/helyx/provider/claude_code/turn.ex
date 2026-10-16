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
  # (#240): its `id` and `uuid` are one new UUID. `compact` is nil for a
  # model turn; in a compaction turn it is `:asked`, then `:compacted` at
  # its `compact_boundary`, or the `compact_error` of a failed compaction.
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
    compact: nil
  ]

  defmodule Interrupt do
    @moduledoc false
    # A pending interrupt of the turn: its `from`, its `request_id` once
    # written, and whether its control response and the turn's `result`
    # came.
    @enforce_keys [:from]
    defstruct [:from, :request_id, response?: false, result?: false]
  end

  alias Helyx.HarnessIO
  alias Helyx.Message
  alias Helyx.Provider.ClaudeCode.Meter

  # The program started the turn's line (`command_lifecycle` `started`).
  defguard started?(turn) when turn.messages == nil

  # The turn of a `{:turn, ...}` or a `{:compact, ...}` request.
  def new(:turn, id, uuid, %Helyx.Context{messages: messages}),
    do: %__MODULE__{id: id, uuid: uuid, messages: messages}

  def new(:compact, id, uuid, text) do
    line = String.trim_trailing("/compact " <> text)
    %__MODULE__{id: id, uuid: uuid, messages: [Message.user(line)], compact: :asked}
  end

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
      do: {[], %{turn | compact: HarnessIO.cap_error(error)}}

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
    for %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{} = input} <- blocks,
        do: {:tool_call, %Message.ToolCall{id: id, name: name, arguments: input}}
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

  # The terminal of the turn, and the meter after it: a `done` starts a
  # new usage sum, and an error keeps it for the next `done`. A compaction
  # turn keeps it too: no message holds its usage, so the cost of the
  # compaction call goes into the next `done` of the program
  # (docs/features/harness-compaction.md).
  def terminal(%{"is_error" => false, "subtype" => "success"}, %{compact: error}, meter)
      when is_binary(error),
      do: {{:error, {:compaction_failed, error}}, meter}

  def terminal(%{"is_error" => false, "subtype" => "success"} = result, turn, meter) do
    {usage, meter} = if turn.compact, do: {nil, meter}, else: Meter.done(meter)
    {{:done, %{stop_reason: stop_reason(result["stop_reason"]), usage: usage}}, meter}
  end

  def terminal(result, _turn, meter) do
    text = Enum.join(errors(result), "; ")
    text = if text == "" and is_binary(result["result"]), do: result["result"], else: text
    subtype = HarnessIO.cap_error(result["subtype"])
    {{:error, {:claude_code, subtype, HarnessIO.cap_error(text)}}, meter}
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
