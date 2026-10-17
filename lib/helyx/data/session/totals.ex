defmodule Helyx.Session.Totals do
  @moduledoc """
  The usage totals of a session and its context state, as the snapshot
  carries them (`docs/features/session-snapshot.md`, "State fields") and a
  client adds each later message to them (`docs/features/usage-and-limits.md`,
  "The footer").

  The four token sums count every usage that is not nil. `cost` is the sum
  of the known costs, nil when no cost is known; `unknown` is set by a usage
  with `cost: nil`, and `list` by a known cost that is a list price.

  The context state is the estimate from the last usage that is not nil,
  nil before one: its `context_tokens` as `tokens`, its `context_window` as
  `window`, the model of its message, and the bytes of the text and the
  thinking of the messages after it. The sums grow with the transcript; a
  client shows them in capped forms.
  """

  alias Helyx.Message

  defstruct input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            cost: nil,
            unknown: false,
            list: false

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: number() | nil,
          unknown: boolean(),
          list: boolean()
        }

  @type context :: %{
          tokens: non_neg_integer() | nil,
          window: pos_integer() | nil,
          model: String.t() | nil,
          bytes: non_neg_integer()
        }

  @doc "The totals and the context state of `messages`, oldest first."
  @spec of([Message.t()]) :: {t(), context() | nil}
  def of(messages),
    do:
      Enum.reduce(messages, {%__MODULE__{}, nil}, fn m, {t, c} -> {add(t, m), context(c, m)} end)

  @doc """
  Adds the usage of `message` to the totals. A nil usage adds nothing. A
  cost that is not known sets `unknown` and keeps the known sum, unlike
  `Helyx.Usage.add/2`.
  """
  @spec add(t(), Message.t()) :: t()
  def add(totals, %Message{usage: %Helyx.Usage{} = usage}) do
    add_cost(
      %{
        totals
        | input: totals.input + usage.input,
          output: totals.output + usage.output,
          cache_read: totals.cache_read + usage.cache_read,
          cache_write: totals.cache_write + usage.cache_write
      },
      usage
    )
  end

  def add(totals, %Message{}), do: totals

  @doc """
  Adds `message` to the context state. A usage starts a new estimate: its
  `context_tokens` hold its own message. Another message adds its bytes.
  """
  @spec context(context() | nil, Message.t()) :: context() | nil
  def context(_context, %Message{usage: %Helyx.Usage{} = usage, model: model}),
    do: %{tokens: usage.context_tokens, window: usage.context_window, model: model, bytes: 0}

  def context(nil, %Message{}), do: nil

  def context(context, %Message{content: content}),
    do: %{context | bytes: Enum.reduce(content, context.bytes, &(bytes(&1) + &2))}

  defp add_cost(totals, %{cost: nil}), do: %{totals | unknown: true}

  defp add_cost(totals, %{cost: cost, cost_kind: kind}),
    do: %{totals | cost: (totals.cost || 0) + cost, list: totals.list or kind == :list}

  defp bytes(%Message.Text{text: text}), do: byte_size(text)
  defp bytes(%Message.Thinking{thinking: thinking}), do: byte_size(thinking)
  defp bytes(_block), do: 0
end
