defmodule Helyx.Session.Wait do
  @moduledoc false
  # The wait before the next turn can start. The session starts no turn
  # until it ends: the answer of the hands to `Hands.request_cancel/2`
  # (`hands`), then the `aborted` results of the open Helyx tool requests of
  # the turn that ended (`tools`, `{turn_id, call_id}` each, see `next/2`)
  # and the interrupt of the turn (`interrupt`, `{pid, turn_id}`) with its
  # answer (`reply`), the answer to an idle close (`idle`), the answers to
  # the open tool result and context requests of the turn that ended
  # (`results`), and the `:provider_down` of a provider process that ends
  # (`provider`). The session also holds the wait while a steer request is
  # open (see `Helyx.Session.Queue`).
  #
  # The wait ends only when `hands`, `reply`, and `provider` are nil too, not
  # when `results` is empty: an interrupt answer other than
  # `:ok` clears `reply`, and the wait still needs the `:provider_down`.
  # Every part is bounded: the hands by their release deadlines, a provider
  # process by the kill armed with its request (a steer by the steer bound).
  # `callers` are the abort callers, who get their reply at the end.
  #
  # The module is pure: `next/2` names the request that the session sends
  # next, and `sent/3` records its ref.

  alias Helyx.Session.Turn

  defstruct [
    :hands,
    :interrupt,
    :reply,
    :idle,
    :provider,
    tools: [],
    callers: [],
    results: []
  ]

  @type request ::
          {:tool_result, String.t(), String.t(), {:error, String.t()}}
          | {:interrupt, String.t()}
  @type t :: %__MODULE__{
          hands: term(),
          interrupt: {pid(), String.t()} | nil,
          reply: reference() | nil,
          idle: reference() | nil,
          provider: pid() | nil,
          tools: [{String.t(), String.t()}],
          callers: [GenServer.from()],
          results: [reference()]
        }

  # The wait after `turn`, with the current provider process `pid` (or
  # nil). With none (a failure at its `:provider_down`), no request of the
  # turn is open any more.
  @spec after_turn(Turn.t(), pid() | nil) :: t()
  def after_turn(%Turn{} = turn, pid) do
    ids = List.wrap(turn.tool) ++ Enum.map(turn.waiting, & &1.id)
    wait = %__MODULE__{tools: Enum.map(ids, &{turn.id, &1})}

    if pid, do: %{wait | results: turn.results}, else: wait
  end

  # The interrupt of an aborted turn: only a turn that sent `{:turn, ...}`
  # gets one, from the provider process `conn` of the session.
  @spec interrupt(Turn.t(), %{pid: pid()} | nil) :: {pid(), String.t()} | nil
  def interrupt(%Turn{phase: phase, id: id}, %{pid: pid})
      when phase in [:submitting, :submitted, :context],
      do: {pid, id}

  def interrupt(_turn, _conn), do: nil

  # The next step with the current provider process `pid` (or nil):
  # `{:send, wait, pid, request}` for a request to send now (its tag is
  # also its key in the session's `provider_ms`), `{:done,
  # callers}` when the wait ends, or `:open`.
  #
  # The hands killed the Helyx tool of the turn, so each open tool request
  # gets `aborted`: the answers come after the kill and before the
  # interrupt, and wait in `results`. A provider process that ended gets
  # none. An interrupt goes only to the provider process of its turn; one
  # that ended before the hands answered gets none.
  @spec next(t(), pid() | nil) :: {:send, t(), pid(), request()} | {:done, list()} | :open
  def next(%__MODULE__{hands: nil, tools: [{turn_id, call_id} | tools]} = wait, pid)
      when is_pid(pid),
      do:
        {:send, %{wait | tools: tools}, pid,
         {:tool_result, turn_id, call_id, {:error, "aborted"}}}

  def next(%__MODULE__{hands: nil, tools: [_ | _]} = wait, nil),
    do: next(%{wait | tools: []}, nil)

  def next(%__MODULE__{hands: nil, interrupt: {pid, turn_id}} = wait, pid),
    do: {:send, %{wait | interrupt: nil, provider: pid}, pid, {:interrupt, turn_id}}

  def next(%__MODULE__{hands: nil, interrupt: {_, _}} = wait, pid),
    do: next(%{wait | interrupt: nil}, pid)

  def next(
        %__MODULE__{
          hands: nil,
          reply: nil,
          provider: nil,
          results: [],
          callers: callers
        },
        _pid
      ),
      do: {:done, callers}

  def next(%__MODULE__{}, _pid), do: :open

  # Records the ref of a request that `next/2` named.
  @spec sent(t(), request(), reference()) :: t()
  def sent(%__MODULE__{} = wait, {:tool_result, _, _, _}, from),
    do: %{wait | results: [from | wait.results]}

  def sent(%__MODULE__{} = wait, {:interrupt, _}, from), do: %{wait | reply: from}

  # A provider reply of `kind` to the request `from`. Each part acts only
  # when its stored ref matches; any other reply changes nothing.
  #
  # An idle close: `:ok`, the program exited, and the wait goes on until
  # its `:provider_down`; `:busy`, the program stays, and the wait ends. An
  # interrupt: `:ok` keeps the provider process; any other answer ends it,
  # and the wait goes on until its `:provider_down`. A tool result or a
  # context only ends its request.
  @spec answer(t(), atom(), reference(), term()) :: t()
  def answer(%__MODULE__{idle: from} = wait, :idle_close, from, reply) do
    provider = if reply == :busy, do: nil, else: wait.provider
    %{wait | idle: nil, provider: provider}
  end

  def answer(%__MODULE__{reply: from} = wait, :interrupt, from, reply) do
    provider = if reply == :ok, do: nil, else: wait.provider
    %{wait | reply: nil, provider: provider}
  end

  def answer(%__MODULE__{results: results} = wait, kind, from, _reply)
      when kind in [:tool_result, :context],
      do: %{wait | results: List.delete(results, from)}

  def answer(%__MODULE__{} = wait, _kind, _from, _reply), do: wait

  # An abort in the wait: its caller gets the reply at the end.
  @spec abort(t(), GenServer.from()) :: t()
  def abort(%__MODULE__{} = wait, caller), do: %{wait | callers: [caller | wait.callers]}

  # The provider process `pid` ended, after the release of its handles: no
  # tool request is open any more. When the wait was for it, that part and
  # its interrupt answer end too.
  @spec provider_down(t(), pid()) :: t()
  def provider_down(%__MODULE__{} = wait, pid) do
    wait = %{wait | results: []}
    if wait.provider == pid, do: %{wait | provider: nil, reply: nil}, else: wait
  end
end
