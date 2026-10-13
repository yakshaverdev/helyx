defmodule Helyx.Provider.ClaudeCode.Meter do
  @moduledoc false
  # The usage of one `claude` program since the `result` of its last
  # `done` (`docs/features/usage-and-limits.md`, "Per provider").
  #
  # `sum` adds the `usage` of every `result` line, and `known?` is false
  # after a part whose cost is not known. `mark` is the `total_cost_usd`
  # at the last `done`: 0 for a new program, the stored sum for a resumed
  # one (`start/2`), nil when it was not known. `total` and `window` are
  # of the last `result`, nil when it was bad; `config_window` is the
  # window of config (`Helyx.ModelInfo`), for a `result` that gives none.
  # `context` and `model` are of the last `assistant` line. `agents` holds
  # the ids of the open `Agent` calls since the last `result`. A call is
  # open until a tool result that is not an error: an interrupt gives a
  # running call an error result.
  # A `result` with a value outside the wire bound adds nothing and makes
  # the cost unknown.

  import Helyx.Usage, only: [wire_tokens?: 1, wire_cost?: 1, wire_window?: 1]

  @counts ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens)

  defstruct sum: %Helyx.Usage{},
            known?: true,
            mark: 0,
            total: nil,
            window: nil,
            config_window: nil,
            context: nil,
            model: nil,
            agents: []

  # The meter of a new program. A resumed program reports the totals of
  # its harness session: the mark is the sum of the costs that the session
  # stored for it, nil when one is not known.
  def start(nil, window), do: %__MODULE__{config_window: window}
  def start(%Helyx.Usage{cost: cost}, window), do: %__MODULE__{mark: cost, config_window: window}

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

    agents =
      for %{"type" => "tool_use", "name" => "Agent", "id" => id} <- List.wrap(message["content"]),
          is_binary(id),
          do: :binary.copy(id)

    %{meter | context: context, model: model, agents: agents ++ meter.agents}
  end

  # An `assistant` or `user` line of the main loop, also of no Helyx turn:
  # its calls are in the totals.
  def line(meter, %{"type" => "assistant", "message" => %{"content" => blocks} = message})
      when is_list(blocks),
      do: assistant(meter, message)

  def line(meter, %{"type" => "user", "message" => %{"content" => blocks}}) when is_list(blocks),
    do: results(meter, blocks)

  def line(meter, _object), do: meter

  # An `Agent` call with a tool result that is not an error ended.
  defp results(meter, blocks) do
    ended =
      for %{"type" => "tool_result", "tool_use_id" => id} = b <- blocks,
          b["is_error"] != true,
          do: id

    %{meter | agents: meter.agents -- ended}
  end

  # A call cut while it streamed is in no total (research note,
  # 2026-10-13), so its result sets the flag. So does an `aborted_tools`
  # with an `Agent` call open: the interrupt can cut a call of the
  # sub-agent, and no line tells whether it did.
  def result(meter, result) do
    reason = result["terminal_reason"]
    cut? = reason == "aborted_streaming" or (reason == "aborted_tools" and meter.agents != [])
    meter = %{meter | agents: []}

    with {:ok, [input, output, read, write]} <- counts(result["usage"]),
         total when wire_cost?(total) <- result["total_cost_usd"],
         {:ok, window, list?} <- model_usage(result["modelUsage"], meter.model) do
      usage = %Helyx.Usage{input: input, output: output, cache_read: read, cache_write: write}
      sum = Helyx.Usage.add(meter.sum, usage)
      known? = meter.known? and list? and not cut?
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
        context_window: meter.window || meter.config_window
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
