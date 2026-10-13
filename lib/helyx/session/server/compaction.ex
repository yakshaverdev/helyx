defmodule Helyx.Session.Server.Compaction do
  @moduledoc false
  # The compaction of a session (docs/features/harness-compaction.md): a
  # turn with no user message, whose request to the provider process is
  # `{:compact, turn_id, instructions}`. This module owns its admission,
  # its turn, its request, the answer `:unsupported`, and the check of its
  # end; `Helyx.Session.Server.TurnLoop` runs the turn as any other.

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.Server.{ProviderConn, State, TurnLoop, Wait}
  alias Helyx.Session.Turn

  @unsupported "this provider keeps no history of its own, so there is nothing for it to compact"

  # A client's compaction. Idle, it starts now; in a turn, the turn aborts
  # first, as at an abort, and the compaction waits for the end of the
  # wait, as in a wait. One compaction at a time.
  @spec admit(String.t(), State.t()) :: {:ok | {:error, :turn_running}, State.t()}
  def admit(_text, %State{activity: %Turn{compact: compact}} = state) when compact != nil,
    do: {{:error, :turn_running}, state}

  def admit(_text, %State{pending_compact: compact} = state) when compact != nil,
    do: {{:error, :turn_running}, state}

  def admit(text, %State{activity: :idle} = state),
    do: {:ok, TurnLoop.settle(%{state | pending_compact: text})}

  def admit(text, %State{activity: %Turn{}} = state),
    do: {:ok, %{Wait.finish(state, :aborted) | pending_compact: text}}

  def admit(text, %State{activity: %Wait{}} = state), do: {:ok, %{state | pending_compact: text}}

  # Sends the compact request of a compaction turn when the provider
  # process is ready, as `{:turn, ...}` is sent; any other state stays.
  @spec submit(State.t()) :: State.t()
  def submit(
        %State{
          activity: %Turn{phase: :preparing, compact: text} = turn,
          conn: %ProviderConn{pid: pid, status: :ready}
        } = state
      )
      when is_binary(text) do
    from = ask(state, pid, {:compact, turn.id, text}, :reply)
    %{state | activity: %{turn | phase: :submitting, pending: from}}
  end

  def submit(state), do: state

  # The provider keeps no history: a notice, and the turn ends with no
  # message. The Helyx summary of #490 takes the notice's place.
  @spec unsupported(State.t()) :: State.t()
  def unsupported(state),
    do: state |> emit(:notice, %{text: @unsupported}) |> Wait.finish({:done, :end_turn, %{}})

  # The outcome of the provider's terminal: a compaction turn with no
  # compaction event did not compact, whatever the provider says.
  @spec outcome(State.t(), {:done, Helyx.Message.stop_reason(), map()}) ::
          {:done, Helyx.Message.stop_reason(), map()} | {:error, String.t()}
  def outcome(%State{activity: %Turn{compact: text}}, _done) when is_binary(text),
    do: {:error, "the provider reported no compaction"}

  def outcome(_state, done), do: done
end
