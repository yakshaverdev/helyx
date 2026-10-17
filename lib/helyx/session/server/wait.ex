defmodule Helyx.Session.Server.Wait do
  @moduledoc false
  # The turn cleanup (docs/features/session-lifecycle.md, "Turn end"):
  # the end of a turn, and the wait before the next turn. The wait holds
  # the answer of the hands to `Hands.request_cancel/2` (`hands`) and the
  # answer of the provider process in `State.conn` to an interrupt or an
  # idle close (`reply`). A provider process that ends
  # (`ProviderConn.status` `:ending`) also holds the wait, until the hands'
  # `:provider_down`. Each part is bounded: the hands by their release
  # deadlines, a reply by its armed kill. `callers` are the abort callers,
  # who get their reply at the end. `turn` is the id of the turn that the
  # wait ended, or nil, and `turn_end` the data of its `turn_end` while that
  # event waits for the hands, with `started_ms` of that turn. Every
  # message of a client queues until the end.
  # `Helyx.Session.Server.TurnLoop` matches the inputs and ends the wait
  # when no part is left. `finish/2` ends a turn and makes its wait; the
  # other functions change one part of it.

  require Logger

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3, emit: 4]

  alias Helyx.Session.{Hands, ProviderRequest, Turn}
  alias Helyx.Session.Server.{ProviderConn, Records, State, Steering, Summary, ToolRuns}

  defstruct [:hands, :reply, :turn, :turn_end, :started_ms, callers: []]

  @type t :: %__MODULE__{
          hands: :gen_server.request_id() | nil,
          reply: reference() | nil,
          turn: String.t() | nil,
          turn_end: map() | nil,
          started_ms: integer() | nil,
          callers: [GenServer.from()]
        }

  # The end of the turn, at `outcome`: `{:done, stop_reason, usage}`,
  # `:aborted`, or `{:error, reason}`; the reason goes to the log and
  # becomes its text (`Helyx.Reason`). Its prepare Task is killed, its
  # summary call stops (`Summary.stop/1`), and its records close
  # (`Records.finish/2`). At `done` a steer with no answer yet can still be
  # rejected after the turn (`Queue.answer/4`); an abort or a failure gives
  # the queued texts back (`Queue.abort/1`). The hands release the Tasks
  # of the turn before the next turn: always at an abort or a failure, at
  # `done` when a Helyx tool still runs. While one
  # runs, `turn_end` waits for their answer (`cleanup/2`): a start answer
  # that the hands took first then comes before it (#595). Only an
  # abort of a turn that sent `{:turn, ...}` gets an interrupt, after the
  # `aborted` answers of its open tool requests.
  @spec finish(
          State.t(),
          {:done, Helyx.Message.stop_reason(), map()} | :aborted | {:error, term()}
        ) ::
          State.t()
  def finish(%State{activity: turn} = state, outcome) do
    outcome = with {:error, reason} <- outcome, do: {:error, error_text(reason)}
    kill_prepare(turn)
    state = state |> Summary.stop() |> Records.finish(outcome)
    done? = match?({:done, _stop, _usage}, outcome)
    state = Steering.end_turn(state, turn.id, done?)
    state = ToolRuns.end_turn(state, turn)
    running = turn.tool_queue.running
    data = end_data(outcome)
    state = if running, do: state, else: emit(state, :turn_end, data)
    hands = if !done? or running, do: Hands.request_cancel(state.hands, turn.id)
    wait = if outcome == :aborted, do: interrupt(state, turn), else: %__MODULE__{}
    turn_end = if running, do: data
    wait = %{wait | hands: hands, turn: turn.id, turn_end: turn_end, started_ms: turn.started_ms}
    %{state | activity: wait}
  end

  # The snapshot turn of a wait whose `turn_end` waits for the hands: the
  # turn still runs for a client (#595). Its records are closed, so it has
  # no partial message. No other activity has a turn.
  @spec snapshot_turn(:idle | t()) :: Helyx.Session.Snapshot.turn() | nil
  def snapshot_turn(%__MODULE__{turn: id, turn_end: data, started_ms: started}) when data != nil,
    do: %{id: id, partial: nil, elapsed_ms: Turn.elapsed_ms(started)}

  def snapshot_turn(_activity), do: nil

  defp end_data({:done, _stop_reason, _usage}), do: %{outcome: :done}
  defp end_data(:aborted), do: %{outcome: :aborted}
  defp end_data({:error, text}), do: %{outcome: :error, error: text}

  # The wait holds the answer to the interrupt.
  defp interrupt(%State{conn: %ProviderConn{pid: pid}} = state, %Turn{phase: phase, id: id})
       when phase in [:submitting, :submitted],
       do: %__MODULE__{reply: ask(state, pid, {:interrupt, id}, :reply)}

  defp interrupt(_state, _turn), do: %__MODULE__{}

  # Kills the prepare Task of the turn, if one runs. Its late
  # `{ref, {:prepared, ...}}` and `:DOWN` match no turn and are dropped.
  defp kill_prepare(%Turn{prepare: nil}), do: :ok
  defp kill_prepare(%Turn{prepare: pid}), do: Process.exit(pid, :kill)

  # The answer to the interrupt or the idle close of the wait. The loop
  # ends itself after an answer that stops it (`ProviderRequest.stop_after/2`),
  # and the wait then lasts until its `:provider_down`. Any other answer
  # leaves the status: if a `:DOWN` came first, it is `:ending` already.
  @spec answered(State.t(), atom(), term()) :: State.t()
  def answered(%State{activity: wait} = state, kind, reply) do
    state = %{state | activity: %{wait | reply: nil}}

    if ProviderRequest.stop_after(kind, reply),
      do: put_in(state.conn.status, :ending),
      else: state
  end

  # The answer of the hands to the cleanup request, and then a `turn_end`
  # that waited for it. Any other message is a bug and crashes the session.
  def cleanup(%State{activity: %__MODULE__{hands: request} = wait} = state, message) do
    {:reply, result} = :gen_server.check_response(message, request)
    state = if wait.turn_end, do: emit(state, wait.turn, :turn_end, wait.turn_end), else: state
    %{cleanup_notice(result, state) | activity: %{wait | hands: nil, turn_end: nil}}
  end

  # The abort still replies `:ok` (ADR 0006 §2); a failed cleanup is a
  # notice with a fixed text; the log has the reason, and the hands log
  # the handles. The turn has ended, so the notice has no turn id.
  defp cleanup_notice(:ok, state), do: state

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
  # the end of the wait. It drops a compaction that waits.
  @spec abort(State.t(), GenServer.from()) :: State.t()
  def abort(%State{activity: wait} = state, from),
    do:
      Steering.abort(%{
        state
        | pending_compact: nil,
          activity: %{wait | callers: [from | wait.callers]}
      })
end
