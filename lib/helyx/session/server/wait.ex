defmodule Helyx.Session.Server.Wait do
  @moduledoc false
  # The turn cleanup (docs/features/session-lifecycle.md, "Turn end"): the end
  # of a turn, and the wait before the next turn. Each part is bounded: the
  # hands by their release deadlines, a reply by its armed kill. `callers` get
  # their reply at the end. Every message of a client queues until the end.

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
  # `:aborted`, or `{:error, reason}`. The steps and their order are in
  # docs/features/session-lifecycle.md, "Turn end".
  @spec finish(
          State.t(),
          {:done, Helyx.Message.stop_reason(), map()} | :aborted | {:error, term()}
        ) ::
          State.t()
  def finish(state, outcome), do: finish(state, outcome, state.phase.provider)

  # `provider` is `:none` when it ended before the turn did, so no request
  # goes to it (`TurnLoop.provider_down/3`).
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

  # The turn still runs for a client while its `turn_end` waits for the hands
  # (#595). Its records are closed, so it has no partial message.
  @spec snapshot_turn(:idle | t()) :: Helyx.Session.Snapshot.turn() | nil
  def snapshot_turn(%__MODULE__{turn: id, running: %{started_ms: started}}),
    do: %{id: id, partial: nil, elapsed_ms: Turn.elapsed_ms(started)}

  def snapshot_turn(_phase), do: nil

  defp end_data({:done, _stop_reason, _usage}), do: %{outcome: :done}
  defp end_data(:aborted), do: %{outcome: :aborted}
  defp end_data({:error, text}), do: %{outcome: :error, error: text}

  # The wait holds the answer to the interrupt of a turn that sent its
  # request.
  defp interrupt(state, %Flow.Sending{turn: %Turn{id: id}}, %Flow.Up{pid: pid}),
    do: %__MODULE__{reply: ask(state, pid, {:interrupt, id}, :reply)}

  defp interrupt(state, %Flow.Live{turn: %Turn{id: id}}, %Flow.Up{pid: pid}),
    do: %__MODULE__{reply: ask(state, pid, {:interrupt, id}, :reply)}

  defp interrupt(_state, _phase, _provider), do: %__MODULE__{}

  # Its late `{ref, {:prepared, ...}}` and `:DOWN` match no `Turn.prepare`,
  # also of a new turn with the same id, and are dropped.
  defp kill_prepare(%Turn{prepare: nil}), do: :ok
  defp kill_prepare(%Turn{prepare: {_ref, pid, _messages}}), do: Process.exit(pid, :kill)

  # The loop ends itself after an answer that stops it
  # (`ProviderRequest.stop_after/2`), and the wait then lasts until its
  # `:provider_down`. If a `:DOWN` came first, the process is dying already.
  @spec answered(State.t(), atom(), term()) :: State.t()
  def answered(%State{phase: %Flow.Waiting{wait: wait} = phase} = state, kind, reply) do
    state = %{state | phase: %{phase | wait: %{wait | reply: nil}}}

    if ProviderRequest.stop_after(kind, reply),
      do: %{state | phase: %{state.phase | provider: Flow.dying(state.phase.provider)}},
      else: state
  end

  # Any other message is a bug and crashes the session.
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

  # The abort still replies `:ok` (ADR 0006 §2); a failed cleanup is a notice
  # with a fixed text, and the log has the reason. The turn has ended, so the
  # notice has no turn id.
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

  # It drops a compaction and a continue that wait, and ends the
  # `before_settle` chain (`Settle.abort/1`).
  @spec abort(State.t(), GenServer.from()) :: State.t()
  def abort(%State{phase: %Flow.Waiting{wait: wait} = phase} = state, from) do
    wait = %{wait | callers: [from | wait.callers]}

    %{state | pending_compact: nil, phase: %{phase | wait: wait}}
    |> Steering.abort()
    |> Settle.abort()
  end
end
