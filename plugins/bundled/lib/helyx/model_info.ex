defmodule Helyx.ModelInfo do
  @moduledoc false
  # The context window and the prices of a model, by steps 2 to 4 of the
  # source rule: config, the catalog (`Helyx.ModelInfo.Catalog`), nothing.
  # The serving side (step 1) wins in the provider. Each value comes whole
  # from the first source that has it. `docs/features/usage-and-limits.md`,
  # "`Helyx.ModelInfo`" and "Config". The providers of `claude-code`,
  # `codex`, `opencode-go`, and `opencode` share it; it is not a plugin
  # (ADR 0005).
  #
  # Config is a boundary: `lookup/3` checks the entry of the ref in use and
  # names the first bad key. A price is USD per million tokens.

  import Helyx.Usage, only: [wire_cost?: 1, wire_window?: 1]

  @counts [:input, :output, :cache_read, :cache_write]
  @max_tiers 8

  @type prices :: %{
          required(:input) => number(),
          required(:output) => number(),
          optional(:cache_read) => number(),
          optional(:cache_write) => number(),
          optional(:tiers) => [{pos_integer(), prices()}]
        }
  @type t :: %__MODULE__{context_window: pos_integer() | nil, prices: prices() | nil}
  defstruct context_window: nil, prices: nil

  @doc false
  @spec lookup(String.t(), String.t(), term()) ::
          {:ok, t()} | {:error, {:bad_config, [term()]}}
  def lookup(provider_id, model, config \\ Application.get_env(:helyx_plugins, :models, %{})) do
    ref = provider_id <> "/" <> model

    with {:ok, entry} <- entry(config, ref) do
      catalog = Helyx.ModelInfo.Catalog.lookup(provider_id, model)

      {:ok,
       %__MODULE__{
         context_window: entry[:context_window] || catalog.context_window,
         prices: entry[:prices] || catalog.prices
       }}
    end
  end

  @doc false
  # The usage of one model call, priced: the cost from `prices`, and the
  # window from `info` when the serving side gave none.
  @spec price(Helyx.Usage.t(), t()) :: Helyx.Usage.t()
  def price(usage, info) do
    {cost, kind} = cost(usage, info.prices) || {nil, nil}

    %{
      usage
      | cost: cost,
        cost_kind: kind,
        context_window: usage.context_window || info.context_window
    }
  end

  @doc false
  # The list cost of one model call, or nil when a count above 0 has no
  # price. The tier with the largest size under the prompt of the call
  # gives the whole price set.
  @spec cost(Helyx.Usage.t(), prices() | nil) :: {float(), :list} | nil
  def cost(_counts, nil), do: nil

  def cost(counts, prices) do
    prompt = counts.input + counts.cache_read + counts.cache_write
    over = for {size, _set} = tier <- prices[:tiers] || [], prompt > size, do: tier
    {_size, prices} = Enum.max(over, fn -> {0, prices} end)

    sum =
      Enum.reduce_while(@counts, 0.0, fn field, sum ->
        case {Map.fetch!(counts, field), prices[field]} do
          {0, _price} -> {:cont, sum}
          {_n, nil} -> {:halt, nil}
          {n, price} -> {:cont, sum + n * price / 1_000_000}
        end
      end)

    sum && {sum, :list}
  end

  # Config

  defp entry(config, ref) when is_map(config) do
    case Map.fetch(config, ref) do
      :error -> {:ok, []}
      {:ok, entry} -> check(entry, [:models, ref], &entry_key/2)
    end
  end

  defp entry(_config, _ref), do: {:error, {:bad_config, [:models]}}

  defp entry_key(:context_window, window) when wire_window?(window), do: {:ok, window}
  defp entry_key(:prices, prices), do: check_prices(prices)
  defp entry_key(_key, _value), do: :error

  @doc false
  # The check of a config price set, which the catalog shares: the price
  # set as a map, or an error.
  @spec check_prices(term()) :: {:ok, prices()} | {:error, term()}
  def check_prices(prices), do: price_set(prices, true)

  # A price set: `input` and `output`, and the optional cache prices; the
  # top set also has `tiers`. A tier's set is whole.
  defp price_set(prices, tiers?) do
    with {:ok, keys} <- check(prices, [], &price_key(&1, &2, tiers?)),
         :ok <- need(keys, :input),
         :ok <- need(keys, :output) do
      {:ok, Map.new(keys)}
    end
  end

  defp need(keys, key), do: if(Keyword.has_key?(keys, key), do: :ok, else: bad([key]))

  defp price_key(key, price, _tiers?) when key in @counts and wire_cost?(price), do: {:ok, price}
  defp price_key(:tiers, tiers, true), do: tiers(tiers)
  defp price_key(_key, _value, _tiers?), do: :error

  # A tier is `{size, prices}`, with the size from 1 to 10^9 tokens.
  defp tiers(tiers) when is_list(tiers) and length(tiers) <= @max_tiers do
    sets =
      for {size, prices} <- tiers,
          wire_window?(size),
          {:ok, set} <- [price_set(prices, false)],
          do: {size, set}

    if length(sets) == length(tiers), do: {:ok, sets}, else: :error
  end

  defp tiers(_tiers), do: :error

  # A keyword list whose every value passes `fun`, else the path of the
  # first bad key: `[:models, ref, key, ...]`.
  defp check(list, path, fun) do
    if Keyword.keyword?(list),
      do: Enum.reduce_while(list, {:ok, []}, &check_key(&1, &2, path, fun)),
      else: bad(path)
  end

  defp check_key({key, value}, {:ok, acc}, path, fun) do
    case fun.(key, value) do
      {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
      {:error, {:bad_config, rest}} -> {:halt, bad(path ++ [key | rest])}
      :error -> {:halt, bad(path ++ [key])}
    end
  end

  defp bad(path), do: {:error, {:bad_config, path}}
end
