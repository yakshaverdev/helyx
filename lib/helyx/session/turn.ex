defmodule Helyx.Session.Turn do
  @moduledoc false
  # The turn in progress. `partial` is the assistant content so far as a
  # reversed block list, or nil before the first stream event. `calls` are
  # the tool calls of the last `message_end` with no result yet.
  # `model` and `provider` are fixed when the turn starts, so a model switch
  # during the turn takes effect on the next one. `resumed` is the resume id
  # that the connect of the turn passed to the provider, or nil. A turn has
  # a `phase`, `:preparing`, `:submitting`, `:submitted`, or `:context`
  # (submitted, with a context request open), the prepared `context` until
  # it is sent, and the `pending` ref of the answer to `{:turn, ...}`.
  # The Helyx tool requests (`Helyx.Session.Server.Tools`): `tool` is the
  # call id that runs on the hands, `killed?` whether the provider withdrew
  # it, `waiting` the calls after it, and `ids` every call id of the turn.
  # `results` holds the `from` refs of the `tool_result` and `context`
  # requests with no answer; at the turn end they go to the wait's `results`.

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
    :tool,
    calls: [],
    killed?: false,
    waiting: [],
    ids: MapSet.new(),
    results: []
  ]

  @type t :: %__MODULE__{}

  # Adds one stream event to the partial assistant content.
  @spec add_block(t(), Message.block_event()) :: t()
  def add_block(%__MODULE__{partial: partial} = turn, event),
    do: %{turn | partial: Message.add_block(partial, event)}

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

  # The turn of a snapshot (`Helyx.Session.Snapshot`): every call with no
  # result had its `tool_execution_start` at its message end.
  @spec snapshot(t()) :: Helyx.Session.Snapshot.turn()
  def snapshot(%__MODULE__{} = turn) do
    partial = if turn.partial, do: assistant_message(turn, [])
    %{id: turn.id, partial: partial, running: Enum.map(turn.calls, & &1.id)}
  end
end
