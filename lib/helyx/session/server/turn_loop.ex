defmodule Helyx.Session.Server.TurnLoop do
  @moduledoc false
  # The turn lifecycle of a session, its one owner: it matches each
  # lifecycle input to the current phase and makes the transitions of
  # `Helyx.Session.Server.Flow` in `Helyx.Session.Server.State`
  # (docs/features/session-lifecycle.md, "Turn states", "Turn end", "The
  # wait"). The turn starts, connects its provider process, prepares its
  # context, is submitted, and ends; the wait after it lasts until the hands,
  # the open reply, and a provider process that ends are done. The inputs are
  # `admit/3`, `abort/2`, and `handle/2`; a compaction is a turn too.

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3]
  import Helyx.Session.Server.Flow, only: [is_turn: 1]

  alias Helyx.Session.{Id, Queue, Turn}
  alias Helyx.Session.Server.{Compaction, Connect, Prepare, Records, State, Steering}
  alias Helyx.Session.Server.Flow
  alias Helyx.Session.Server.Flow.{Connecting, Dying, Idle, Live, Preparing, Sending, Up, Waiting}
  alias Helyx.Session.Server.{Summary, Wait}

  # A client prompt, steer, or follow-up by phase; returns the reply and the
  # state. An abort waits for the hands: a turn that starts now could send
  # a tool call to the hands during their release, and that call would
  # block the session, so every message queues until the hands answer.
  # `Steering.steer/2` accepts a steer on a turn or a wait.
  def admit(_op, user, %State{phase: %Idle{}} = state), do: {:ok, begin_turn(state, [user])}

  def admit(:prompt, _user, %State{phase: %{turn: %Turn{}}} = state),
    do: {{:error, :turn_running}, state}

  def admit(:steer, user, state), do: Steering.steer(state, user)
  def admit(_op, user, state), do: Steering.queue(state, :follow_ups, user)

  # A lifecycle message, matched to the current turn, wait, or provider
  # process ("Turn states"). The turn is `Preparing` until the session
  # sends `{:turn, ...}`, which needs a ready provider process and the
  # prepared context; `Sending` until the answer; then `Live`.
  #
  # A turn that the provider started by itself (#240) opens only with no
  # turn and no wait; any other time it is dropped with its events.
  @spec handle(term(), State.t()) :: State.t()
  def handle(
        {:stream_event, turn_id, :turn_start},
        %State{phase: %Idle{provider: %Up{} = provider}} = state
      ),
      do: start_provider_turn(state, provider, turn_id)

  def handle(
        {:stream_end, turn_id, terminal},
        %State{phase: %{turn: %Turn{id: turn_id}}} = state
      ),
      do: end_turn(terminal, state)

  # A process that the session stopped is dying, and it stays dying.
  def handle(
        {:provider_ready, pid},
        %State{phase: %{provider: %Connecting{pid: pid} = provider} = phase} = state
      ),
      do: arm_idle(submit(%{state | phase: %{phase | provider: Flow.up(provider)}}))

  # The reply of the turn's running prepare Task, at the turn start
  # (`Preparing`) or for a context request (`Live`, C1-C4,
  # `one-provider-path.md`).
  def handle(
        {ref, {:prepared, result}},
        %State{phase: %{turn: %Turn{prepare: {ref, _, _}}}} = state
      ),
      do: Prepare.prepared(state, result)

  # A context request (C1-C4) comes after the events before it, and is
  # answered as a tool result is: only for the `Live` turn with no
  # context request open (no prepare Task, no summary call for it, no
  # `{:context, ...}` without the provider's reply), not a compaction; at
  # any other time it is a bad action. One after a context overflow builds
  # with the trigger `:overflow` (docs/features/summary-compaction.md).
  def handle({:need_context, id}, state), do: handle({:need_context, id, :auto}, state)

  def handle(
        {:need_context, id, why},
        %State{phase: %Live{turn: %Turn{id: id, prepare: nil, compact: nil}, pending: nil}} =
          state
      ) do
    if Summary.open?(state),
      do: stop_provider(state, {:bad_action, {:need_context, id}}),
      else: Prepare.start(state, why)
  end

  def handle({:need_context, turn_id, _why}, %State{phase: %{turn: %Turn{id: turn_id}}} = state),
    do: stop_provider(state, {:bad_action, {:need_context, turn_id}})

  # The answer to `{:turn, ...}`, `{:compact, ...}`, or `{:context, ...}`;
  # the last one closes the context request. An error ends the provider
  # process, and its `:provider_down` fails the turn.
  def handle({:provider_reply, from, kind, reply}, %State{phase: phase} = state)
      when is_turn(phase) and phase.pending == from do
    phase =
      if reply == :ok,
        do: %Live{turn: phase.turn, provider: phase.provider, pending: nil},
        else: %Sending{turn: phase.turn, provider: phase.provider, pending: nil}

    state = %{state | phase: phase}

    case {kind, reply} do
      {:turn, :ok} -> Steering.send_local_steers(state)
      {:compact, :unsupported} -> Prepare.start(state, :manual)
      _ -> state
    end
  end

  # The answer to a steer, also after its turn ("Steer", `Queue.answer/4`).
  # A late `:rejected` queues the steer, and an idle session starts it.
  def handle({:provider_reply, from, :steer, reply}, state),
    do: progress(Steering.answer(state, from, reply))

  def handle(
        {:provider_reply, from, kind, reply},
        %State{phase: %Waiting{wait: %Wait{reply: from}}} = state
      ),
      do: progress(Wait.answered(state, kind, reply))

  # Only the current idle timer counts, and only while the session is
  # idle: a turn or a wait since it was armed makes it old. The wait holds
  # every message until the answer.
  def handle(
        {:timeout, ref, :idle_close},
        %State{idle: ref, phase: %Idle{provider: %Up{pid: pid} = provider}} = state
      ) do
    from = ask(state, pid, :idle_close, :close)
    %{state | idle: nil, phase: %Waiting{wait: %Wait{reply: from}, provider: provider}}
  end

  # From the hands, after the release of the provider process's handles: the
  # end of the session's provider process. A provider process leaves the
  # phase only here, so any other `:provider_down` is a bug and crashes.
  def handle(
        {:provider_down, pid, reason},
        %State{phase: %{provider: %{pid: pid} = provider}} = state
      ),
      do: provider_down(state, provider, reason)

  # The answer of the hands to the start of the session's provider process
  # (`Connect.run/1`), in a `Preparing` turn or in the wait after it.
  # session monitors the process (`monitor_down/1`) and lets it run: a turn
  # that ended before the answer keeps it, as one that ended after does
  # (#726). A refusal fails the turn; in a wait the turn has ended already.
  def handle(
        {:provider_start, ref, {:ok, pid}},
        %State{phase: %{provider: %Connecting{start: ref} = provider} = phase} = state
      ) do
    Process.monitor(pid)
    send(pid, :start)
    %{state | phase: %{phase | provider: %{provider | pid: pid}}}
  end

  def handle(
        {:provider_start, ref, {:error, text}},
        %State{phase: %{turn: %Turn{}, provider: %{start: ref}}} = state
      ),
      do: Wait.finish(state, {:error, text}, :none)

  def handle(
        {:provider_start, ref, {:error, _text}},
        %State{phase: %{provider: %{start: ref}} = phase} = state
      ),
      do: progress(%{state | phase: Flow.no_provider(phase)})

  # The answer to the start of a summary call (`Summary.started/2`).
  def handle({:provider_start, ref, result}, %State{summary_call: %Summary{start: ref}} = state),
    do: Summary.started(state, result)

  # The session's monitor of the current provider process (#361).
  def handle(
        {:DOWN, _ref, :process, pid, _reason},
        %State{phase: %{provider: %{pid: pid}}} = state
      ),
      do: monitor_down(state)

  # The end of the turn's prepare Task before its context: it raised,
  # exited, or was killed at its bound (`:context_timeout`). A Task that
  # sent its context is no longer `Turn.prepare`: its `:DOWN` comes after.
  def handle(
        {:DOWN, _ref, :process, pid, reason},
        %State{phase: %{turn: %Turn{prepare: {_task_ref, pid, _messages}}}} = state
      ),
      do: Prepare.prepared(state, {:error, Prepare.down_reason(reason)})

  # A message for a turn or a provider process that is no longer current,
  # or a reply that nobody waits for. The `:DOWN` of a provider process
  # that the session dropped already, of a prepare Task that sent its
  # context or was killed at its turn end, or of the hands' cleanup request
  # (their `:EXIT` stops the session).
  def handle({:stream_event, _id, :turn_start}, state), do: state
  def handle({:stream_end, _turn_id, _terminal}, state), do: state
  def handle({:provider_ready, _pid}, state), do: state
  def handle({_ref, {:prepared, _result}}, state), do: state
  def handle({:need_context, _turn_id, _why}, state), do: state
  def handle({:provider_reply, _from, _kind, _reply}, state), do: state
  def handle({:timeout, _ref, :idle_close}, state), do: state
  def handle({:DOWN, _ref, :process, _pid, _reason}, state), do: state

  # The answer of the hands to the cleanup request (`Wait.cleanup/2`).
  def handle(message, %State{phase: %Waiting{wait: %Wait{hands: request}}} = state)
      when request != nil,
      do: progress(Wait.cleanup(state, message))

  # Starts a turn with the user messages, in order.
  defp begin_turn(%State{} = state, users) do
    turn = %Turn{id: Id.new(), model: state.model, provider: state.provider}
    state = Steering.open(open_turn(state, turn, %{}))
    call_provider(Enum.reduce(users, state, &Records.append_user(&2, &1)))
  end

  # A turn that the provider started by itself (#240): a `Live` turn
  # with no user message.
  defp start_provider_turn(%State{} = state, provider, turn_id) do
    turn = %Turn{id: turn_id, model: provider.model, provider: state.provider}
    phase = %Live{turn: Turn.open(turn, length(state.transcript)), provider: provider}
    Steering.open(emit(%{state | phase: phase}, :turn_start, %{origin: :provider}))
  end

  defp open_turn(%State{phase: %Idle{provider: provider}} = state, turn, data) do
    phase = %Preparing{turn: Turn.open(turn, length(state.transcript)), provider: provider}
    emit(%{state | phase: phase}, :turn_start, data)
  end

  # The provider process (started at the first turn, `Connect`) and the
  # prepare Task, which builds the context; a turn that connects again keeps
  # its prepare.
  defp call_provider(state, mode \\ :reuse)

  defp call_provider(
         %State{phase: %Preparing{turn: %Turn{prepare: nil, context: nil}}} = state,
         mode
       ),
       do: state |> Connect.run(mode) |> Prepare.start(:auto)

  defp call_provider(state, mode), do: Connect.run(state, mode)

  # Sends `{:turn, ...}` when the provider process is ready and the context
  # is prepared. The steers queued in `Preparing`, then the background
  # ends, join the transcript and the context: part of the prompt. The
  # recall message goes last (docs/features/memory.md).
  def submit(
        %State{
          phase: %Preparing{turn: %Turn{context: context}, provider: %Up{pid: pid} = provider}
        } = state
      )
      when context != nil do
    {steers, %State{phase: %{turn: turn}} = state} = Steering.append_steers(state)
    context = %{context | messages: context.messages ++ steers ++ List.wrap(turn.recall)}
    from = ask(state, pid, {:turn, turn.id, context}, :reply)
    turn = %{turn | context: nil, recall: nil}
    %{state | phase: %Sending{turn: turn, provider: provider, pending: from}}
  end

  def submit(state), do: Compaction.submit(state)

  # The end of the session's provider process: no request to it is open any
  # more. In a wait its reply ends too. In a turn it fails the turn, whose
  # cleanup the hands then run after the release; the turn end gives the
  # steer notices first. Only a process of an earlier turn that ends while
  # this turn prepares got nothing of it: the turn connects a new one,
  # once.
  defp provider_down(%State{phase: %Waiting{wait: wait} = phase} = state, _provider, _reason) do
    phase = %{phase | provider: :none, wait: %{wait | reply: nil}}
    progress(Steering.provider_down(%{state | phase: phase}))
  end

  defp provider_down(
         %State{phase: %Preparing{turn: %Turn{id: id}}} = state,
         %{turn: started_by},
         _reason
       )
       when started_by != id,
       do: call_provider(Steering.provider_down(state), :restart)

  defp provider_down(%State{phase: %{turn: %Turn{}}} = state, _provider, reason),
    do: Steering.provider_down(Wait.finish(state, {:error, reason}, :none))

  # Idle, before the session's `:DOWN` (no fixed order): given-back ends hold.
  defp provider_down(%State{phase: %Idle{} = phase} = state, _provider, _reason),
    do: settle(Steering.provider_down(%{state | phase: Flow.no_provider(phase)}))

  # The session's monitor of the current provider process (#361). Outside a
  # sent turn the process is dying: in a `Preparing` turn it holds back
  # `{:turn, ...}`, and with no turn the session waits, until its
  # `:provider_down`. In a sent turn its `:provider_down` fails the turn.
  defp monitor_down(%State{phase: %Preparing{provider: provider} = phase} = state),
    do: %{state | phase: %{phase | provider: Flow.dying(provider)}}

  defp monitor_down(%State{phase: %Idle{provider: provider}} = state),
    do: %{state | phase: %Waiting{wait: %Wait{}, provider: Flow.dying(provider)}}

  defp monitor_down(%State{phase: %Waiting{provider: provider} = phase} = state),
    do: %{state | phase: %{phase | provider: Flow.dying(provider)}}

  # In a sent turn the `:DOWN` changes nothing: its `provider_down` fails it.
  defp monitor_down(%State{} = state), do: state

  # The release of the hands can take longer than the timeout of a client
  # call (issue #93), so the abort of a turn or a wait gets its reply when
  # the wait ends, not in the call. With no turn and no wait the reply is
  # at once; a steer of an ended turn can still wait for its answer, and
  # gets its notice now (`Queue.abort/1`).
  def abort(%State{phase: %Idle{}} = state, from) do
    state = Steering.abort(state)
    GenServer.reply(from, :ok)
    state
  end

  def abort(%State{phase: %Waiting{}} = state, from), do: progress(Wait.abort(state, from))

  def abort(%State{phase: %{turn: %Turn{}}} = state, from),
    do: put_in(Wait.finish(state, :aborted).phase.wait.callers, [from])

  # At the end of the wait the abort callers get their reply. An idle
  # session settles too: a late `:rejected` can queue a steer. A process
  # that ends, the session's or a summary call's, holds the wait. A start
  # with no answer holds it too: the cleanup request went to the hands after
  # it, and the hands answer in order.
  def progress(%State{phase: %Waiting{provider: %Dying{}}} = state), do: state

  def progress(%State{phase: %Waiting{}, summary_call: %Summary{}} = state), do: state

  def progress(
        %State{phase: %Waiting{wait: %Wait{hands: nil, reply: nil} = wait} = phase} = state
      ) do
    Enum.each(wait.callers, &GenServer.reply(&1, :ok))
    settle(%{state | phase: %Idle{provider: phase.provider}})
  end

  def progress(%State{phase: %Idle{}} = state), do: settle(state)
  def progress(state), do: state

  # With no turn and no wait, a provider process of another model than the
  # session's closes before the next turn starts (a provider or a model
  # switch); otherwise the queues start the next turn.
  def settle(%State{phase: %Idle{}} = state) do
    with %State{phase: %Idle{}} = state <- close_switched(state) do
      arm_idle(start_queued(state))
    end
  end

  def settle(state), do: state

  # A provider process of another model than the session's closes, and the
  # session waits for its end.
  defp close_switched(
         %State{model: model, phase: %Idle{provider: %{pid: pid, model: other} = provider}} =
           state
       )
       when other != model do
    ask(state, pid, :close, :close)
    %{state | phase: %Waiting{wait: %Wait{}, provider: Flow.dying(provider)}}
  end

  defp close_switched(state), do: state

  # A normal turn end starts the next turn: a waiting compaction, else one
  # from the queue (`Queue.drain/1`), so each turn end starts one more while
  # one waits. The drain event goes out between the turns, with no turn id.
  defp start_queued(%State{pending_compact: text} = state) when text != nil do
    turn = %Turn{id: Id.new(), model: state.model, provider: state.provider, compact: text}
    call_provider(open_turn(%{state | pending_compact: nil}, turn, %{origin: :compaction}))
  end

  defp start_queued(%State{} = state) do
    case Steering.drain(state) do
      {[], state} -> if Queue.wake?(state.queue), do: begin_turn(state, []), else: state
      {users, state} -> begin_turn(state, users)
    end
  end

  # Arms the idle timer when the session holds a ready provider process
  # with no turn and no wait. It cancels the earlier timer; a message of
  # it that is already in the mailbox has an old ref.
  defp arm_idle(%State{phase: %Idle{provider: %Up{}}} = state) do
    if state.idle, do: :erlang.cancel_timer(state.idle)
    %{state | idle: :erlang.start_timer(state.provider_ms.idle, self(), :idle_close)}
  end

  defp arm_idle(state), do: state

  # The terminal of the turn, from the provider process.
  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state),
    do: progress(Wait.finish(state, Compaction.outcome(state, {:done, stop_reason, usage})))

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)

  # A provider output outside the contract: the turn fails, and the
  # provider process stops with `{:shutdown, reason}`; the hands release it
  # and the wait lasts until its `:provider_down`.
  def stop_provider(%State{phase: %{provider: %{pid: pid} = provider}} = state, reason) do
    Process.exit(pid, {:shutdown, reason})
    Wait.finish(state, {:error, reason}, Flow.dying(provider))
  end

  def fail_turn(reason, state), do: Wait.finish(state, {:error, reason})
end
