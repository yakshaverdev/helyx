defmodule Helyx.Session.Wait do
  @moduledoc false
  # The wait before the next turn can start. The session starts no turn
  # until it ends: the answer of the hands to `Hands.request_cancel/2`
  # (`hands`), then the Helyx tool of the turn that ended (`tool`,
  # `{turn_id, call_id}`, see `next/2`) and the interrupt of a connected
  # turn (`interrupt`, `{pid, turn_id}`) with its answer (`reply`), the
  # answer to an idle close (`idle`), the answers to the open steer requests
  # of the turn that ended (`steers`, a `Helyx.Session.Steers` ledger) and
  # to its open tool start, tool result, and context requests (`results`), and the
  # `:provider_down` of a provider process that ends (`provider`).
  #
  # The wait ends only when `hands`, `reply`, and `provider` are nil too, not
  # when `steers` and `results` are empty: an interrupt answer other than
  # `:ok` clears `reply`, and the wait still needs the `:provider_down`.
  # Every part is bounded: the hands by their release deadlines, a provider
  # process by the kill armed with its request (a steer by the steer bound).
  # `callers` are the abort callers, who get their reply at the end.
  #
  # The module is pure: `next/2` names the request that the session sends
  # next, and `sent/3` records its ref.

  alias Helyx.Session.{Steers, Turn}

  defstruct [
    :hands,
    :interrupt,
    :reply,
    :idle,
    :provider,
    :tool,
    callers: [],
    steers: %Steers{},
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
          tool: {String.t(), String.t()} | nil,
          callers: [GenServer.from()],
          steers: Steers.t(),
          results: [reference()]
        }

  # The wait after `turn`, with the current provider process `pid` (or
  # nil). With none (a failure at its `:provider_down`), no request of the
  # turn is open any more. Returns the steer effects of the turn end (see
  # `Steers.end_turn/3`).
  @spec after_turn(Turn.t(), pid() | nil, boolean()) :: {t(), [Steers.effect()]}
  def after_turn(%Turn{} = turn, pid, normal?) do
    {steers, effects} = Steers.end_turn(turn.steers, turn.id, normal?)
    wait = %__MODULE__{tool: tool(turn)}

    if pid,
      do: {%{wait | steers: steers, results: List.wrap(turn.start) ++ turn.results}, effects},
      else: {wait, effects}
  end

  defp tool(%Turn{tool: %{id: id}, id: turn_id}), do: {turn_id, id}
  defp tool(_turn), do: nil

  # The interrupt of an aborted turn: only a connected turn that sent
  # `{:turn, ...}` gets one, from the provider process `conn` of the session.
  @spec interrupt(Turn.t(), %{pid: pid()} | nil) :: {pid(), String.t()} | nil
  def interrupt(%Turn{turn_mode: :connected, phase: phase, id: id}, %{pid: pid})
      when phase in [:submitting, :submitted],
      do: {pid, id}

  def interrupt(_turn, _conn), do: nil

  # The next step with the current provider process `pid` (or nil):
  # `{:send, wait, pid, request}` for a request to send now (its tag is
  # also its key in the session's `provider_ms`), `{:done,
  # callers}` when the wait ends, or `:open`.
  #
  # The hands killed the Helyx tool of the turn, so its result is `aborted`:
  # the answer comes after the kill and before the interrupt. The loop
  # writes it only for a call that it confirmed at the ask, also after the
  # turn; it answered any other call itself. Its request waits in
  # `results`. An interrupt goes only to the provider process of its turn;
  # one that ended before the hands answered gets none.
  @spec next(t(), pid() | nil) :: {:send, t(), pid(), request()} | {:done, list()} | :open
  def next(%__MODULE__{hands: nil, tool: {turn_id, call_id}} = wait, pid) when is_pid(pid),
    do: {:send, %{wait | tool: nil}, pid, {:tool_result, turn_id, call_id, {:error, "aborted"}}}

  def next(%__MODULE__{hands: nil, tool: {_, _}} = wait, nil), do: next(%{wait | tool: nil}, nil)

  def next(%__MODULE__{hands: nil, interrupt: {pid, turn_id}} = wait, pid),
    do: {:send, %{wait | interrupt: nil, provider: pid}, pid, {:interrupt, turn_id}}

  def next(%__MODULE__{hands: nil, interrupt: {_, _}} = wait, pid),
    do: next(%{wait | interrupt: nil}, pid)

  def next(
        %__MODULE__{
          hands: nil,
          reply: nil,
          provider: nil,
          steers: %Steers{open: []},
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
  # and the wait goes on until its `:provider_down`. A steer: see
  # `Steers.answer/3`. A tool start, tool result, or context only ends its
  # request.
  @spec answer(t(), atom(), reference(), term()) :: {t(), [Steers.effect()]}
  def answer(%__MODULE__{idle: from} = wait, :idle_close, from, reply) do
    provider = if reply == :busy, do: nil, else: wait.provider
    {%{wait | idle: nil, provider: provider}, []}
  end

  def answer(%__MODULE__{reply: from} = wait, :interrupt, from, reply) do
    provider = if reply == :ok, do: nil, else: wait.provider
    {%{wait | reply: nil, provider: provider}, []}
  end

  def answer(%__MODULE__{steers: steers} = wait, :steer, from, reply) do
    {steers, effects} = Steers.answer(steers, from, reply)
    {%{wait | steers: steers}, effects}
  end

  def answer(%__MODULE__{results: results} = wait, kind, from, _reply)
      when kind in [:tool_start, :tool_result, :context],
      do: {%{wait | results: List.delete(results, from)}, []}

  def answer(%__MODULE__{} = wait, _kind, _from, _reply), do: {wait, []}

  # An abort in the wait: its caller gets the reply at the end, and the
  # steers that a late `:rejected` could queue get their notice now.
  @spec abort(t(), GenServer.from()) :: {t(), [Steers.effect()]}
  def abort(%__MODULE__{} = wait, caller) do
    {steers, effects} = Steers.abort(wait.steers)
    {%{wait | steers: steers, callers: [caller | wait.callers]}, effects}
  end

  # The provider process `pid` ended, after the release of its handles: no
  # steer or tool request is open any more. When the wait was for it, that
  # part and its interrupt answer end too.
  @spec provider_down(t(), pid()) :: {t(), [Steers.effect()]}
  def provider_down(%__MODULE__{} = wait, pid) do
    {steers, effects} = Steers.provider_down(wait.steers)
    wait = %{wait | steers: steers, results: []}

    if wait.provider == pid,
      do: {%{wait | provider: nil, reply: nil}, effects},
      else: {wait, effects}
  end
end
