defmodule Helyx.Session.Server.Wait do
  @moduledoc false
  # The turn cleanup (docs/features/long-lived-harness.md, "Turn cleanup"):
  # the end of a turn, and the wait before the next turn. The wait holds
  # the answer of the hands to `Hands.request_cancel/2` (`hands`), the
  # answer to an interrupt or an idle close (`reply`), and the release of a
  # provider process that ends (`provider`, until the hands'
  # `:provider_down`). Each part is bounded: the hands by their release
  # deadlines, a reply by its armed kill. `callers` are the abort callers,
  # who get their reply at the end. Every message of a client queues until
  # the end. `Helyx.Session.Server.TurnLoop` matches the inputs and ends
  # the wait when no part is left. `end_turn/3` and `close_turn/4` end a
  # turn and make its wait; the other functions change one part of it.

  require Logger

  import Helyx.Session.Server.State, only: [ask: 4, provider_pid: 1]
  import Helyx.Session.Server.Record, only: [emit: 3, emit: 4]

  alias Helyx.Session.{Hands, ProviderRequest, Turn}
  alias Helyx.Session.Server.{Messages, ProviderConn, State, Steering, ToolRuns}

  defstruct [:hands, :reply, :provider, callers: []]

  # The normal end of the turn, at its `:done` terminal.
  def end_turn(state, stop_reason, usage) do
    {%State{activity: turn} = state, assistant} = Messages.end_turn(state, stop_reason, usage)

    kill_prepare(turn)

    # A steer with no answer yet can still be rejected after the turn
    # (`Queue.answer/3`).
    state =
      state
      |> Steering.end_turn(turn.id, true)
      |> ToolRuns.end_turn(turn)
      |> emit(:turn_end, %{message: assistant})
      |> emit(:agent_end, %{stop_reason: stop_reason})

    # A Helyx tool that still runs: the turn cleanup of the hands runs
    # before the next turn.
    hands = if turn.tool_queue.running, do: Hands.request_cancel(state.hands, turn.id)
    %{state | activity: %__MODULE__{hands: hands}}
  end

  # An abort or a failure ends the turn at once: its prepare Task is
  # killed, and the hands release its Tasks before the next turn; the
  # `callers` get their reply when the wait ends. A partial assistant
  # message with a tool call joins the transcript
  # (`Messages.close_turn/3`), and its calls get `aborted`; one with
  # text only is closed with the stop reason so clients do not keep it
  # open, and is not added to the transcript. Only an abort of a turn that
  # sent `{:turn, ...}` gets an interrupt, after the `aborted` answers of
  # its open tool requests.
  def close_turn(%State{activity: turn} = state, stop, reason, callers) do
    kill_prepare(turn)
    request = Hands.request_cancel(state.hands, turn.id)

    data =
      if stop == :aborted,
        do: %{stop_reason: :aborted},
        else: %{stop_reason: :error, error: reason}

    state =
      state
      |> Steering.end_turn(turn.id, false)
      |> Messages.close_turn(stop, reason)
      |> Steering.drop_queues()
      |> ToolRuns.end_turn(turn)
      |> emit(:agent_end, data)

    wait = if stop == :aborted, do: interrupt(state, turn), else: %__MODULE__{}
    %{state | activity: %{wait | hands: request, callers: callers}}
  end

  # The wait holds the answer to the interrupt, and the provider process
  # until that answer keeps it.
  defp interrupt(%State{conn: %ProviderConn{pid: pid}} = state, %Turn{phase: phase, id: id})
       when phase in [:submitting, :submitted, :context],
       do: %__MODULE__{reply: ask(state, pid, {:interrupt, id}, :reply), provider: pid}

  defp interrupt(_state, _turn), do: %__MODULE__{}

  # Kills the prepare Task of the turn, if one runs. Its late
  # `{:prepared, ...}` and `:DOWN` match no turn and are dropped.
  defp kill_prepare(%Turn{prepare: nil}), do: :ok
  defp kill_prepare(%Turn{prepare: pid}), do: Process.exit(pid, :kill)

  # The answer to the interrupt or the idle close of the wait. The loop
  # ends itself after an answer that stops it (`ProviderRequest.stop_after/2`),
  # and the wait then lasts until its `:provider_down`.
  def answered(%State{activity: wait} = state, kind, reply) do
    provider = if ProviderRequest.stop_after(kind, reply), do: wait.provider
    %{state | activity: %{wait | reply: nil, provider: provider}}
  end

  # A provider process ended in the wait, after its release: no request to
  # it is open any more. When the wait was for it, its reply ends too.
  def provider_down(%State{activity: wait} = state, pid) do
    conn = if provider_pid(state) == pid, do: nil, else: state.conn
    wait = if wait.provider == pid, do: %{wait | provider: nil, reply: nil}, else: wait
    Steering.provider_down(%{state | conn: conn, activity: wait})
  end

  # The answer of the hands to the cleanup request. Any other message is a
  # bug and crashes the session.
  def cleanup(%State{activity: %__MODULE__{hands: request} = wait} = state, message) do
    {:reply, result} = :gen_server.check_response(message, request)
    %{cleanup_notice(result, state) | activity: %{wait | hands: nil}}
  end

  # The abort still replies `:ok` (ADR 0006 §5); a failed cleanup is a
  # notice with a fixed text; the log has the reason, whose handle list
  # has no bound. The turn has ended, so the notice has no turn id.
  defp cleanup_notice(:ok, state), do: state

  defp cleanup_notice({:error, reason}, state) do
    Logger.warning("abort cleanup failed: " <> reason)
    text = "abort cleanup failed: a process or resource of the turn may still be held"
    emit(state, nil, :notice, %{text: text})
  end

  # An abort in a wait drops the queues, like the abort that started the
  # wait, and its caller gets the reply at the end of the wait. A steer
  # that still waits for its answer gets its notice now: a late
  # `:rejected` must not queue it again after the abort.
  def abort(%State{activity: wait} = state, from) do
    state = Steering.drop_queues(%{state | activity: %{wait | callers: [from | wait.callers]}})
    Steering.abort(state)
  end
end
