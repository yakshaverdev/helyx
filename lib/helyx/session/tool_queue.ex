defmodule Helyx.Session.ToolQueue do
  @moduledoc false
  # The Helyx tool requests of one turn (`docs/features/one-provider-path.md`,
  # "Helyx tools inside the program"): `running`, the call id that runs on
  # the hands, with `running_bytes`, the encoded size of its call,
  # `killed?`, whether the provider withdrew it, and `waiting`, at most
  # @max_waiting calls after it with their sizes, in arrival order. Each
  # call gets exactly one result.
  #
  # The functions return the struct with the effects for the session, in
  # order: `{:run, call}` (the hands run it), `{:kill, call_id}` (the hands
  # kill the running call), and `{:result, call_id, result}` (the
  # `{:tool_result, ...}` request to the provider process).

  alias Helyx.Message.ToolCall
  alias Helyx.Session.{Stream, Turn}

  # Bounds the fan-out of a model: one runs and these wait.
  @max_waiting 16
  @too_many "too many Helyx tool calls: one runs and #{@max_waiting} wait"
  @too_large "Helyx tool calls too large: the running and waiting calls are over the byte bound"
  @aborted {:error, "aborted"}

  defstruct running: nil, running_bytes: 0, killed?: false, waiting: []

  @type t :: %__MODULE__{
          running: String.t() | nil,
          running_bytes: non_neg_integer(),
          killed?: boolean(),
          waiting: [{ToolCall.t(), non_neg_integer()}]
        }
  @type effect ::
          {:run, ToolCall.t()}
          | {:kill, String.t()}
          | {:result, String.t(), {:ok | :error, String.t()}}
  @type step :: {t(), [effect()]}

  # A request of `bytes` encoded call bytes (`Helyx.Session.Stream`) with
  # the checker's `rejection` reason, or nil. A call id that is open (it
  # runs or waits) is outside the contract: `:open`. An answered id is not
  # checked: no real provider reuses an id (#369). The running and waiting
  # calls hold at most `Turn.max_message_bytes/0` together, so a single
  # call over it never runs.
  @spec request(t(), ToolCall.t(), non_neg_integer(), String.t() | nil) :: {:ok, step()} | :open
  def request(%__MODULE__{} = tools, %ToolCall{id: id} = call, bytes, rejection) do
    cond do
      tools.running == id or Enum.any?(tools.waiting, &(id(&1) == id)) ->
        :open

      # An integer over the digit limit, or arguments that are not a JSON object.
      rejection ->
        {:ok, {tools, [{:result, id, {:error, Stream.not_run(rejection)}}]}}

      bytes(tools) + bytes > Turn.max_message_bytes() ->
        {:ok, {tools, [{:result, id, {:error, @too_large}}]}}

      tools.running == nil ->
        {:ok, run(tools, {call, bytes})}

      length(tools.waiting) >= @max_waiting ->
        {:ok, {tools, [{:result, id, {:error, @too_many}}]}}

      true ->
        {:ok, {%{tools | waiting: tools.waiting ++ [{call, bytes}]}, []}}
    end
  end

  # The hands' result of the running call: a killed call gets `aborted`.
  # Then the next waiting call runs.
  @spec result(t(), {:ok | :error, String.t()}) :: step()
  def result(%__MODULE__{running: id} = tools, result) when is_binary(id) do
    answer = {:result, id, if(tools.killed?, do: @aborted, else: result)}
    tools = %{tools | running: nil, running_bytes: 0, killed?: false}

    case tools.waiting do
      [] ->
        {tools, [answer]}

      [next | waiting] ->
        {tools, effects} = run(%{tools | waiting: waiting}, next)
        {tools, [answer | effects]}
    end
  end

  # The provider withdrew a request (#198): the running call is killed and
  # gets `aborted` at the hands' result; a waiting one gets `aborted` now.
  # Any other id has nothing open.
  @spec cancel(t(), String.t()) :: step()
  def cancel(%__MODULE__{running: id} = tools, id), do: {%{tools | killed?: true}, [{:kill, id}]}

  def cancel(%__MODULE__{waiting: waiting} = tools, id) do
    case Enum.split_with(waiting, &(id(&1) == id)) do
      {[], _} -> {tools, []}
      {_, waiting} -> {%{tools | waiting: waiting}, [{:result, id, @aborted}]}
    end
  end

  # The turn ended: each open call gets `aborted`. The struct ends with
  # the turn.
  @spec end_turn(t()) :: [effect()]
  def end_turn(%__MODULE__{} = tools) do
    ids = List.wrap(tools.running) ++ Enum.map(tools.waiting, &id/1)
    Enum.map(ids, &{:result, &1, @aborted})
  end

  defp run(tools, {%ToolCall{id: id} = call, bytes}),
    do: {%{tools | running: id, running_bytes: bytes}, [{:run, call}]}

  defp id({%ToolCall{id: id}, _bytes}), do: id

  defp bytes(tools),
    do: Enum.reduce(tools.waiting, tools.running_bytes, fn {_, b}, sum -> sum + b end)
end
