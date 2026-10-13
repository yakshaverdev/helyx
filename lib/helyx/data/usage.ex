defmodule Helyx.Usage do
  @moduledoc """
  The token usage of one assistant message, with its cost and the context
  of its last model call. Every provider maps its own wire fields into this
  one struct at its boundary (`docs/features/usage-and-limits.md`).

  The token fields are sums over the model calls of the message; a field
  that the wire does not report is 0. `cost` is in USD and nil when
  unknown; `cost_kind` is nil exactly when `cost` is nil. `context_tokens`
  and `context_window` are of the last model call. A nil usage means that
  there is nothing to count; the unknown usage `%Helyx.Usage{}` means that
  the accounting is missing or partial.

  Two bounds apply. A provider checks each wire value that it maps with
  `wire_tokens?/1`, `wire_cost?/1`, and `wire_window?/1`. Core checks a
  usage with `valid?/1`, the struct bound. `add/2` keeps a sum within the
  struct bound.
  """

  @max_tokens 1_000_000_000_000_000
  @max_cost 1_000_000_000_000
  @max_wire_tokens 1_000_000_000
  @max_wire_cost 1_000_000
  @max_window 1_000_000_000
  @token_fields [:input, :output, :cache_read, :cache_write]

  defstruct input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            cost: nil,
            cost_kind: nil,
            context_tokens: nil,
            context_window: nil

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          cost: number() | nil,
          cost_kind: :billed | :list | nil,
          context_tokens: non_neg_integer() | nil,
          context_window: pos_integer() | nil
        }

  @doc "A token count from the wire: an integer from 0 to 10^9."
  defguard wire_tokens?(n) when is_integer(n) and n >= 0 and n <= @max_wire_tokens

  @doc "A cost from the wire: a number from 0 to 10^6 USD."
  defguard wire_cost?(c) when is_number(c) and c >= 0 and c <= @max_wire_cost

  @doc "A context window from the wire: an integer from 1 to 10^9."
  defguard wire_window?(w) when is_integer(w) and w >= 1 and w <= @max_window

  @doc """
  Whether `usage` is a `Helyx.Usage` with exactly its eight fields, each
  within the struct bound: the token fields and `context_tokens` from 0 to
  10^15, the cost from 0 to 10^12 USD, the window from 1 to 10^9.
  """
  @spec valid?(term()) :: boolean()
  # Nine keys: the eight fields and `__struct__`.
  def valid?(%__MODULE__{cost: cost, cost_kind: kind} = usage) when map_size(usage) == 9 do
    Enum.all?(@token_fields, &tokens?(Map.fetch!(usage, &1))) and
      (usage.context_tokens == nil or tokens?(usage.context_tokens)) and
      (usage.context_window == nil or wire_window?(usage.context_window)) and
      ((cost == nil and kind == nil) or (cost?(cost) and kind in [:list, :billed]))
  end

  def valid?(_other), do: false

  @doc """
  Adds the later usage `b` to the earlier usage `a`; both are valid. The
  token fields add up, and the context fields come from `b`. The cost and
  the kind are nil when either cost is nil; else the kind is `:list` when
  either kind is `:list`. A token sum over 10^15 becomes 10^15, and a cost
  sum over 10^12 is not kept: either makes the cost and the kind nil.
  """
  @spec add(t(), t()) :: t()
  def add(%__MODULE__{} = a, %__MODULE__{} = b) do
    sums = for field <- @token_fields, do: {field, Map.fetch!(a, field) + Map.fetch!(b, field)}
    capped? = Enum.any?(sums, fn {_field, sum} -> sum > @max_tokens end)
    {cost, kind} = if capped?, do: {nil, nil}, else: cost(a, b)
    struct!(b, [{:cost, cost}, {:cost_kind, kind} | Enum.map(sums, &cap/1)])
  end

  @doc "The usage with its cost not known: the cost and the kind are nil."
  @spec unpriced(t()) :: t()
  def unpriced(%__MODULE__{} = usage), do: %{usage | cost: nil, cost_kind: nil}

  defp cap({field, sum}), do: {field, min(sum, @max_tokens)}

  defp cost(%{cost: nil}, _b), do: {nil, nil}
  defp cost(_a, %{cost: nil}), do: {nil, nil}

  defp cost(a, b) do
    sum = a.cost + b.cost
    kind = if :list in [a.cost_kind, b.cost_kind], do: :list, else: :billed
    if sum > @max_cost, do: {nil, nil}, else: {sum, kind}
  end

  defp tokens?(n), do: is_integer(n) and n >= 0 and n <= @max_tokens
  defp cost?(c), do: is_number(c) and c >= 0 and c <= @max_cost
end
