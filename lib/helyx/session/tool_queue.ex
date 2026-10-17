defmodule Helyx.Session.ToolQueue do
  @moduledoc false
  # The Helyx tool requests of one turn (`docs/features/one-provider-path.md`,
  # `docs/features/concurrent-tool-calls.md`): `running`, the call ids that
  # run on the hands, each with the encoded size of its call and its
  # `concurrent?` flag, and `waiting`, at most @max_waiting calls after them
  # with their sizes and flags, in arrival order. Each call gets exactly one
  # result.
  #
  # The functions return the struct with the effects for the session, in
  # order: `{:run, call}` (the hands run it) and `{:result, call_id, result}`
  # (the `{:tool_result, ...}` request to the provider process).

  alias Helyx.Message.ToolCall
  alias Helyx.Session
  alias Helyx.Session.{Stream, Turn}

  # Bound the fan-out of a model: these run at once, and these wait.
  @max_running 8
  @max_waiting 16
  @too_many "too many Helyx tool calls: #{@max_running} run and #{@max_waiting} wait"
  @too_large "Helyx tool calls too large: the running and waiting calls are over the byte bound"

  defstruct running: %{}, waiting: []

  @type t :: %__MODULE__{
          running: %{String.t() => {non_neg_integer(), boolean()}},
          waiting: [{ToolCall.t(), non_neg_integer(), boolean()}]
        }
  @type effect ::
          {:run, ToolCall.t()}
          | {:result, String.t(), {:ok | :error, String.t()}}
  @type step :: {t(), [effect()]}

  # A request of `bytes` encoded call bytes (`Helyx.Session.Stream`) with
  # the checker's `rejection` reason, or nil, of a tool that runs
  # `concurrent?` with others or alone. A call id that is open (it runs or
  # waits) is outside the contract: `:open`. An answered id is not checked:
  # no real provider reuses an id (#369). The running and waiting calls hold
  # at most `Turn.max_message_bytes/0` together, so a single call over it
  # never runs.
  @spec request(t(), ToolCall.t(), non_neg_integer(), String.t() | nil, boolean()) ::
          {:ok, step()} | :open
  def request(%__MODULE__{} = tools, %ToolCall{id: id} = call, bytes, rejection, concurrent?) do
    cond do
      is_map_key(tools.running, id) or Enum.any?(tools.waiting, &(id(&1) == id)) ->
        :open

      # An integer over the digit limit, or arguments that are not a JSON object.
      rejection ->
        {:ok, {tools, [{:result, id, {:error, Stream.not_run(rejection)}}]}}

      bytes(tools) + bytes > Turn.max_message_bytes() ->
        {:ok, {tools, [{:result, id, {:error, @too_large}}]}}

      # `start_waiting/2` runs after each change, so a waiting call cannot
      # start yet: a new call starts at once only when none waits.
      length(tools.waiting) < @max_waiting ->
        {:ok, start_waiting(%{tools | waiting: tools.waiting ++ [{call, bytes, concurrent?}]})}

      true ->
        {:ok, {tools, [{:result, id, {:error, @too_many}}]}}
    end
  end

  # The hands' result of the running call `id`. Then the waiting calls
  # that may start run.
  @spec result(t(), String.t(), {:ok | :error, String.t()}) :: step()
  def result(%__MODULE__{} = tools, id, result) do
    {{_bytes, _concurrent?}, running} = Map.pop!(tools.running, id)
    {tools, effects} = start_waiting(%{tools | running: running})
    {tools, [{:result, id, result} | effects]}
  end

  # The turn ended: each open call gets `aborted`. The struct ends with
  # the turn.
  @spec end_turn(t()) :: [effect()]
  def end_turn(%__MODULE__{} = tools) do
    ids = Map.keys(tools.running) ++ Enum.map(tools.waiting, &id/1)
    Enum.map(ids, &{:result, &1, Session.aborted_result()})
  end

  # Only the first waiting call can start, so the calls start in arrival
  # order. A serial call starts when no call runs, and runs alone. A
  # concurrent call starts beside concurrent calls, under @max_running.
  defp start_waiting(tools, runs \\ []) do
    case tools.waiting do
      [{call, bytes, concurrent?} | waiting] ->
        if may_start?(tools.running, concurrent?) do
          running = Map.put(tools.running, call.id, {bytes, concurrent?})
          start_waiting(%{tools | running: running, waiting: waiting}, [{:run, call} | runs])
        else
          {tools, Enum.reverse(runs)}
        end

      [] ->
        {tools, Enum.reverse(runs)}
    end
  end

  defp may_start?(running, _concurrent?) when running == %{}, do: true
  defp may_start?(_running, false), do: false

  defp may_start?(running, true),
    do: map_size(running) < @max_running and Enum.all?(running, fn {_, {_, c?}} -> c? end)

  defp id({%ToolCall{id: id}, _bytes, _concurrent?}), do: id

  defp bytes(tools),
    do:
      Enum.sum_by(Map.values(tools.running), &elem(&1, 0)) +
        Enum.sum_by(tools.waiting, &elem(&1, 1))
end
