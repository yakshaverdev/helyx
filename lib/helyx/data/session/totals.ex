defmodule Helyx.Session.Totals do
  @moduledoc """
  The usage totals of a session and its context state, as the snapshot
  carries them (`docs/features/session-snapshot.md`, "State fields") and a
  client adds each later message to them (`docs/features/usage-and-limits.md`,
  "The footer").

  The four token sums count every usage that is not nil. `cost` is the sum
  of the known costs, nil when no cost is known; `unknown` is set by a usage
  with `cost: nil`, and `list` by a known cost that is a list price.

  The context state is the estimate from the last usage whose
  `context_tokens` is an integer, nil before one: those tokens as `tokens`,
  its `context_window` as `window`, the model of its message, and the bytes
  of the text, the thinking, and the tool calls of the messages after it.
  The summary compaction plugin estimates with the same rule
  (`docs/features/summary-compaction.md`). A client sets the tokens of
  the estimate at a compaction with `compacted/2`, and `of/2` applies the
  last compaction after its message. The sums grow with the transcript; a
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

  @typedoc "The last compaction of `of/2`: the id of the message before it, and its `tokens_after`."
  @type compaction :: {String.t(), non_neg_integer() | nil}

  @type context :: %{
          tokens: non_neg_integer() | nil,
          window: pos_integer() | nil,
          model: String.t() | nil,
          bytes: non_neg_integer()
        }

  @doc """
  The totals and the context state of `messages`, oldest first. `compacted`
  is the last compaction of the session: the id of the message before it
  and its `tokens_after`, applied after that message with `compacted/2`.
  """
  @spec of([Message.t()], compaction() | nil) :: {t(), context() | nil}
  def of(messages, compacted \\ nil) do
    Enum.reduce(messages, {%__MODULE__{}, nil}, fn m, {t, c} ->
      {add(t, m), c |> context(m) |> compacted_at(m, compacted)}
    end)
  end

  defp compacted_at(context, %Message{id: id}, {id, tokens_after}),
    do: compacted(context, tokens_after)

  defp compacted_at(context, _message, _compacted), do: context

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
  Adds `message` to the context state. A usage with integer
  `context_tokens` starts a new estimate: they hold its own message.
  Another message, also one whose usage has nil `context_tokens`, adds its
  bytes; a tool call counts its name and its JSON arguments.
  """
  @spec context(context() | nil, Message.t()) :: context() | nil
  def context(_context, %Message{usage: %Helyx.Usage{context_tokens: n} = usage, model: model})
      when is_integer(n),
      do: %{tokens: n, window: usage.context_window, model: model, bytes: 0}

  def context(nil, %Message{}), do: nil

  def context(context, %Message{content: content}),
    do: %{context | bytes: Enum.reduce(content, context.bytes, &(bytes(&1) + &2))}

  @doc """
  The context state after a compaction: the tokens become `tokens_after`
  with no bytes after them, nil when it is unknown, and the window and the
  model stay. With no estimate it stays nil.
  """
  @spec compacted(context() | nil, non_neg_integer() | nil) :: context() | nil
  def compacted(nil, _tokens_after), do: nil
  def compacted(context, tokens_after), do: %{context | tokens: tokens_after, bytes: 0}

  defp add_cost(totals, %{cost: nil}), do: %{totals | unknown: true}

  defp add_cost(totals, %{cost: cost, cost_kind: kind}),
    do: %{totals | cost: (totals.cost || 0) + cost, list: totals.list or kind == :list}

  defp bytes(%Message.Text{text: text}), do: byte_size(text)
  defp bytes(%Message.Thinking{thinking: thinking}), do: byte_size(thinking)

  defp bytes(%Message.ToolCall{name: name, arguments: args}),
    do: byte_size(name) + byte_size(JSON.encode!(args))
end
