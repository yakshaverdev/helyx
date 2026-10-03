defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks and the turn loop. The
  # client API and the docs of the behaviour are in `Helyx.Session`.

  require Logger

  alias Helyx.{Context, Message, ModelRef}
  alias Helyx.Session.{Hands, Id, ProviderRequest, Queue, Snapshot, Transcript, Turn}
  alias Helyx.Session.Server.{Messages, ProviderConn, Record, State, Steering, Stop, Tools, Wait}

  import State, only: [ask: 4, provider_pid: 1]
  import Record, only: [emit: 3, emit: 4]

  use GenServer, restart: :temporary, shutdown: Stop.shutdown_ms()

  def start_link(%State{id: id, core: core} = state) do
    GenServer.start_link(__MODULE__, state, name: via(core, id))
  end

  # Callbacks

  @impl true
  def init(%State{} = state) do
    # The session traps exits: the hands are linked, so their crash arrives
    # as a message, and a death of the session takes them with it (ADR 0004).
    Process.flag(:trap_exit, true)

    # The tool checks ran before the session started, so the hands' init
    # cannot fail (#150).
    {:ok, hands} =
      Hands.start_link(
        core: state.core,
        cwd: state.cwd,
        session: self(),
        tools: state.tool_modules
      )

    {:ok, %{state | hands: hands, instance_id: Id.new()}}
  end

  # An abort waits for the hands. A turn that starts now could send a tool
  # call to the hands during their release, and that call would block the
  # session, so every message queues until the hands answer.
  @impl true
  def handle_call({:steer, text}, _from, %State{activity: %Wait{}} = state),
    do: queue_reply(state, :steers, text)

  def handle_call({op, text}, _from, %State{activity: %Wait{}} = state)
      when op in [:prompt, :follow_up] do
    queue_reply(state, :follow_ups, text)
  end

  # An abort drops the queues, like the abort that started the wait, so no
  # message sent before it starts a turn.
  # A steer that still waits for its answer gets its notice now: a late
  # `:rejected` must not queue it again after the abort.
  def handle_call(:abort, from, %State{activity: %Wait{} = wait} = state) do
    state = Steering.drop_queues(%{state | activity: %{wait | callers: [from | wait.callers]}})
    {:noreply, progress(Steering.abort(state))}
  end

  def handle_call({:prompt, _text}, _from, %State{activity: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  # A steer on a `submitted` turn, also with a context request open, goes
  # to the provider process; in `preparing` and `submitting` it stays in the
  # local queue (see "Turn states" in `docs/features/long-lived-harness.md`).
  # A sent steer counts in the 32 steers until its `user_message` and its
  # answer (see `Helyx.Session.Queue`).
  def handle_call({:steer, text}, _from, %State{activity: %Turn{phase: phase}} = state)
      when phase in [:submitted, :context] do
    if Queue.room?(state.queue),
      do: {:reply, :ok, Steering.send_steer(text, state)},
      else: {:reply, {:error, :queue_full}, state}
  end

  def handle_call({:steer, text}, _from, %State{activity: %Turn{}} = state),
    do: queue_reply(state, :steers, text)

  def handle_call({:follow_up, text}, _from, %State{activity: %Turn{}} = state),
    do: queue_reply(state, :follow_ups, text)

  def handle_call({op, text}, _from, %State{activity: :idle} = state)
      when op in [:prompt, :steer, :follow_up],
      do: {:reply, :ok, begin_turn(state, [text])}

  def handle_call(:snapshot, _from, %State{} = state) do
    snapshot = %Snapshot{
      instance_id: state.instance_id,
      seq: state.seq,
      messages: state.transcript,
      turn:
        if(match?(%Turn{}, state.activity),
          do: Turn.snapshot(state.activity, Transcript.open_calls(state.transcript))
        ),
      model: ModelRef.to_string(state.model),
      queue: Queue.counts(state.queue)
    }

    {:reply, snapshot, state}
  end

  # The entry and the snapshot in one message, so every later event reaches
  # the caller. A repeated subscribe keeps the entry and its monitor.
  def handle_call({:subscribe, pid}, from, %State{} = state) do
    handle_call(:snapshot, from, Record.subscribe(state, pid))
  end

  def handle_call({:set_model, %ModelRef{} = ref, provider}, _from, %State{} = state) do
    model = ModelRef.to_string(ref)
    state = Record.persist(state, &Helyx.Session.File.append_model_change(&1, model))
    state = %{state | model: ref, provider: provider}
    {:reply, :ok, settle(emit(state, nil, :model_change, %{model: model}))}
  end

  # A steer of an ended turn can still wait for its answer: the abort gives
  # its notice now, so a late `:rejected` queues nothing.
  def handle_call(:abort, _from, %State{activity: :idle} = state),
    do: {:reply, :ok, Steering.abort(state)}

  # The release of the hands can take longer than the timeout of a client call
  # (issue #93), so the session does not wait in a call: the answer of the
  # hands arrives as a message, and the abort callers get their reply then.
  def handle_call(:abort, from, %State{activity: %Turn{}} = state),
    do: {:noreply, abort_turn(state, [from])}

  @impl true
  def handle_info(
        {:stream_event, turn_id, {:message_end, stop_reason, usage}},
        %State{activity: %Turn{id: turn_id}} = state
      ) do
    {state, _assistant, calls} = Messages.close_assistant(state, stop_reason, usage)
    state = Enum.reduce(calls, state, &emit(&2, :tool_execution_start, %{tool_call: &1}))
    {:noreply, put_in(state.activity.partial, nil)}
  end

  # A result goes to the first open call with its id
  # (`Transcript.open_calls/1`), so the transcript, the file, and the
  # replay agree. A result for no open call is dropped.
  def handle_info(
        {:stream_event, turn_id, {:tool_result, call_id, result}},
        %State{activity: %Turn{id: turn_id}} = state
      ) do
    case Enum.find(Transcript.open_calls(state.transcript), &(&1.id == call_id)) do
      nil -> {:noreply, state}
      call -> {:noreply, Messages.record_result(call, result, state)}
    end
  end

  # The provider took a steer of this turn: its text, the one the session
  # checked at the client call, joins the transcript here (see
  # `Queue.take/2`).
  def handle_info(
        {:stream_event, turn_id, {:user_message, steer_id}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, Steering.take(state, steer_id)}

  # A Helyx tool request of the provider process `pid`, and its withdrawal
  # (`Tools`). The call and its result join the transcript from the
  # program's own events, not from here. A request of a turn that is not
  # current gets `aborted`.
  def handle_info(
        {:tool_request, _pid, turn_id, call, rejection},
        %State{activity: %Turn{id: turn_id}} = state
      ) do
    case Tools.request(state, call, rejection) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason} -> {:noreply, stop_provider(state, reason)}
    end
  end

  def handle_info({:tool_request, pid, turn_id, call, _rejection}, state),
    do: {:noreply, Tools.late(state, pid, turn_id, call.id)}

  def handle_info({:cancel_tool, turn_id, call_id}, %State{activity: %Turn{id: turn_id}} = state),
    do: {:noreply, Tools.cancel(state, call_id)}

  def handle_info(
        {:stream_event, turn_id, {:resume, id, cut}},
        %State{activity: %Turn{id: turn_id} = turn} = state
      ) do
    # The provider id is the prefix of the turn's model ref: `find/2`
    # matched it, so the session runs no plugin code for it.
    provider = turn.model.provider
    state = Record.persist(state, &Helyx.Session.File.append_resume_id(&1, provider, id))
    ids = Map.put(state.resume_ids, provider, {id, length(state.transcript)})
    state = %{state | resume_ids: ids}
    data = %{provider: provider, resume_id: id, lost: turn.resumed != nil, cut: cut}
    {:noreply, emit(state, :provider_session, data)}
  end

  # A notice of the provider is an event only: it joins no message, so the
  # transcript that the model gets again never holds it.
  def handle_info(
        {:stream_event, turn_id, {:notice, text}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, emit(state, :notice, %{text: text})}

  # A turn that the provider started by itself (#240) opens only with no
  # turn and no wait: a submitted turn with no user message. Any other
  # time it is dropped with its events; its tool requests get `aborted`.
  def handle_info(
        {:stream_event, turn_id, :turn_start},
        %State{activity: :idle, conn: %ProviderConn{ready: true, model: model}} = state
      ) do
    turn = %Turn{id: turn_id, model: model, provider: state.provider, phase: :submitted}
    {:noreply, open_turn(state, turn, %{origin: :provider})}
  end

  def handle_info({:stream_event, _id, :turn_start}, state), do: {:noreply, state}

  def handle_info({:stream_event, turn_id, event}, %State{activity: %Turn{id: turn_id}} = state) do
    %State{activity: turn} = state = Messages.start_assistant_message(state)

    {:noreply,
     %{state | activity: Turn.add_block(turn, event)}
     |> emit(:message_update, Map.new([event]))}
  end

  # The terminal of the turn, from the provider process.
  def handle_info({:stream_end, turn_id, terminal}, %State{activity: %Turn{id: turn_id}} = state) do
    {:noreply, end_turn(terminal, state)}
  end

  # The hands' result of the running Helyx tool.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{activity: %Turn{id: turn_id, tool: call_id}} = state
      ),
      do: {:noreply, Tools.result(state, result)}

  # The messages of a turn (see "Turn states" in
  # `docs/features/long-lived-harness.md`). The turn is `preparing` until
  # the session sends `{:turn, ...}`, which needs a ready provider process
  # and the prepared context; `submitting` until the answer; then
  # `submitted`.
  def handle_info({:provider_ready, pid}, %State{conn: %ProviderConn{pid: pid} = conn} = state) do
    {:noreply, State.arm_idle(submit(%{state | conn: %{conn | ready: true}}))}
  end

  # The prepare Task checked the context (`Stream.prepare/4`): a plugin
  # that returned anything else fails the turn.
  def handle_info(
        {:prepared, turn_id, result},
        %State{activity: %Turn{id: turn_id, phase: :preparing} = turn} = state
      ) do
    case result do
      {:ok, context} -> {:noreply, submit(%{state | activity: %{turn | context: context}})}
      {:error, reason} -> {:noreply, fail_turn(reason, state)}
    end
  end

  def handle_info({:prepare_failed, turn_id, reason}, state),
    do: handle_info({:prepared, turn_id, {:error, {:task_exit, reason}}}, state)

  # A context request (C1-C4, `one-provider-path.md`), after the events
  # before it: only for the submitted turn with no context request open;
  # for the current turn at any other time it is a bad action. The context
  # is answered as a tool result is. A request or a context of a turn that
  # ended is dropped.
  def handle_info(
        {:need_context, turn_id},
        %State{activity: %Turn{id: turn_id, phase: :submitted}} = state
      ),
      do: {:noreply, prepare(put_in(state.activity.phase, :context))}

  def handle_info(
        {:need_context, turn_id} = action,
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, stop_provider(state, {:bad_action, action})}

  def handle_info(
        {:prepared, turn_id, result},
        %State{activity: %Turn{id: turn_id, phase: :context} = turn, conn: conn} = state
      ) do
    ask(state, conn.pid, {:context, turn_id, result}, :context)
    {:noreply, %{state | activity: %{turn | phase: :submitted}}}
  end

  # An answer other than `:ok` ends the provider process, and its
  # `:provider_down` fails the turn.
  def handle_info(
        {:provider_reply, from, :turn, reply},
        %State{activity: %Turn{pending: from} = turn} = state
      ) do
    phase = if reply == :ok, do: :submitted, else: :submitting
    state = %{state | activity: %{turn | pending: nil, phase: phase}}
    {:noreply, if(reply == :ok, do: Steering.send_local_steers(state), else: state)}
  end

  # The answer to a steer, also after its turn (see "Steer" in
  # `docs/features/long-lived-harness.md` and `Queue.answer/3`). A late
  # `:rejected` queues the steer, and an idle session starts it.
  def handle_info({:provider_reply, from, :steer, reply}, %State{} = state),
    do: {:noreply, progress(Steering.answer(state, from, reply))}

  # The answer to the interrupt or the idle close of the wait. The loop
  # ends itself after an answer that stops it (`ProviderRequest.stop_after/2`),
  # and the wait then lasts until its `:provider_down`.
  def handle_info(
        {:provider_reply, from, kind, reply},
        %State{activity: %Wait{reply: from} = wait} = state
      ) do
    provider = if ProviderRequest.stop_after(kind, reply), do: wait.provider
    {:noreply, progress(%{state | activity: %{wait | reply: nil, provider: provider}})}
  end

  # The idle timer of the provider process. Only the current timer counts,
  # and only while the session is idle: a turn or a wait since it was armed
  # makes it old. The wait holds every message until the answer.
  def handle_info(
        {:timeout, ref, :idle_close},
        %State{idle: ref, activity: :idle, conn: %ProviderConn{pid: pid, ready: true}} = state
      ) do
    from = ask(state, pid, :idle_close, :close)
    {:noreply, %{state | idle: nil, activity: %Wait{reply: from, provider: pid}}}
  end

  def handle_info({:timeout, _ref, :idle_close}, state), do: {:noreply, state}

  # From the hands, after the release of the provider process's handles: the
  # end of the provider process that the wait is for, or of the current one.
  # In a turn it fails the turn, whose cleanup the hands then run after the
  # release. Only a process of an earlier turn that ends while this turn
  # prepares got nothing of it: the turn connects a new one, once.
  def handle_info({:provider_down, pid, _reason}, %State{activity: %Wait{provider: pid}} = state),
    do: {:noreply, wait_provider_down(state, pid)}

  def handle_info(
        {:provider_down, pid, _reason},
        %State{conn: %ProviderConn{pid: pid}, activity: %Wait{}} = state
      ),
      do: {:noreply, wait_provider_down(state, pid)}

  def handle_info(
        {:provider_down, pid, reason},
        %State{conn: %ProviderConn{pid: pid} = conn, activity: %Turn{} = turn} = state
      ) do
    if turn.phase == :preparing and conn.turn != turn.id,
      do: {:noreply, call_provider(Steering.provider_down(%{state | conn: nil}))},
      else: {:noreply, fail_turn(reason, %{state | conn: nil})}
  end

  # Idle, when it comes before the session's `:DOWN` (no order between them).
  def handle_info({:provider_down, pid, _reason}, %State{conn: %ProviderConn{pid: pid}} = state),
    do: {:noreply, Steering.provider_down(%{state | conn: nil})}

  # The session's monitor: a provider process that ends outside a turn is
  # dropped at once, and the next turn waits for its `:provider_down`.
  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %State{conn: %ProviderConn{pid: pid}, activity: activity} = state
      )
      when not is_struct(activity, Turn) do
    wait = if activity == :idle, do: %Wait{}, else: activity
    {:noreply, %{state | conn: nil, activity: %{wait | provider: pid}}}
  end

  # A message for a turn, a call, or a provider process that is no longer
  # current, or a reply that nobody waits for.
  def handle_info({:provider_ready, _pid}, state), do: {:noreply, state}
  def handle_info({:provider_reply, _from, _kind, _reply}, state), do: {:noreply, state}
  def handle_info({:prepared, _turn_id, _result}, state), do: {:noreply, state}
  def handle_info({:need_context, _turn_id}, state), do: {:noreply, state}
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:cancel_tool, _turn_id, _call_id}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}
  def handle_info({:stream_end, _turn_id, _terminal}, state), do: {:noreply, state}

  # The failed subscribe of `Helyx.Session.subscribe/1`, and the end of a
  # subscriber: only the monitor of its entry removes the entry.
  def handle_info({:unsubscribe, pid}, %State{} = state) do
    {:noreply, Record.unsubscribe(state, pid)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{subscribers: subscribers} = state)
      when :erlang.map_get(pid, subscribers) == ref,
      do: {:noreply, Record.subscriber_down(state, pid)}

  # In a preparing turn the `:DOWN` holds back `{:turn, ...}` until then.
  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %State{conn: %ProviderConn{pid: pid}, activity: %Turn{phase: :preparing}} = state
      ),
      do: {:noreply, put_in(state.conn.ready, false)}

  # The `:DOWN` of a provider process that the session dropped already, of
  # the current one in a sent turn (its `:provider_down` fails it), or of
  # the hands' cleanup request (their `:EXIT` stops the session).
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # The hands are linked and vital: their death takes the session with it.
  def handle_info({:EXIT, pid, reason}, %State{hands: pid} = state), do: {:stop, reason, state}

  # An exit from any other linked process, the sessions Registry for
  # example, is vital: a session that outlived its registration would keep working
  # where no client can reach it.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # The answer of the hands to the cleanup request. If the hands die, the
  # `:DOWN` clause above takes the request's `:DOWN` and their `:EXIT` stops
  # the session. Any other message is a bug and crashes the session.
  def handle_info(message, %State{activity: %Wait{hands: request} = wait} = state)
      when request != nil do
    {:reply, result} = :gen_server.check_response(message, request)
    {:noreply, progress(%{cleanup_notice(result, state) | activity: %{wait | hands: nil}})}
  end

  # The abort still replies `:ok` (ADR 0006 §5); a failed cleanup is a
  # notice. Its text is fixed, so it stays in the bound of a notice; the
  # log has the reason, whose handle list has no bound. The turn has
  # ended, so the notice has no turn id.
  defp cleanup_notice(:ok, state), do: state

  defp cleanup_notice({:error, reason}, state) do
    Logger.warning("abort cleanup failed: " <> reason)
    text = "abort cleanup failed: a process or resource of the turn may still be held"
    emit(state, nil, :notice, %{text: text})
  end

  # The session stops only for a trapped reason; on an untrappable kill the
  # link kills the hands, which take the provider process and the tool Tasks.
  #
  # The hands end before the session (#219). Core stops its session
  # supervisor before its task supervisor, and the release Tasks of the
  # hands run under the task supervisor. So a release that the hands start
  # after the session ended could find the task supervisor stopped.
  @impl true
  def terminate(_reason, state) do
    Stop.run(state)
  end

  # Turn machinery

  # Ends the turn at once, drops the queues, and asks the hands to release
  # its resources; the `callers` get their reply when the wait ends. A
  # turn that sent `{:turn, ...}` also gets an interrupt, after the
  # `aborted` answers of its open tool requests.
  defp abort_turn(%State{activity: turn} = state, callers) do
    request = Hands.request_cancel(state.hands, turn.id)

    state =
      state
      |> Steering.end_turn(turn.id, false)
      |> Messages.abort_open_calls()
      |> Messages.close_partial_message(:aborted, :aborted)
      |> Steering.drop_queues()
      |> Tools.end_turn(turn)
      |> emit(:agent_end, %{stop_reason: :aborted})

    %{state | activity: %{interrupt(state, turn) | hands: request, callers: callers}}
  end

  # Only a turn that sent `{:turn, ...}` gets an interrupt. The wait holds
  # its answer, and the provider process until that answer keeps it.
  defp interrupt(%State{conn: %ProviderConn{pid: pid}} = state, %Turn{phase: phase, id: id})
       when phase in [:submitting, :submitted, :context],
       do: %Wait{reply: ask(state, pid, {:interrupt, id}, :interrupt), provider: pid}

  defp interrupt(_state, _turn), do: %Wait{}

  # At the end of the wait the abort callers get their reply. An idle
  # session settles too: a late `:rejected` can queue a steer.
  defp progress(%State{activity: %Wait{hands: nil, reply: nil, provider: nil} = wait} = state) do
    Enum.each(wait.callers, &GenServer.reply(&1, :ok))
    settle(%{state | activity: :idle})
  end

  defp progress(%State{activity: :idle} = state), do: settle(state)
  defp progress(state), do: state

  # A provider process ended in the wait, after its release: no request to
  # it is open any more. When the wait was for it, its reply ends too.
  defp wait_provider_down(%State{activity: wait} = state, pid) do
    conn = if provider_pid(state) == pid, do: nil, else: state.conn
    wait = if wait.provider == pid, do: %{wait | provider: nil, reply: nil}, else: wait
    progress(Steering.provider_down(%{state | conn: conn, activity: wait}))
  end

  # With no turn and no wait, a provider process of another model than the
  # session's closes before the next turn starts (a provider or a model
  # switch); otherwise the queues start the next turn.
  defp settle(%State{activity: :idle} = state) do
    with %State{activity: :idle} = state <- State.close_switched(state) do
      State.arm_idle(start_queued(state))
    end
  end

  defp settle(state), do: state

  # Starts a turn with one user message per text, in order.
  defp begin_turn(%State{} = state, texts) do
    turn = %Turn{id: Id.new(), model: state.model, provider: state.provider}
    state = open_turn(state, turn, %{})
    call_provider(Enum.reduce(texts, state, &Messages.append_user(&2, &1)))
  end

  defp open_turn(state, turn, data),
    do: %{state | activity: turn} |> emit(:agent_start, %{}) |> emit(:turn_start, data)

  defp queue_reply(state, key, text) do
    case Steering.queue(state, key, text) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, :queue_full} = error -> {:reply, error, state}
    end
  end

  # A normal turn end starts a new turn with everything still queued, steers
  # first. The drain event goes out between the turns, with a nil turn id.
  defp start_queued(%State{} = state) do
    case Steering.drain(state) do
      {[], state} -> state
      {texts, state} -> begin_turn(state, texts)
    end
  end

  # The provider process (started at the first turn) and a prepare Task of
  # the hands, which builds the context; a turn that connects again keeps
  # its prepare.
  defp call_provider(%State{activity: %Turn{phase: phase}} = state) do
    case State.connect(state) do
      {:ok, state} -> if phase, do: state, else: prepare(put_in(state.activity.phase, :preparing))
      {:error, text} -> fail_turn(text, state)
    end
  end

  # The prepare Task of the hands builds the context, under `prepare_ms`.
  defp prepare(%State{activity: %Turn{id: turn_id}} = state) do
    session = self()
    %State{model_context: model_context, compaction: compaction} = state
    context = %Context{messages: state.transcript, tools: state.tools}
    opts = [turn_id: turn_id] ++ State.base_opts(state)

    :ok =
      Hands.prepare(state.hands, turn_id, fn tref ->
        result = Helyx.Session.Stream.prepare(model_context, compaction, context, opts)
        :timer.cancel(tref)
        send(session, {:prepared, turn_id, result})
      end)

    state
  end

  # Sends `{:turn, ...}` when the provider process is ready and the context
  # is prepared. The steers queued in `preparing` join the transcript and
  # the end of the context: they are part of the prompt, not steers.
  defp submit(
         %State{
           activity: %Turn{phase: :preparing, context: context},
           conn: %ProviderConn{pid: pid, ready: true}
         } = state
       )
       when context != nil do
    {steers, %State{activity: turn} = state} = Steering.append_steers(state)
    context = %{context | messages: context.messages ++ Enum.map(steers, &Message.user/1)}
    from = ask(state, pid, {:turn, turn.id, context}, :turn)
    %{state | activity: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  defp submit(state), do: state

  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    {%State{activity: turn} = state, assistant, _calls} =
      Messages.close_assistant(state, stop_reason, usage)

    # A call in the last message gets no result. A steer with no answer yet
    # can still be rejected after the turn (`Queue.answer/3`).
    state =
      state
      |> Messages.abort_open_calls()
      |> Steering.end_turn(turn.id, true)
      |> Tools.end_turn(turn)
      |> emit(:turn_end, %{message: assistant})
      |> emit(:agent_end, %{stop_reason: stop_reason})

    # A Helyx tool that still runs: the turn cleanup of the hands runs
    # before the next turn.
    hands = if turn.tool, do: Hands.request_cancel(state.hands, turn.id)
    progress(%{state | activity: %Wait{hands: hands}})
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # A provider output outside the contract: the turn fails, and the
  # provider process stops with `{:shutdown, reason}`; the hands release it
  # and the wait lasts until its `:provider_down`.
  defp stop_provider(%State{conn: %ProviderConn{pid: pid}} = state, reason) do
    Process.exit(pid, {:shutdown, reason})
    state = fail_turn(reason, %{state | conn: nil})
    put_in(state.activity.provider, pid)
  end

  # A partial assistant message is closed with a failure stop reason so
  # clients do not keep it open. It is not added to the transcript.
  # A turn can fail after a message whose calls have no result yet. A failed
  # turn runs the turn cleanup of the hands before the next turn: its
  # prepare Task can still run.
  defp fail_turn(reason, %State{activity: turn} = state) do
    state =
      state
      |> Steering.end_turn(turn.id, false)
      |> Messages.abort_open_calls()
      |> Messages.close_partial_message(:error, reason)
      |> Steering.drop_queues()
      |> Tools.end_turn(turn)
      |> emit(:agent_end, %{stop_reason: :error, error: reason})

    %{state | activity: %Wait{hands: Hands.request_cancel(state.hands, turn.id)}}
  end

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
