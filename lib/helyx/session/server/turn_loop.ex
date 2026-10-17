defmodule Helyx.Session.Server.TurnLoop do
  @moduledoc false
  # The turn lifecycle of a session, its one owner: it matches each
  # lifecycle input to the current activity and makes the transitions of
  # `activity` and `conn` in `Helyx.Session.Server.State`
  # (docs/features/session-lifecycle.md, "Turn states", "Turn end",
  # and "The wait"). The turn starts, connects its provider process,
  # prepares its context, is submitted, and ends; the wait after it lasts
  # until the hands, the open reply, and a provider process that ends are
  # done. The inputs are the client calls (`admit/3`, `abort/2`) and the
  # messages of `handle/2`. A compaction is a turn too (`Compaction`).

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Session.{Hands, Id, ProviderProcess, Queue, Transcript, Turn}
  alias Helyx.Session.Server.{Compaction, Prepare, ProviderConn, Records, State, Steering}
  alias Helyx.Session.Server.{Summary, Wait}

  # A client prompt, steer, or follow-up by phase; returns the reply and the
  # state. An abort waits for the hands: a turn that starts now could send
  # a tool call to the hands during their release, and that call would
  # block the session, so every message queues until the hands answer.
  # `Steering.steer/2` accepts a steer on a turn or a wait.
  def admit(_op, user, %State{activity: :idle} = state), do: {:ok, begin_turn(state, [user])}

  def admit(:prompt, _user, %State{activity: %Turn{}} = state),
    do: {{:error, :turn_running}, state}

  def admit(:steer, user, state), do: Steering.steer(state, user)
  def admit(_op, user, state), do: Steering.queue(state, :follow_ups, user)

  # A lifecycle message, matched to the current turn, wait, or provider
  # process ("Turn states"). The turn is `preparing` until the session
  # sends `{:turn, ...}`, which needs a ready provider process and the
  # prepared context; `submitting` until the answer; then `submitted`.
  #
  # A turn that the provider started by itself (#240) opens only with no
  # turn and no wait; any other time it is dropped with its events.
  @spec handle(term(), State.t()) :: State.t()
  def handle(
        {:stream_event, turn_id, :turn_start},
        %State{activity: :idle, conn: %ProviderConn{status: :ready}} = state
      ),
      do: start_provider_turn(state, turn_id)

  def handle({:stream_end, turn_id, terminal}, %State{activity: %Turn{id: turn_id}} = state),
    do: end_turn(terminal, state)

  # A process that the session stopped is `:ending`, and it stays `:ending`.
  def handle(
        {:provider_ready, pid},
        %State{conn: %ProviderConn{pid: pid, status: :starting}} = state
      ),
      do: arm_idle(submit(put_in(state.conn.status, :ready)))

  # The reply of the turn's running prepare Task, at the turn start
  # (`preparing`) or for a context request (`submitted`, C1-C4,
  # `one-provider-path.md`).
  def handle(
        {_ref, {:prepared, turn_id, result}},
        %State{activity: %Turn{id: turn_id, prepare: pid}} = state
      )
      when pid != nil,
      do: Prepare.prepared(state, result)

  # A context request (C1-C4) comes after the events before it, and is
  # answered as a tool result is: only for the submitted turn with no
  # context request open (no prepare Task, no summary call for it), not a
  # compaction; at any other time it is a bad action. One after a context
  # overflow builds with the trigger `:overflow`
  # (docs/features/summary-compaction.md).
  def handle({:need_context, id}, state), do: handle({:need_context, id, :auto}, state)

  def handle(
        {:need_context, id, why},
        %State{activity: %Turn{id: id, phase: :submitted, prepare: nil, compact: nil}} = state
      ) do
    if Summary.open?(state),
      do: stop_provider(state, {:bad_action, {:need_context, id}}),
      else: Prepare.start(state, why)
  end

  def handle({:need_context, turn_id, _why}, %State{activity: %Turn{id: turn_id}} = state),
    do: stop_provider(state, {:bad_action, {:need_context, turn_id}})

  # The answer to `{:turn, ...}` or `{:compact, ...}`. An error ends the
  # provider process, and its `:provider_down` fails the turn.
  def handle({:provider_reply, from, kind, reply}, %State{activity: %Turn{pending: from}} = state) do
    phase = if reply == :ok, do: :submitted, else: :submitting
    state = %{state | activity: %{state.activity | pending: nil, phase: phase}}

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

  def handle({:provider_reply, from, kind, reply}, %State{activity: %Wait{reply: from}} = state),
    do: progress(Wait.answered(state, kind, reply))

  # Only the current idle timer counts, and only while the session is
  # idle: a turn or a wait since it was armed makes it old. The wait holds
  # every message until the answer.
  def handle(
        {:timeout, ref, :idle_close},
        %State{idle: ref, activity: :idle, conn: %ProviderConn{pid: pid, status: :ready}} = state
      ) do
    from = ask(state, pid, :idle_close, :close)
    %{state | idle: nil, activity: %Wait{reply: from}}
  end

  # From the hands, after the release of the provider process's handles:
  # the end of the session's provider process. A process leaves `conn`
  # only here, so any other `:provider_down` is a bug and crashes the
  # session.
  def handle({:provider_down, pid, reason}, %State{conn: %ProviderConn{pid: pid} = conn} = state),
    do: provider_down(%{state | conn: nil}, conn, reason)

  # The session's monitor of the current provider process (#361).
  def handle(
        {:DOWN, _ref, :process, pid, _reason},
        %State{conn: %ProviderConn{pid: pid}} = state
      ),
      do: monitor_down(state)

  # The end of the turn's prepare Task before its context: it raised,
  # exited, or was killed at its bound (`:context_timeout`). A Task that
  # sent its context is no longer `Turn.prepare`: its `:DOWN` comes after.
  def handle({:DOWN, _ref, :process, pid, reason}, %State{activity: %Turn{prepare: pid}} = state),
    do: Prepare.prepared(state, {:error, Prepare.down_reason(reason)})

  # A message for a turn or a provider process that is no longer current,
  # or a reply that nobody waits for. The `:DOWN` of a provider process
  # that the session dropped already, of a prepare Task that sent its
  # context or was killed at its turn end, or of the hands' cleanup request
  # (their `:EXIT` stops the session).
  def handle({:stream_event, _id, :turn_start}, state), do: state
  def handle({:stream_end, _turn_id, _terminal}, state), do: state
  def handle({:provider_ready, _pid}, state), do: state
  def handle({_ref, {:prepared, _turn_id, _result}}, state), do: state
  def handle({:need_context, _turn_id, _why}, state), do: state
  def handle({:provider_reply, _from, _kind, _reply}, state), do: state
  def handle({:timeout, _ref, :idle_close}, state), do: state
  def handle({:DOWN, _ref, :process, _pid, _reason}, state), do: state

  # The answer of the hands to the cleanup request (`Wait.cleanup/2`).
  def handle(message, %State{activity: %Wait{hands: request}} = state) when request != nil,
    do: progress(Wait.cleanup(state, message))

  # Starts a turn with the user messages, in order.
  defp begin_turn(%State{} = state, users) do
    turn = %Turn{id: Id.new(), model: state.model, provider: state.provider}
    state = Steering.open(open_turn(state, turn, %{}))
    call_provider(Enum.reduce(users, state, &Records.append_user(&2, &1)))
  end

  # A turn that the provider started by itself (#240): a submitted turn
  # with no user message.
  defp start_provider_turn(%State{conn: %ProviderConn{model: model}} = state, turn_id) do
    turn = %Turn{id: turn_id, model: model, provider: state.provider, phase: :submitted}
    Steering.open(open_turn(state, turn, %{origin: :provider}))
  end

  defp open_turn(state, turn, data),
    do: emit(%{state | activity: Turn.open(turn, length(state.transcript))}, :turn_start, data)

  # The provider process (started at the first turn) and the prepare Task,
  # which builds the context; a turn that connects again keeps its prepare.
  defp call_provider(%State{activity: %Turn{phase: phase}} = state) do
    case connect(state) do
      {:ok, state} ->
        if phase, do: state, else: Prepare.start(put_in(state.activity.phase, :preparing), :auto)

      {:error, text} ->
        fail_turn(text, state)
    end
  end

  # Starts the provider process of the turn under the hands, with the resume
  # of the messages before the turn, and monitors it (`monitor_down/1`). A
  # process of another model was closed before (`close_switched/1`). An
  # `:ending` process holds a wait, so no turn reuses it.
  defp connect(
         %State{conn: %ProviderConn{model: model, status: status}, activity: %Turn{model: model}} =
           state
       )
       when status != :ending,
       do: {:ok, state}

  defp connect(%State{conn: nil, activity: turn} = state) do
    history = Enum.take(state.transcript, turn.start)
    {resumed, usage} = Transcript.resume(history, state.resume_ids, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tool_specs,
      opts: [resume_id: resumed, resume_usage: usage] ++ State.base_opts(state),
      session: self()
    }

    with {:ok, pid} <-
           Hands.start_provider(state.hands, turn.provider, ProviderProcess.run(args)) do
      Process.monitor(pid)
      conn = %ProviderConn{pid: pid, model: turn.model, turn: turn.id, resumed: resumed}
      {:ok, %{state | conn: conn}}
    end
  end

  # Sends `{:turn, ...}` when the provider process is ready and the context
  # is prepared. The steers queued in `preparing`, then the background
  # ends, join the transcript and the context: part of the prompt.
  def submit(
        %State{
          activity: %Turn{phase: :preparing, context: context},
          conn: %ProviderConn{pid: pid, status: :ready}
        } = state
      )
      when context != nil do
    {steers, %State{activity: turn} = state} = Steering.append_steers(state)
    context = %{context | messages: context.messages ++ steers}
    from = ask(state, pid, {:turn, turn.id, context}, :reply)
    %{state | activity: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  def submit(state), do: Compaction.submit(state)

  # The end of the session's provider process, `conn` already nil: no
  # request to it is open any more. In a wait its reply ends too. In a turn
  # it fails the turn, whose cleanup the hands then run after the release;
  # the turn end gives the steer notices first. Only a process of an
  # earlier turn that ends while this turn prepares got nothing of it: the
  # turn connects a new one, once.
  defp provider_down(%State{activity: %Wait{} = wait} = state, _conn, _reason),
    do: progress(Steering.provider_down(%{state | activity: %{wait | reply: nil}}))

  defp provider_down(
         %State{activity: %Turn{phase: :preparing, id: id}} = state,
         %ProviderConn{turn: started_by},
         _reason
       )
       when started_by != id,
       do: call_provider(Steering.provider_down(state))

  defp provider_down(%State{activity: %Turn{}} = state, _conn, reason),
    do: Steering.provider_down(fail_turn(reason, state))

  # Idle, before the session's `:DOWN` (no fixed order): given-back ends hold.
  defp provider_down(%State{activity: :idle} = state, _conn, _reason),
    do: settle(Steering.provider_down(state))

  # The session's monitor of the current provider process (#361). Outside a
  # sent turn the process is `:ending`: in a preparing turn it holds back
  # `{:turn, ...}`, and with no turn the session waits, until its
  # `:provider_down`. In a sent turn its `:provider_down` fails the turn.
  defp monitor_down(%State{activity: %Turn{phase: phase}} = state)
       when phase in [:submitting, :submitted],
       do: state

  defp monitor_down(%State{activity: activity} = state) do
    activity = if activity == :idle, do: %Wait{}, else: activity
    %{put_in(state.conn.status, :ending) | activity: activity}
  end

  # The release of the hands can take longer than the timeout of a client
  # call (issue #93), so the abort of a turn or a wait gets its reply when
  # the wait ends, not in the call. With no turn and no wait the reply is
  # at once; a steer of an ended turn can still wait for its answer, and
  # gets its notice now (`Queue.abort/1`).
  def abort(%State{activity: :idle} = state, from) do
    state = Steering.abort(state)
    GenServer.reply(from, :ok)
    state
  end

  def abort(%State{activity: %Wait{}} = state, from), do: progress(Wait.abort(state, from))

  def abort(%State{activity: %Turn{}} = state, from),
    do: put_in(Wait.finish(state, :aborted).activity.callers, [from])

  # At the end of the wait the abort callers get their reply. An idle
  # session settles too: a late `:rejected` can queue a steer. A process
  # that ends, the session's or a summary call's, holds the wait.
  def progress(%State{activity: %Wait{}, conn: %ProviderConn{status: :ending}} = state),
    do: state

  def progress(%State{activity: %Wait{}, summary_call: %Summary{}} = state), do: state

  def progress(%State{activity: %Wait{hands: nil, reply: nil} = wait} = state) do
    Enum.each(wait.callers, &GenServer.reply(&1, :ok))
    settle(%{state | activity: :idle})
  end

  def progress(%State{activity: :idle} = state), do: settle(state)
  def progress(state), do: state

  # With no turn and no wait, a provider process of another model than the
  # session's closes before the next turn starts (a provider or a model
  # switch); otherwise the queues start the next turn.
  def settle(%State{activity: :idle} = state) do
    with %State{activity: :idle} = state <- close_switched(state) do
      arm_idle(start_queued(state))
    end
  end

  def settle(state), do: state

  # A provider process of another model than the session's closes, and the
  # session waits for its end.
  defp close_switched(%State{model: model, conn: %ProviderConn{pid: pid, model: other}} = state)
       when other != model do
    ask(state, pid, :close, :close)
    %{put_in(state.conn.status, :ending) | activity: %Wait{}}
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
  defp arm_idle(%State{activity: :idle, conn: %ProviderConn{status: :ready}} = state) do
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
  def stop_provider(%State{conn: %ProviderConn{pid: pid}} = state, reason) do
    Process.exit(pid, {:shutdown, reason})
    fail_turn(reason, put_in(state.conn.status, :ending))
  end

  def fail_turn(reason, state), do: Wait.finish(state, {:error, reason})
end
