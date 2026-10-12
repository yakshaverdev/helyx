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
  # messages of `handle/2`; `work/1` lists the work that a session stop
  # ends (`Helyx.Session.Server.Stop`).

  import Helyx.Session.Server.State, only: [ask: 4]
  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.{Context, Message}
  alias Helyx.Session.{Hands, Id, ProviderProcess, Transcript, Turn}
  alias Helyx.Session.Server.{ProviderConn, Records, State, Steering, Wait}

  # A client prompt, steer, or follow-up by phase; returns the reply and the
  # state. An abort waits for the hands: a turn that starts now could send
  # a tool call to the hands during their release, and that call would
  # block the session, so every message queues until the hands answer.
  # `Steering.steer/2` accepts a steer on a turn or a wait.
  def admit(_op, text, %State{activity: :idle} = state), do: {:ok, begin_turn(state, [text])}

  def admit(:prompt, _text, %State{activity: %Turn{}} = state),
    do: {{:error, :turn_running}, state}

  def admit(:steer, text, state), do: Steering.steer(state, text)
  def admit(_op, text, state), do: Steering.queue(state, :follow_ups, text)

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

  # The result of the turn's running prepare Task, at the turn start
  # (`preparing`) or for a context request (`submitted`, C1-C4,
  # `one-provider-path.md`).
  def handle(
        {:prepared, turn_id, result},
        %State{activity: %Turn{id: turn_id, prepare: pid}} = state
      )
      when pid != nil,
      do: prepared(state, result)

  # A context request (C1-C4) comes after the events before it, and is
  # answered as a tool result is: only for the submitted turn with no
  # context request open (no prepare Task); at any other time it is a bad
  # action.
  def handle(
        {:need_context, turn_id},
        %State{activity: %Turn{id: turn_id, phase: :submitted, prepare: nil}} = state
      ),
      do: prepare(state)

  def handle({:need_context, turn_id}, %State{activity: %Turn{id: turn_id}} = state),
    do: stop_provider(state, {:bad_action, {:need_context, turn_id}})

  # An answer other than `:ok` ends the provider process, and its
  # `:provider_down` fails the turn.
  def handle(
        {:provider_reply, from, :turn, reply},
        %State{activity: %Turn{pending: from}} = state
      ) do
    phase = if reply == :ok, do: :submitted, else: :submitting
    state = %{state | activity: %{state.activity | pending: nil, phase: phase}}
    if reply == :ok, do: Steering.send_local_steers(state), else: state
  end

  # The answer to a steer, also after its turn ("Steer", `Queue.answer/3`).
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
  # exited, or was killed at its bound. A Task that sent its context is no
  # longer `Turn.prepare`: its `:DOWN` comes after.
  def handle({:DOWN, _ref, :process, pid, reason}, %State{activity: %Turn{prepare: pid}} = state),
    do: prepared(state, {:error, {:task_exit, Message.cap_integers(reason)}})

  # A message for a turn or a provider process that is no longer current,
  # or a reply that nobody waits for. The `:DOWN` of a provider process
  # that the session dropped already, of a prepare Task that sent its
  # context or was killed at its turn end, or of the hands' cleanup request
  # (their `:EXIT` stops the session).
  def handle({:stream_event, _id, :turn_start}, state), do: state
  def handle({:stream_end, _turn_id, _terminal}, state), do: state
  def handle({:provider_ready, _pid}, state), do: state
  def handle({:prepared, _turn_id, _result}, state), do: state
  def handle({:need_context, _turn_id}, state), do: state
  def handle({:provider_reply, _from, _kind, _reply}, state), do: state
  def handle({:timeout, _ref, :idle_close}, state), do: state
  def handle({:DOWN, _ref, :process, _pid, _reason}, state), do: state

  # The answer of the hands to the cleanup request (`Wait.cleanup/2`).
  def handle(message, %State{activity: %Wait{hands: request}} = state) when request != nil,
    do: progress(Wait.cleanup(state, message))

  # Starts a turn with one user message per text, in order.
  defp begin_turn(%State{} = state, texts) do
    turn = %Turn{id: Id.new(), model: state.model, provider: state.provider}
    state = open_turn(state, turn, %{})
    call_provider(Enum.reduce(texts, state, &Records.append_user(&2, &1)))
  end

  # A turn that the provider started by itself (#240): a submitted turn
  # with no user message.
  defp start_provider_turn(%State{conn: %ProviderConn{model: model}} = state, turn_id) do
    turn = %Turn{id: turn_id, model: model, provider: state.provider, phase: :submitted}
    open_turn(state, turn, %{origin: :provider})
  end

  defp open_turn(state, turn, data),
    do: emit(%{state | activity: turn}, :turn_start, data)

  # The provider process (started at the first turn) and the prepare Task,
  # which builds the context; a turn that connects again keeps its prepare.
  defp call_provider(%State{activity: %Turn{phase: phase}} = state) do
    case connect(state) do
      {:ok, state} -> if phase, do: state, else: prepare(put_in(state.activity.phase, :preparing))
      {:error, text} -> fail_turn(text, state)
    end
  end

  # Starts the provider process of the turn under the hands, with the
  # resume id of the transcript, and monitors it (`monitor_down/1`). A
  # provider process of another model was closed before the turn
  # (`close_switched/1`). An `:ending` process holds a wait, so no turn
  # reuses it.
  defp connect(
         %State{conn: %ProviderConn{model: model, status: status}, activity: %Turn{model: model}} =
           state
       )
       when status != :ending,
       do: {:ok, state}

  defp connect(%State{conn: nil, activity: turn} = state) do
    resumed = Transcript.resumable(state.transcript, state.resume_ids, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tool_specs,
      opts: [resume_id: resumed] ++ base_opts(state),
      session: self()
    }

    with {:ok, pid} <-
           Hands.start_provider(state.hands, turn.provider, ProviderProcess.run(args)) do
      Process.monitor(pid)
      conn = %ProviderConn{pid: pid, model: turn.model, turn: turn.id, resumed: resumed}
      {:ok, %{state | conn: conn}}
    end
  end

  defp base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]

  # The prepare Task builds the context, at the turn start and at each
  # context request. The session owns it: a child of the task supervisor,
  # monitored, its pid in `Turn.prepare`, killed at the turn end. Its kill
  # at `prepare_ms` is armed as its first act, before any plugin code.
  defp prepare(%State{activity: %Turn{id: turn_id}} = state) do
    session = self()
    %State{model_context: model_context, compaction: compaction, prepare_ms: ms} = state
    context = %Context{messages: state.transcript, tools: state.tool_specs}
    opts = [turn_id: turn_id] ++ base_opts(state)

    {:ok, pid} =
      Task.Supervisor.start_child(Helyx.Core.task_supervisor(state.core), fn ->
        {:ok, tref} = :timer.kill_after(ms)
        result = Helyx.Session.Stream.prepare(model_context, compaction, context, opts)
        :timer.cancel(tref)
        send(session, {:prepared, turn_id, result})
      end)

    Process.monitor(pid)
    put_in(state.activity.prepare, pid)
  end

  # The checked context (`Stream.prepare/4`), or the error of the prepare
  # Task: a plugin that returned anything else, or a Task that died. In
  # `preparing` an error fails the turn; a context request gets it as the
  # answer.
  defp prepared(%State{activity: %Turn{phase: :preparing} = turn} = state, result) do
    state = %{state | activity: %{turn | prepare: nil}}

    case result do
      {:ok, context} -> submit(put_in(state.activity.context, context))
      {:error, reason} -> fail_turn(reason, state)
    end
  end

  defp prepared(%State{activity: %Turn{phase: :submitted} = turn, conn: conn} = state, result) do
    ask(state, conn.pid, {:context, turn.id, result}, :reply)
    %{state | activity: %{turn | prepare: nil}}
  end

  # Sends `{:turn, ...}` when the provider process is ready and the context
  # is prepared. The steers queued in `preparing` join the transcript and
  # the end of the context: they are part of the prompt, not steers.
  defp submit(
         %State{
           activity: %Turn{phase: :preparing, context: context},
           conn: %ProviderConn{pid: pid, status: :ready}
         } = state
       )
       when context != nil do
    {steers, %State{activity: turn} = state} = Steering.append_steers(state)
    context = %{context | messages: context.messages ++ Enum.map(steers, &Message.user/1)}
    from = ask(state, pid, {:turn, turn.id, context}, :reply)
    %{state | activity: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  defp submit(state), do: state

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

  # Idle, when it comes before the session's `:DOWN` (no order between them).
  defp provider_down(%State{activity: :idle} = state, _conn, _reason),
    do: Steering.provider_down(state)

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
  # session settles too: a late `:rejected` can queue a steer.
  defp progress(%State{activity: %Wait{}, conn: %ProviderConn{status: :ending}} = state),
    do: state

  defp progress(%State{activity: %Wait{hands: nil, reply: nil} = wait} = state) do
    Enum.each(wait.callers, &GenServer.reply(&1, :ok))
    settle(%{state | activity: :idle})
  end

  defp progress(%State{activity: :idle} = state), do: settle(state)
  defp progress(state), do: state

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

  # A normal turn end starts the next turn from the queue (`Queue.drain/1`),
  # so each turn end starts one more while the queue holds a text. The
  # drain event goes out between the turns, with a nil turn id.
  defp start_queued(%State{} = state) do
    case Steering.drain(state) do
      {[], state} -> state
      {texts, state} -> begin_turn(state, texts)
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
    do: progress(Wait.finish(state, {:done, stop_reason, usage}))

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # A provider output outside the contract: the turn fails, and the
  # provider process stops with `{:shutdown, reason}`; the hands release it
  # and the wait lasts until its `:provider_down`.
  def stop_provider(%State{conn: %ProviderConn{pid: pid}} = state, reason) do
    Process.exit(pid, {:shutdown, reason})
    fail_turn(reason, put_in(state.conn.status, :ending))
  end

  defp fail_turn(reason, state), do: Wait.finish(state, {:error, reason})

  # The work that a session stop ends (`Helyx.Session.Server.Stop`): in a
  # turn, its prepare Task, to kill; the hands take its provider process.
  # With no turn, the provider process, also one that ends (an idle close,
  # a switch close, an abort), to close.
  @spec work(State.t()) :: %{kill: [pid()], close: [pid()]}
  def work(%State{activity: %Turn{prepare: pid}}), do: %{kill: List.wrap(pid), close: []}
  def work(%State{conn: %ProviderConn{pid: pid}}), do: %{kill: [], close: [pid]}
  def work(_state), do: %{kill: [], close: []}
end
