defmodule Helyx.Provider.ClaudeCode.Meter do
  @moduledoc false
  # The usage of one `claude` program since the `result` of its last
  # `done` (`docs/features/usage-and-limits.md`, "Per provider").
  #
  # `sum` adds the `usage` of every `result` line, and `known?` is false
  # after a part whose cost is not known. `mark` is the `total_cost_usd`
  # at the last `done`: 0 for a new program, the stored sum for a resumed
  # one (`start/1`), nil when it was not known. `total` and `window` are
  # of the last `result`, nil when it was bad. `context` and `model` are
  # of the last `assistant` line.
  # A `result` with a value outside the wire bound adds nothing and makes
  # the cost unknown.

  import Helyx.Usage, only: [wire_tokens?: 1, wire_cost?: 1, wire_window?: 1]

  @counts ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens)

  defstruct sum: %Helyx.Usage{},
            known?: true,
            mark: 0,
            total: nil,
            window: nil,
            context: nil,
            model: nil

  # The meter of a new program. A resumed program reports the totals of
  # its harness session: the mark is the sum of the costs that the session
  # stored for it, nil when one is not known.
  def start(nil), do: %__MODULE__{}
  def start(%Helyx.Usage{cost: cost}), do: %__MODULE__{mark: cost}

  # The context of the next call: the four counts of the line's usage. A
  # bad usage or model keeps the ones before.
  def assistant(meter, message) do
    context =
      case counts(message["usage"]) do
        {:ok, counts} -> Enum.sum(counts)
        :error -> meter.context
      end

    # A copy: the decoded line can hold the whole line as one binary.
    model = if is_binary(message["model"]), do: :binary.copy(message["model"]), else: meter.model
    %{meter | context: context, model: model}
  end

  # A call cut while it streamed is in no total (research note,
  # 2026-10-13), so its result sets the flag.
  def result(meter, result) do
    with {:ok, [input, output, read, write]} <- counts(result["usage"]),
         total when wire_cost?(total) <- result["total_cost_usd"],
         {:ok, window, list?} <- model_usage(result["modelUsage"], meter.model) do
      usage = %Helyx.Usage{input: input, output: output, cache_read: read, cache_write: write}
      sum = Helyx.Usage.add(meter.sum, usage)
      known? = meter.known? and list? and result["terminal_reason"] != "aborted_streaming"
      %{meter | sum: sum, known?: known?, total: total, window: window}
    else
      _ -> %{meter | known?: false, total: nil, window: nil}
    end
  end

  # The usage of a `done` at the last `result`, and a new sum. The cost is
  # the total of the process now minus the total at the last `done`.
  def done(meter) do
    %{sum: sum, mark: mark, total: total} = meter
    cost = if meter.known? && mark && total && total >= mark, do: total - mark

    usage = %{
      sum
      | cost: cost,
        cost_kind: cost && :list,
        context_tokens: meter.context,
        context_window: meter.window
    }

    {usage, %{meter | sum: %Helyx.Usage{}, known?: true, mark: total}}
  end

  defp counts(%{} = usage) do
    counts = for key <- @counts, do: Map.get(usage, key, 0)
    if Enum.all?(counts, &wire_tokens?/1), do: {:ok, counts}, else: :error
  end

  defp counts(_usage), do: :error

  # The window of the entry of the model: the only key, or the key of the
  # last `assistant` line's model. The cost is a list price only when the
  # `costBasis` of every entry is "list". A replayed line's result has an
  # empty map: no model call, so no entry to price.
  defp model_usage(%{} = entries, model) do
    values = Map.values(entries)
    entry = if map_size(entries) == 1, do: hd(values), else: entries[model]
    list? = Enum.all?(values, &match?(%{"costBasis" => "list"}, &1))

    case entry do
      %{"contextWindow" => window} when wire_window?(window) -> {:ok, window, list?}
      %{"contextWindow" => window} when window != nil -> :error
      _ -> {:ok, nil, list?}
    end
  end

  defp model_usage(nil, _model), do: {:ok, nil, false}
  defp model_usage(_entries, _model), do: :error
end
