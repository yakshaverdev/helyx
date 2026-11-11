defmodule Helyx.Session.Turn do
  @moduledoc false
  # The turn in progress. `partial` is the assistant content so far as a
  # reversed block list. `model` and `provider` are fixed when the turn starts.
  # The turn's step is the session's phase, not a field here
  # (`Helyx.Session.Server.Flow`).
  #
  # `prepare` is `{ref, pid, messages}`: the ref and the pid of the running
  # prepare Task and the messages that it got; only a reply with that ref is the
  # Task's context.

  alias Helyx.{Message, ModelRef}

  @enforce_keys [:id, :model, :provider]
  defstruct [
    :id,
    :model,
    :provider,
    :partial,
    :message_id,
    :context,
    :prepare,
    :compact,
    :start,
    :started_ms,
    :recall,
    recall_failed: false,
    bytes: 0,
    blocks: 0,
    tool_queue: %Helyx.Session.ToolQueue{},
    approval_chains: %Helyx.Session.ApprovalChains{},
    owners: %{},
    asks: [],
    askers: %{},
    ui_blocks: [],
    held_results: %{},
    helyx_calls: %{},
    helyx_calls_refused: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          model: ModelRef.t(),
          provider: module(),
          partial: [Message.block()] | nil,
          message_id: String.t() | nil,
          context: Helyx.Context.t() | nil,
          prepare: {reference(), pid(), [Message.t()]} | nil,
          compact: String.t() | :reported | nil,
          start: non_neg_integer() | nil,
          started_ms: integer() | nil,
          recall: Message.t() | nil,
          recall_failed: boolean(),
          bytes: non_neg_integer(),
          blocks: non_neg_integer(),
          tool_queue: Helyx.Session.ToolQueue.t(),
          approval_chains: Helyx.Session.ApprovalChains.t(),
          owners: %{String.t() => :tool | :approval},
          asks: [{String.t(), GenServer.from(), Helyx.Session.Snapshot.ask(), pid()}],
          askers: %{pid() => {reference(), {:tool | :hook, String.t()}}},
          ui_blocks: [Helyx.Session.Server.UIBlocks.entry()],
          held_results: %{String.t() => [Helyx.UIBlock.t()]},
          helyx_calls: %{String.t() => true},
          helyx_calls_refused: boolean()
        }

  # The largest streamed model output that a provider allows is 128K tokens, and
  # text averages about 4 bytes for each token: about 512 KiB. The margin is 16
  # times, and a response of 64 bytes for each token still fits.
  @max_message_bytes 8 * 1_048_576

  # A safety budget, not a provider limit: without it, alternating 1-byte text
  # and thinking deltas make about 8 million blocks within the byte bound.
  @max_message_blocks 1_024

  # The bound also holds the open Helyx tool requests
  # (`Helyx.Session.ToolQueue`).
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  # The session file reader holds every message it reads to this bound (#673).
  @spec max_message_blocks() :: pos_integer()
  def max_message_blocks, do: @max_message_blocks

  # An event that takes the open message over `@max_message_bytes`, or a new
  # block over `@max_message_blocks`, is a contract break:
  # `{:error, {:message_too_large, bytes, max}}` or
  # `{:error, {:too_many_blocks, blocks, max}}`, and nothing is added. A delta
  # that merges into the last block (`Message.add_block/2`) makes no new block.
  @spec add_block(t(), Message.block_event(), non_neg_integer()) ::
          {:ok, t()}
          | {:error, {:message_too_large | :too_many_blocks, pos_integer(), pos_integer()}}
  def add_block(%__MODULE__{} = turn, event, size) do
    bytes = turn.bytes + size

    # The byte check comes first: a merge appends the delta to the last block.
    if bytes > @max_message_bytes do
      {:error, {:message_too_large, bytes, @max_message_bytes}}
    else
      old = turn.partial
      partial = Message.add_block(old, event)
      # The compare is O(1): a new block's tail is the old list itself, and a
      # merge's new head sits on the old tail, whose head has another kind.
      blocks = if match?([_ | ^old], partial), do: turn.blocks + 1, else: turn.blocks

      if blocks > @max_message_blocks,
        do: {:error, {:too_many_blocks, blocks, @max_message_blocks}},
        else: {:ok, %{turn | partial: partial, bytes: bytes, blocks: blocks}}
    end
  end

  # The turn with no open assistant message.
  @spec close_partial(t()) :: t()
  def close_partial(%__MODULE__{} = turn),
    do: %{turn | partial: nil, message_id: nil, bytes: 0, blocks: 0}

  # The assistant message of the turn from the blocks so far, with `fields`.
  @spec assistant_message(t(), keyword()) :: Message.t()
  def assistant_message(%__MODULE__{partial: partial, model: model} = turn, fields) do
    struct!(
      %Message{
        role: :assistant,
        id: turn.message_id,
        content: Enum.reverse(partial),
        model: ModelRef.to_string(model)
      },
      fields
    )
  end

  # The turn at its open, with `transcript_length` messages before it.
  @spec open(t(), non_neg_integer()) :: t()
  def open(%__MODULE__{} = turn, transcript_length),
    do: %{turn | start: transcript_length, started_ms: System.monotonic_time(:millisecond)}

  # The milliseconds since `started_ms`.
  @spec elapsed_ms(integer()) :: non_neg_integer()
  def elapsed_ms(started_ms), do: System.monotonic_time(:millisecond) - started_ms

  @spec snapshot(t()) :: Helyx.Session.Snapshot.turn()
  def snapshot(%__MODULE__{} = turn) do
    partial = if turn.partial, do: assistant_message(turn, [])
    %{id: turn.id, partial: partial, elapsed_ms: elapsed_ms(turn.started_ms)}
  end
end
