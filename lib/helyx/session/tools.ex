defmodule Helyx.Session.Tools do
  @moduledoc false
  # The Helyx tool requests of one turn (`docs/features/one-provider-path.md`,
  # "Helyx tools inside the program"): `running`, the call id that runs on
  # the hands, `killed?`, whether the provider withdrew it, and `waiting`,
  # at most @max_waiting calls after it, in arrival order. Each call gets
  # exactly one result.
  #
  # The functions return the struct with the effects for the session, in
  # order: `{:run, call}` (the hands run it), `{:kill, call_id}` (the hands
  # kill the running call), and `{:result, call_id, result}` (the
  # `{:tool_result, ...}` request to the provider process).

  alias Helyx.Message.ToolCall
  alias Helyx.Session.Stream

  # Bounds the fan-out of a model: one runs and these wait.
  @max_waiting 16
  @too_many "too many Helyx tool calls: one runs and #{@max_waiting} wait"
  @aborted {:error, "aborted"}

  defstruct running: nil, killed?: false, waiting: []

  @type t :: %__MODULE__{running: String.t() | nil, killed?: boolean(), waiting: [ToolCall.t()]}
  @type effect ::
          {:run, ToolCall.t()}
          | {:kill, String.t()}
          | {:result, String.t(), {:ok | :error, String.t()}}
  @type step :: {t(), [effect()]}

  # A request with the checker's `rejection` reason, or nil. A call id that
  # is open (it runs or waits) is outside the contract: `:open`. An answered
  # id is not checked: no real provider reuses an id (#369).
  @spec request(t(), ToolCall.t(), String.t() | nil) :: {:ok, step()} | :open
  def request(%__MODULE__{} = tools, %ToolCall{id: id} = call, rejection) do
    cond do
      tools.running == id or Enum.any?(tools.waiting, &(&1.id == id)) ->
        :open

      # An integer over the digit limit, or arguments that are not a JSON object.
      rejection ->
        {:ok, {tools, [{:result, id, {:error, Stream.not_run(rejection)}}]}}

      tools.running == nil ->
        {:ok, run(tools, call)}

      length(tools.waiting) >= @max_waiting ->
        {:ok, {tools, [{:result, id, {:error, @too_many}}]}}

      true ->
        {:ok, {%{tools | waiting: tools.waiting ++ [call]}, []}}
    end
  end

  # The hands' result of the running call: a killed call gets `aborted`.
  # Then the next waiting call runs.
  @spec result(t(), {:ok | :error, String.t()}) :: step()
  def result(%__MODULE__{running: id} = tools, result) when is_binary(id) do
    answer = {:result, id, if(tools.killed?, do: @aborted, else: result)}
    tools = %{tools | running: nil, killed?: false}

    case tools.waiting do
      [] ->
        {tools, [answer]}

      [call | waiting] ->
        {tools, effects} = run(%{tools | waiting: waiting}, call)
        {tools, [answer | effects]}
    end
  end

  # The provider withdrew a request (#198): the running call is killed and
  # gets `aborted` at the hands' result; a waiting one gets `aborted` now.
  # Any other id has nothing open.
  @spec cancel(t(), String.t()) :: step()
  def cancel(%__MODULE__{running: id} = tools, id), do: {%{tools | killed?: true}, [{:kill, id}]}

  def cancel(%__MODULE__{waiting: waiting} = tools, id) do
    case Enum.split_with(waiting, &(&1.id == id)) do
      {[], _} -> {tools, []}
      {_, waiting} -> {%{tools | waiting: waiting}, [{:result, id, @aborted}]}
    end
  end

  # The turn ended: each open call gets `aborted`. The struct ends with
  # the turn.
  @spec end_turn(t()) :: [effect()]
  def end_turn(%__MODULE__{} = tools) do
    ids = List.wrap(tools.running) ++ Enum.map(tools.waiting, & &1.id)
    Enum.map(ids, &{:result, &1, @aborted})
  end

  defp run(tools, %ToolCall{id: id} = call), do: {%{tools | running: id}, [{:run, call}]}
end
