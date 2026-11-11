defmodule Helyx.Session.Server.Wait do
  @moduledoc false
  # The turn cleanup (docs/features/session-lifecycle.md, "Turn end"):
  # the end of a turn, and the wait before the next turn. The wait holds the
  # answer of the hands to `Hands.request_revoke/2` or
  # `Hands.request_cancel/2` (`hands`) and the answer
  # of the provider process in the phase's provider to an interrupt or an
  # idle close (`reply`). A provider process that ends
  # (`Helyx.Session.Server.Flow.Dying`) also holds the wait, until the hands'
  # `:provider_down`. Each part is bounded: the hands by their release
  # deadlines, a reply by its armed kill. `callers` are the abort callers,
  # who get their reply at the end. `turn` is the id of the turn that the
  # wait ended, or nil, and `running` holds, while its `turn_end` waits for
  # the hands, the `data` of that event, the `started_ms` of the turn and the
  # UI blocks that the turn still shows (`ui_blocks`, as in
  # `Helyx.Session.Turn`), which its `turn_end` drops. `settle` is the
  # `before_settle` chain, due or running, or `:revoke`, the revoke that an
  # abort asked for while the chain waits behind a pending hands request,
  # the last part
  # (`Helyx.Session.Server.Settle`). Every message of a client queues until
  # the end.
  # `Helyx.Session.Server.TurnLoop` matches the inputs and ends the wait
  # when no part is left. `finish/2` ends a turn and makes its wait; the
  # other functions change one part of it.

  require Logger

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3, emit: 4]

  alias Helyx.Session.{Hands, ProviderRequest, Turn}
  alias Helyx.Session.Server.{Approvals, Asks, Flow, Records, Settle, State, Steering}
  alias Helyx.Session.Server.{Summary, ToolRuns}

  defstruct [:hands, :reply, :turn, :running, :settle, callers: []]

  @type t :: %__MODULE__{
          hands: :gen_server.request_id() | nil,
          reply: reference() | nil,
          turn: String.t() | nil,
          running:
            %{
              data: map(),
              started_ms: integer(),
              ui_blocks: [Helyx.Session.Server.UIBlocks.entry()]
            }
            | nil,
          settle: {:due, Helyx.Hook.settle(), map()} | :revoke | reference() | nil,
          callers: [GenServer.from()]
        }

  # The end of the turn, at `outcome`: `{:done, stop_reason, usage}`,
  # `:aborted`, or `{:error, reason}`; the reason goes to the log and
  # becomes its text (`Helyx.Reason`). Its prepare Task is killed, its
  # asks end (`Asks.finish/1`), its summary call stops (`Summary.stop/1`),
  # and its records close (`Records.finish/2`). At `done` a steer with no answer yet can still be
  # rejected after the turn (`Queue.answer/4`); an abort or a failure gives
  # the queued texts back (`Queue.abort/1`). The hands release the Tasks
  # of the turn before the next turn: always at an abort or a failure, at
  # `done` when a Helyx tool still runs. An abort or a failure revokes the
  # lease of the turn's background runs: their Tasks end, and no end joins
  # a later turn (ADR 0014, invariant 4). The messages of the turn go to
  # the sync worker (docs/features/memory.md). While one
  # runs, `turn_end` waits for their answer (`cleanup/2`): a start answer
  # that the hands took first then comes before it (#595). Only an
  # abort of a turn that sent `{:turn, ...}` gets an interrupt, after the
  # deny of its pending approval requests and the `aborted` answers of its
  # open tool requests; the hands also release at `done` when a chain of
  # an approval request still runs. `Settle.finish/3` adds the
  # `before_settle` chain when it is due; an abort or a failure drops a
  # waiting continue with the queues (`Queue.abort/1`).
  @spec finish(
          State.t(),
          {:done, Helyx.Message.stop_reason(), map()} | :aborted | {:error, term()}
        ) ::
          State.t()
  def finish(state, outcome), do: finish(state, outcome, state.phase.provider)

  # `provider` is the provider process that the wait holds: `:none` when it
  # ended before the turn did (`TurnLoop.provider_down/3`), so no request
  # goes to it.
  @spec finish(
          State.t(),
          {:done, Helyx.Message.stop_reason(), map()} | :aborted | {:error, term()},
          Flow.provider()
        ) :: State.t()
  def finish(%State{phase: %{turn: turn} = phase} = state, outcome, provider) do
    outcome = with {:error, reason} <- outcome, do: {:error, error_text(reason)}
    kill_prepare(turn)
    state = state |> Asks.finish() |> Summary.stop() |> Records.finish(outcome)
    done? = match?({:done, _stop, _usage}, outcome)
    state = Steering.end_turn(state, turn.id, done?)

    state =
      if match?(%Flow.Up{}, provider),
        do: state |> Approvals.end_turn(turn) |> ToolRuns.end_turn(turn),
        else: state

    Helyx.Session.Sync.push_turn(state)
    running? = turn.tool_queue.running != %{}
    data = end_data(outcome)
    state = if running?, do: state, else: emit(state, :turn_end, data)
    chains? = turn.approval_chains.running != %{}

    hands =
      cond do
        !done? -> Hands.request_revoke(state.hands, turn.id)
        running? or chains? -> Hands.request_cancel(state.hands, turn.id)
        true -> nil
      end

    wait = if outcome == :aborted, do: interrupt(state, phase, provider), else: %__MODULE__{}

    running =
      if running?,
        do: %{data: data, started_ms: turn.started_ms, ui_blocks: state.phase.turn.ui_blocks}

    wait = %{wait | hands: hands, turn: turn.id, running: running}

    Settle.finish(%{state | phase: %Flow.Waiting{wait: wait, provider: provider}}, turn, outcome)
  end

  # The snapshot turn of a wait whose `turn_end` waits for the hands: the
  # turn still runs for a client (#595). Its records are closed, so it has
  # no partial message. No other phase has a turn.
  @spec snapshot_turn(:idle | t()) :: Helyx.Session.Snapshot.turn() | nil
  def snapshot_turn(%__MODULE__{turn: id, running: %{started_ms: started}}),
    do: %{id: id, partial: nil, elapsed_ms: Turn.elapsed_ms(started)}

  def snapshot_turn(_phase), do: nil

  defp end_data({:done, _stop_reason, _usage}), do: %{outcome: :done}
  defp end_data(:aborted), do: %{outcome: :aborted}
  defp end_data({:error, text}), do: %{outcome: :error, error: text}

  # The wait holds the answer to the interrupt, for a turn that sent its
  # request.
  defp interrupt(state, %Flow.Sending{turn: %Turn{id: id}}, %Flow.Up{pid: pid}),
    do: %__MODULE__{reply: ask(state, pid, {:interrupt, id}, :reply)}

  defp interrupt(state, %Flow.Live{turn: %Turn{id: id}}, %Flow.Up{pid: pid}),
    do: %__MODULE__{reply: ask(state, pid, {:interrupt, id}, :reply)}

  defp interrupt(_state, _phase, _provider), do: %__MODULE__{}

  # Kills the prepare Task of the turn, if one runs. Its late
  # `{ref, {:prepared, ...}}` and `:DOWN` match no `Turn.prepare`, also of
  # a new turn with the same id, and are dropped.
  defp kill_prepare(%Turn{prepare: nil}), do: :ok
  defp kill_prepare(%Turn{prepare: {_ref, pid, _messages}}), do: Process.exit(pid, :kill)

  # The answer to the interrupt or the idle close of the wait. The loop
  # ends itself after an answer that stops it (`ProviderRequest.stop_after/2`),
  # and the wait then lasts until its `:provider_down`. Any other answer
  # leaves the provider: if a `:DOWN` came first, it is dying already.
  @spec answered(State.t(), atom(), term()) :: State.t()
  def answered(%State{phase: %Flow.Waiting{wait: wait} = phase} = state, kind, reply) do
    state = %{state | phase: %{phase | wait: %{wait | reply: nil}}}

    if ProviderRequest.stop_after(kind, reply),
      do: %{state | phase: %{state.phase | provider: Flow.dying(state.phase.provider)}},
      else: state
  end

  # The answer of the hands to the cleanup request, and then a `turn_end`
  # that waited for it. Any other message is a bug and crashes the session.
  def cleanup(
        %State{phase: %Flow.Waiting{wait: %__MODULE__{hands: request} = wait} = phase} = state,
        message
      ) do
    {:reply, result} = :gen_server.check_response(message, request)
    state = if wait.running, do: emit(state, wait.turn, :turn_end, wait.running.data), else: state
    state = revoke(result, state)
    %{cleanup_notice(result, state) | phase: %{phase | wait: %{wait | hands: nil, running: nil}}}
  end

  # The runs that the abort or the failure revoked delivered no end, so the
  # session drops their count (ADR 0014, invariant 4).
  defp revoke({:revoked, ids, _error}, state), do: Steering.revoked(state, ids)
  defp revoke(_result, state), do: state

  # The abort still replies `:ok` (ADR 0006 §2); a failed cleanup is a
  # notice with a fixed text; the log has the reason, and the hands log
  # the handles. The turn has ended, so the notice has no turn id.
  defp cleanup_notice(:ok, state), do: state
  defp cleanup_notice({:revoked, _ids, nil}, state), do: state
  defp cleanup_notice({:revoked, _ids, error}, state), do: cleanup_notice(error, state)

  defp cleanup_notice({:error, reason}, state) do
    Logger.warning("abort cleanup failed: " <> reason)
    text = "abort cleanup failed: a process or resource of the turn may still be held"
    emit(state, nil, :notice, %{text: text})
  end

  defp error_text(reason) do
    Helyx.Reason.log("turn failed", reason)
    Helyx.Reason.text(reason)
  end

  # An abort in a wait gives the queued texts back, like the abort that
  # started the wait (`Queue.abort/1`), and its caller gets the reply at
  # the end of the wait. It drops a compaction and a continue that wait,
  # and ends the `before_settle` chain (`Settle.abort/1`). While the chain
  # is due or runs, the abort also revokes the ended turn's Tasks and
  # background runs.
  @spec abort(State.t(), GenServer.from()) :: State.t()
  def abort(%State{phase: %Flow.Waiting{wait: wait} = phase} = state, from) do
    wait = %{wait | callers: [from | wait.callers]}

    %{state | pending_compact: nil, phase: %{phase | wait: wait}}
    |> Steering.abort()
    |> Settle.abort()
  end
end
