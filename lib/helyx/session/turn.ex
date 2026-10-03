defmodule Helyx.Session.Turn do
  @moduledoc false
  # The turn in progress. `partial` is the assistant content so far as a
  # reversed block list, or nil before the first stream event, and `bytes`
  # the size of its text, thinking, and tool calls. The open
  # tool calls come from the transcript (`Transcript.open_calls/1`).
  # `model` and `provider` are fixed when the turn starts, so a model switch
  # during the turn takes effect on the next one. `resumed` is the resume id
  # that the connect of the turn passed to the provider, or nil. A turn has
  # a `phase`, `:preparing`, `:submitting`, `:submitted`, or `:context`
  # (submitted, with a context request open), the prepared `context` until
  # it is sent, and the `pending` ref of the answer to `{:turn, ...}`.
  # `prepare` is the pid of the running prepare Task, which the session
  # monitors and kills at the turn end, or nil.
  # `tool_queue` holds the Helyx tool requests of the turn
  # (`Helyx.Session.ToolQueue`).

  alias Helyx.{Message, ModelRef}

  @enforce_keys [:id, :model, :provider]
  defstruct [
    :id,
    :model,
    :provider,
    :partial,
    :resumed,
    :phase,
    :context,
    :pending,
    :prepare,
    bytes: 0,
    tool_queue: %Helyx.Session.ToolQueue{}
  ]

  @type t :: %__MODULE__{}

  # The most bytes of text, thinking, and tool calls in the open assistant
  # message. The largest streamed model output that a provider allows is
  # 128K tokens (the current Claude models and the OpenAI GPT-5 models).
  # Text averages about 4 bytes for each token, so such a response is about
  # 512 KiB: the margin is 16 times, and a response of 64 bytes for each
  # token still fits.
  @max_message_bytes 8 * 1_048_576

  # The bound also holds the open Helyx tool requests (`Helyx.Session.ToolQueue`).
  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  # Adds one stream event of `size` bytes to the partial assistant content.
  # An event that takes the open message over `@max_message_bytes` is a
  # contract break: `{:error, {:message_too_large, bytes, max}}`, and
  # nothing is added.
  @spec add_block(t(), Message.block_event(), non_neg_integer()) ::
          {:ok, t()} | {:error, {:message_too_large, pos_integer(), pos_integer()}}
  def add_block(%__MODULE__{} = turn, event, size) do
    bytes = turn.bytes + size

    if bytes > @max_message_bytes,
      do: {:error, {:message_too_large, bytes, @max_message_bytes}},
      else: {:ok, %{turn | partial: Message.add_block(turn.partial, event), bytes: bytes}}
  end

  # The turn with no open assistant message.
  @spec close_partial(t()) :: t()
  def close_partial(%__MODULE__{} = turn), do: %{turn | partial: nil, bytes: 0}

  # The assistant message of the turn from the blocks so far, with `fields`.
  @spec assistant_message(t(), keyword()) :: Message.t()
  def assistant_message(%__MODULE__{partial: partial, model: model}, fields) do
    struct!(
      %Message{
        role: :assistant,
        content: Enum.reverse(partial),
        model: ModelRef.to_string(model)
      },
      fields
    )
  end

  # The turn of a snapshot (`Helyx.Session.Snapshot`).
  @spec snapshot(t()) :: Helyx.Session.Snapshot.turn()
  def snapshot(%__MODULE__{} = turn) do
    partial = if turn.partial, do: assistant_message(turn, [])
    %{id: turn.id, partial: partial}
  end
end
