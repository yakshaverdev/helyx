defmodule Helyx.Session.HarnessChains do
  @moduledoc false
  # The set of harness chains of one turn (ADR 0013 §3 and §4,
  # `docs/features/hooks.md`, "Harness approvals"): the approval requests
  # of the provider for calls of its own tools, each decided by the
  # `before_tool` chain of its call. `running` holds the chains that run on
  # the hands, by call id, with the approval id of their request, and
  # `waiting` at most @max_waiting more, in arrival order. A call has at
  # most one pending request (its chain runs or waits). The set takes no
  # place of the tool queue: the program, not the hands, gives the result
  # of the call.
  #
  # The functions return the struct with the effects for the session, in
  # order: `{:run, approval_id, call}` (the hands run its chain) and
  # `{:answer, approval_id, decision}` (the `{:approval, ...}` request to
  # the provider process).

  alias Helyx.Message.ToolCall

  # The bounds of the tool queue (`Helyx.Session.ToolQueue`).
  @max_running 8
  @max_waiting 16
  @too_many "too many approval requests: #{@max_running} run and #{@max_waiting} wait"
  @second "the call has a pending approval request"

  defstruct running: %{}, waiting: []

  @type decision :: :allow | {:deny, String.t()}
  @type t :: %__MODULE__{
          running: %{String.t() => String.t()},
          waiting: [{String.t(), ToolCall.t()}]
        }
  @type effect :: {:run, String.t(), ToolCall.t()} | {:answer, String.t(), decision()}
  @type step :: {t(), [effect()]}

  # Whether the request `approval_id` is pending (its chain runs or
  # waits). A request with a pending id is outside the contract. An ended
  # id is not checked, as the tool queue does not check an answered call
  # id (#369).
  @spec pending?(t(), String.t()) :: boolean()
  def pending?(%__MODULE__{} = chains, approval_id), do: approval_id in pending(chains)

  # The request `approval_id`, of an id that is not pending, for the open
  # harness call `call`. A second request for a call, and a request past
  # the bounds, is denied at once.
  @spec request(t(), String.t(), ToolCall.t()) :: step()
  def request(%__MODULE__{} = chains, approval_id, %ToolCall{id: call_id} = call) do
    cond do
      pending_call?(chains, call_id) ->
        {chains, [{:answer, approval_id, {:deny, @second}}]}

      # A chain waits only while @max_running run: a result starts the
      # first waiting one at once.
      map_size(chains.running) < @max_running ->
        running = Map.put(chains.running, call_id, approval_id)
        {%{chains | running: running}, [{:run, approval_id, call}]}

      length(chains.waiting) < @max_waiting ->
        {%{chains | waiting: chains.waiting ++ [{approval_id, call}]}, []}

      true ->
        {chains, [{:answer, approval_id, {:deny, @too_many}}]}
    end
  end

  # Whether the chain of the call `call_id` runs.
  @spec running?(t(), String.t()) :: boolean()
  def running?(%__MODULE__{running: running}, call_id), do: is_map_key(running, call_id)

  # The decision of the running chain of `call_id`. Then the first waiting
  # chain starts.
  @spec result(t(), String.t(), decision()) :: step()
  def result(%__MODULE__{} = chains, call_id, decision) do
    {approval_id, running} = Map.pop!(chains.running, call_id)
    answer = {:answer, approval_id, decision}

    case chains.waiting do
      [{next_id, call} | waiting] ->
        running = Map.put(running, call.id, next_id)
        {%{chains | running: running, waiting: waiting}, [answer, {:run, next_id, call}]}

      [] ->
        {%{chains | running: running}, [answer]}
    end
  end

  # The approval ids of the pending requests: the session denies each one
  # at the end of the turn. The struct ends with the turn.
  @spec pending(t()) :: [String.t()]
  def pending(%__MODULE__{} = chains),
    do: Map.values(chains.running) ++ Enum.map(chains.waiting, &elem(&1, 0))

  defp pending_call?(chains, call_id),
    do:
      is_map_key(chains.running, call_id) or
        Enum.any?(chains.waiting, fn {_id, call} -> call.id == call_id end)
end
