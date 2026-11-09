defmodule Helyx.Session.Server.Settle do
  @moduledoc false
  # The `before_settle` chain of a session and its continue turn
  # (docs/features/before-settle.md): the only writer of `settle` in
  # `Helyx.Session.Server.Wait`. A wait after a done turn that is not a
  # compaction has the chain `due` when a hook is on the point; it starts
  # when no other part of the wait is left (`TurnLoop.progress/1`), and
  # the wait lasts until its answer. A continue waits in the queue
  # (`Helyx.Session.Queue`, `continue`) for the next turn, which
  # `TurnLoop.start_queued/1` starts after a waiting compaction and ahead
  # of the queued texts; the queue counts the turns in a row that a
  # continue started (`hook_turns`), and drops a waiting continue at an
  # abort or a failed turn.

  import Helyx.Session.Server.Events, only: [emit: 4]

  alias Helyx.Message
  alias Helyx.Session.Hands
  alias Helyx.Session.Server.Flow.Waiting
  alias Helyx.Session.Server.{State, Steering, TurnLoop, Wait}
  alias Helyx.Session.Turn

  # The most turns in a row that a continue starts.
  @max_turns 8

  # The wait that `turn` ended at `outcome` (`Wait.finish/2`). After a done
  # turn that is not a compaction the chain is due, when a hook is on the
  # point: the input of the hooks, with the session's folder, and the
  # context of a call of the turn with no tool.
  @spec finish(State.t(), Turn.t(), term()) :: State.t()
  def finish(state, turn, {:done, stop_reason, _usage}) do
    if turn.compact == nil and is_map_key(Helyx.Core.hooks(state.core), :before_settle) do
      input = %{
        session_id: state.id,
        turn_id: turn.id,
        stop_reason: stop_reason,
        cwd: state.cwd
      }

      put_wait(state, settle: {:due, input, State.tool_context(state, turn.model)})
    else
      state
    end
  end

  def finish(state, _turn, _aborted_or_failed), do: state

  # The due chain starts in the hands, when no other part of its wait is
  # left; the wait holds the ref of the request.
  @spec start(State.t()) :: State.t()
  def start(%State{phase: %Waiting{wait: %Wait{settle: {:due, input, context}} = wait}} = state) do
    ref = Hands.Settle.request(state.hands, wait.turn, input, context)
    put_wait(state, settle: ref)
  end

  # The answer of the chain of the current wait. An answer of a chain that
  # an abort cancelled finds no ref, and is dropped.
  @spec answer(State.t(), reference(), term()) :: State.t()
  def answer(%State{phase: %Waiting{wait: %Wait{settle: ref}}} = state, ref, answer),
    do: TurnLoop.progress(continue(put_wait(state, settle: nil), answer))

  def answer(state, _ref, _answer), do: state

  defp continue(state, :settle), do: state

  defp continue(%State{queue: %{hook_turns: turns}} = state, {:continue, module, _text})
       when turns >= @max_turns do
    text =
      "the hook #{inspect(module)} asked for one more turn past the limit of " <>
        "#{@max_turns} turns in a row that hooks start; the session settled"

    emit(state, nil, :notice, %{text: text})
  end

  defp continue(state, {:continue, module, text}),
    do: Steering.continue(state, Message.user(text, Message.hook_origin(module)))

  # An abort in a wait cancels a running chain with the Tasks of the ended
  # turn: the wait holds the answer of the hands, as at the abort of a
  # turn. A due chain does not start. The queue dropped a waiting continue
  # (`Queue.abort/1`).
  @spec abort(State.t()) :: State.t()
  def abort(%State{phase: %Waiting{wait: %Wait{settle: ref} = wait}} = state)
      when is_reference(ref),
      do: put_wait(state, settle: nil, hands: Hands.request_cancel(state.hands, wait.turn))

  def abort(%State{phase: %Waiting{}} = state), do: put_wait(state, settle: nil)

  # A failed hook of the current chain of the turn `turn_id` gets a
  # notice; a later answer, after an abort cancelled the chain, gets none.
  @spec current?(State.t(), String.t()) :: boolean()
  def current?(%State{phase: %Waiting{wait: %Wait{turn: turn_id, settle: ref}}}, turn_id),
    do: is_reference(ref)

  def current?(_state, _turn_id), do: false

  defp put_wait(%State{phase: %Waiting{wait: wait} = phase} = state, fields),
    do: %{state | phase: %{phase | wait: struct!(wait, fields)}}
end
