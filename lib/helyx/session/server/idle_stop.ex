defmodule Helyx.Session.Server.IdleStop do
  @moduledoc false
  # The idle stop of a session (docs/features/idle-unload.md): one timer, of
  # the pattern of the provider idle close (`Connect.arm_idle/1`), that stops
  # a session that nobody watches and that has no work. The facts are checked
  # at the arm and again at the fire, so a fact that changed after the arm
  # keeps the session.

  alias Helyx.Session.{Hands, Queue}
  alias Helyx.Session.Server.{Asks, Flow, State}

  # The call to the hands reads one map, which takes well under a millisecond;
  # 1,000 ms is the margin for load. A call with no answer proves nothing, so
  # the session stays.
  @live_runs_ms 1_000
  def live_runs_ms, do: @live_runs_ms

  # The largest time that `:erlang.start_timer/3` takes, in ms; a larger
  # value is a `badarg` in the session. The Core check reads it, so a value
  # that a session cannot arm is refused at the start, not at the first arm
  # (docs/features/idle-unload.md).
  @max_ms 4_294_967_295
  def max_ms, do: @max_ms

  # Cancels the timer of an earlier arm and arms one when the facts hold. A
  # nil `idle_stop_ms` or a failed fact holds no timer.
  @spec arm(State.t()) :: State.t()
  def arm(%State{idle_stop: ref} = state) do
    if ref, do: :erlang.cancel_timer(ref)

    case state.idle_stop_ms do
      nil ->
        %{state | idle_stop: nil}

      ms ->
        if quiet?(state),
          do: %{state | idle_stop: :erlang.start_timer(ms, self(), :idle_stop)},
          else: %{state | idle_stop: nil}
    end
  end

  # The timer fired: the facts decide, not the arm. A stop runs the normal
  # stop path, which frees the place of the session (`Helyx.Session.Server.Stop`).
  @spec fired(State.t()) :: {:stop, {:shutdown, :idle}, State.t()} | {:noreply, State.t()}
  def fired(%State{} = state) do
    if quiet?(state) do
      {:stop, {:shutdown, :idle}, %{state | idle_stop: nil}}
    else
      {:noreply, %{state | idle_stop: nil}}
    end
  end

  # The six facts of the idle stop: no turn and no wait, no subscriber, an
  # empty queue, no open ask, a session that saves to a file, and hands that
  # hold no live background run. The ask is implied by the phase today; the
  # check reads it so a change to that rule does not unload a session with an
  # open ask.
  @spec quiet?(State.t()) :: boolean()
  def quiet?(
        %State{phase: %Flow.Idle{}, subscribers: subscribers, save: save, hands: hands} = state
      )
      when map_size(subscribers) == 0 and is_pid(hands) do
    Queue.empty?(state.queue) and Asks.snapshot(state) == [] and
      match?({:saving, _}, save) and quiet_hands?(hands)
  end

  def quiet?(_state), do: false

  defp quiet_hands?(hands) do
    Hands.live_runs(hands, live_runs_ms()) == 0
  catch
    :exit, _reason -> false
  end
end
