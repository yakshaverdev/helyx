defmodule Helyx.Session.Server.Connect do
  @moduledoc false
  # The provider process of the turn (docs/features/session-lifecycle.md,
  # "Provider death"): a process of the turn's model already runs, or the
  # session asks the hands to start one, with the resume of the messages
  # before the turn. Their answer comes to `TurnLoop.handle/2`. A process of
  # another model was closed before (`TurnLoop.close_switched/1`), and a
  # dying process holds a wait, so no turn reuses one.

  alias Helyx.Session.{Hands, ProviderProcess, Transcript, Turn}
  alias Helyx.Session.Server.Flow.{Connecting, Preparing, Up}
  alias Helyx.Session.Server.State

  # The state with the provider process of its turn, started if none runs.
  @spec run(State.t()) :: State.t()
  def run(
        %State{phase: %Preparing{turn: %Turn{model: model}, provider: %kind{model: model}}} =
          state
      )
      when kind in [Connecting, Up],
      do: state

  def run(%State{phase: %Preparing{turn: turn, provider: :none} = phase} = state),
    do: start(state, phase, turn)

  defp start(state, phase, turn) do
    history = Enum.take(state.transcript, turn.start)
    {resumed, usage} = Transcript.resume(history, state.resume_ids, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tool_specs,
      opts: State.init_opts(state, resumed, usage),
      session: self()
    }

    start = Hands.start_provider(state.hands, turn.provider, ProviderProcess.run(args))
    provider = %Connecting{start: start, model: turn.model, turn: turn.id, resumed: resumed}

    %{state | phase: %{phase | provider: provider}}
  end
end
