defmodule Helyx.TUI.SessionUsage do
  @moduledoc false
  # The usage of a session as the footer shows it (#558,
  # `docs/features/usage-and-limits.md`, "The footer"). `ViewModel` adds
  # every message of the live path and of the snapshot here once, so both
  # paths give the same values.
  #
  # The four token sums count every usage that is not nil. `cost` is the
  # sum of the known costs, nil when no cost is known; `unknown` is set by a
  # usage with `cost: nil`, and `list` by a known cost that is a list price.
  # `context` is the estimate from the last usage that is not nil, nil
  # before one: its `context_tokens`, its `context_window`, the model of its
  # message, and the bytes of the text, thinking, and tool result text of
  # the messages after it. The sums grow with the transcript; the footer
  # shows them in capped forms.

  alias Helyx.Message

  defstruct input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            cost: nil,
            unknown: false,
            list: false,
            context: nil

  @type context :: %{
          tokens: non_neg_integer() | nil,
          window: pos_integer() | nil,
          model: String.t() | nil,
          bytes: non_neg_integer()
        }

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: number() | nil,
          unknown: boolean(),
          list: boolean(),
          context: context() | nil
        }

  # Not `Helyx.Usage.add/2`: it makes the whole cost nil when one part is
  # not known, and the footer shows the known part as a lower bound.
  # A nil usage adds nothing to the sums. A usage starts a new estimate:
  # its `context_tokens` hold its own message.
  @spec add(t(), Message.t()) :: t()
  def add(totals, %Message{usage: %Helyx.Usage{} = usage, model: model}) do
    context = %{
      tokens: usage.context_tokens,
      window: usage.context_window,
      model: model,
      bytes: 0
    }

    add_cost(
      %{
        totals
        | input: totals.input + usage.input,
          output: totals.output + usage.output,
          cache_read: totals.cache_read + usage.cache_read,
          cache_write: totals.cache_write + usage.cache_write,
          context: context
      },
      usage
    )
  end

  def add(%{context: nil} = totals, _message), do: totals

  def add(%{context: context} = totals, %Message{content: content}) do
    bytes = Enum.reduce(content, context.bytes, &(bytes(&1) + &2))
    %{totals | context: %{context | bytes: bytes}}
  end

  # The context %: the estimate, `context_tokens` plus a quarter of the
  # bytes after it, over the window. Nil unless both counts are known and
  # the message of the estimate is of `model`, the current model: after a
  # switch, the old window is not the window of the new model.
  @spec context_percent(t(), String.t()) :: non_neg_integer() | nil
  def context_percent(%{context: %{model: model} = context}, model)
      when is_integer(context.tokens) and is_integer(context.window),
      do: div((context.tokens + div(context.bytes, 4)) * 100, context.window)

  def context_percent(_totals, _model), do: nil

  defp add_cost(totals, %{cost: nil}), do: %{totals | unknown: true}

  defp add_cost(totals, %{cost: cost, cost_kind: kind}),
    do: %{totals | cost: (totals.cost || 0) + cost, list: totals.list or kind == :list}

  defp bytes(%Message.Text{text: text}), do: byte_size(text)
  defp bytes(%Message.Thinking{thinking: thinking}), do: byte_size(thinking)
  defp bytes(_block), do: 0
end
