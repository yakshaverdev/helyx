defmodule Helyx.Session.Turn do
  @moduledoc false
  # The turn in progress. `partial` is the assistant content so far as a
  # reversed block list, or nil before the first stream event. `calls` are
  # the tool calls still to answer, the head running. `rejected` are the
  # tool calls of the current assistant message that get an error result
  # and never run, each with its reason: the provider rejected the call, or
  # its arguments held an integer over the digit limit (see
  # `Helyx.Message.cap_integers/1`). They are compared by value,
  # because a provider can repeat a call id: a call that is equal to a
  # rejected call after the cap is also rejected. One turn has many provider
  # calls, so each provider call starts with an empty map.
  # `model` and `provider` are fixed when the turn starts, so a model switch
  # during the turn takes effect on the next one, and so does `turn_mode`
  # (`Helyx.Provider.turn/1`). `resumed` is the harness session id that
  # the connect of the turn passed to a connected provider, or nil. A
  # connected turn has a `phase`, `:preparing`, `:submitting`, or
  # `:submitted`, the prepared `context` until it is sent, and the
  # `pending` ref of the answer to `{:turn, ...}`. `steers` lists each steer that the turn sent
  # to the harness and that has no `user_message` or no answer yet, in
  # send order: `{steer_id, text, answer}`, where `answer` is the `from`
  # ref until the answer comes, then `:answered`; a steer taken before its
  # answer keeps a nil `text` until the answer. `tool` is the Helyx tool
  # request of a connected turn that runs on the hands (the harness loop
  # keeps the waiting ones), `start` the `from` ref of its
  # `{:tool_start, ...}` ask with no answer, and `results` the `from` refs
  # of the `tool_result` requests with no answer. At the turn end both go
  # to the wait's `results`.

  alias Helyx.{Message, ModelRef}

  @enforce_keys [:id, :model, :provider, :turn_mode]
  defstruct [
    :id,
    :model,
    :provider,
    :turn_mode,
    :task,
    :partial,
    :resumed,
    :phase,
    :context,
    :pending,
    :start,
    calls: [],
    rejected: %{},
    steers: [],
    tool: nil,
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

  @spec reject(t(), Message.ToolCall.t(), String.t()) :: t()
  def reject(%__MODULE__{rejected: rejected} = turn, call, reason),
    do: %{turn | rejected: Map.put(rejected, call, reason)}

  # The reason of a rejected call, or nil for a call that runs.
  @spec rejection(t(), Message.ToolCall.t()) :: String.t() | nil
  def rejection(%__MODULE__{rejected: rejected}, call), do: Map.get(rejected, call)
end
