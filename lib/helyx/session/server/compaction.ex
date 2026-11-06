defmodule Helyx.Session.Server.Compaction do
  @moduledoc false
  # The compaction of a session (docs/features/harness-compaction.md): a
  # turn with no user message, whose request to the provider process is
  # `{:compact, turn_id, instructions}`. This module owns its admission,
  # its turn, its request, the answer `:unsupported`, and the check of its
  # end; `Helyx.Session.Server.TurnLoop` runs the turn as any other.

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.Server.Flow.{Idle, Preparing, Sending, Up, Waiting}
  alias Helyx.Session.Server.{State, TurnLoop, Wait}
  alias Helyx.Session.Turn

  @unsupported "this provider keeps no history of its own, and the compaction plugin " <>
                 "made no summary, so there is nothing to compact"

  # A client's compaction. Idle, it starts now; in a turn, the turn aborts
  # first, as at an abort, and the compaction waits for the end of the
  # wait, as in a wait. One compaction at a time.
  @spec admit(String.t(), State.t()) :: {:ok | {:error, :turn_running}, State.t()}
  def admit(_text, %State{phase: %{turn: %Turn{compact: compact}}} = state) when compact != nil,
    do: {{:error, :turn_running}, state}

  def admit(_text, %State{pending_compact: compact} = state) when compact != nil,
    do: {{:error, :turn_running}, state}

  def admit(text, %State{phase: %Idle{}} = state),
    do: {:ok, TurnLoop.settle(%{state | pending_compact: text})}

  def admit(text, %State{phase: %{turn: %Turn{}}} = state),
    do: {:ok, %{Wait.finish(state, :aborted) | pending_compact: text}}

  def admit(text, %State{phase: %Waiting{}} = state), do: {:ok, %{state | pending_compact: text}}

  # Sends the compact request of a compaction turn when the provider
  # process is ready, as `{:turn, ...}` is sent; any other state stays.
  @spec submit(State.t()) :: State.t()
  def submit(
        %State{
          phase: %Preparing{
            turn: %Turn{phase: :preparing, compact: text} = turn,
            provider: %Up{pid: pid} = provider
          }
        } = state
      )
      when is_binary(text) do
    from = ask(state, pid, {:compact, turn.id, text}, :reply)
    turn = %{turn | phase: :submitting, pending: from}
    %{state | phase: %Sending{turn: turn, provider: provider}}
  end

  def submit(state), do: state

  # The provider keeps no history, and the Compaction plugin made no
  # summary (`Helyx.Session.Server.Prepare`): a notice, and the turn ends
  # with no message.
  @spec unsupported(State.t()) :: State.t()
  def unsupported(state),
    do: state |> emit(:notice, %{text: @unsupported}) |> Wait.finish({:done, :end_turn, %{}})

  # The outcome of the provider's terminal: a compaction turn with no
  # compaction event did not compact, whatever the provider says.
  @spec outcome(State.t(), {:done, Helyx.Message.stop_reason(), map()}) ::
          {:done, Helyx.Message.stop_reason(), map()} | {:error, String.t()}
  def outcome(%State{phase: %{turn: %Turn{compact: text}}}, _done) when is_binary(text),
    do: {:error, "the provider reported no compaction"}

  def outcome(_state, done), do: done
end
