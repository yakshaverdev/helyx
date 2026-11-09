defmodule Helyx.Session.Server.Connect do
  @moduledoc false
  # The provider process of the turn: a process of the turn's model already
  # runs, or the session asks the hands to start one, with the resume of the
  # messages before the turn. Their answer comes to `TurnLoop.handle/2`. A
  # process of another model was closed before
  # (`TurnLoop.close_switched/1`), and a dying process holds a wait. Between
  # turns a ready process arms the idle timer (`arm_idle/1`).

  alias Helyx.Session.{Hands, ProviderProcess, Transcript, Turn}
  alias Helyx.Session.Server.Flow.{Connecting, Idle, Preparing, Up}
  alias Helyx.Session.Server.State

  # The state with the provider process of its turn. `:reuse` keeps a
  # process of the turn's model that is not dying; `:restart` starts one,
  # because the turn's process ended (`TurnLoop.provider_down/3`).
  @spec run(State.t(), :reuse | :restart) :: State.t()
  def run(state, mode \\ :reuse)

  def run(
        %State{phase: %Preparing{turn: %Turn{model: model}, provider: %kind{model: model}}} =
          state,
        :reuse
      )
      when kind in [Connecting, Up],
      do: state

  def run(%State{phase: %Preparing{turn: turn} = phase} = state, _mode),
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

  # Arms the idle timer when the session holds a ready provider process
  # with no turn and no wait. It cancels the earlier timer; a message of
  # it that is already in the mailbox has an old ref.
  @spec arm_idle(State.t()) :: State.t()
  def arm_idle(%State{phase: %Idle{provider: %Up{}}} = state) do
    if state.idle, do: :erlang.cancel_timer(state.idle)
    %{state | idle: :erlang.start_timer(state.provider_ms.idle, self(), :idle_close)}
  end

  def arm_idle(state), do: state
end
