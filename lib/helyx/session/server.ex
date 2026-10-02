defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks and the turn loop. The
  # client API and the docs of the behaviour are in `Helyx.Session`.

  require Logger

  alias Helyx.{Context, Message, ModelRef}
  alias Helyx.Session.{Hands, Id, ProviderProcess, Queues, Snapshot, Steers}
  alias Helyx.Session.Server.{Messages, ProviderConn, Record, State}
  alias Helyx.Session.{Transcript, Turn, Wait}

  import State, only: [ask: 4, drop_turn: 2, provider_pid: 1]
  import Record, only: [emit: 3, emit: 4]

  # The stop of a session (`terminate/2`): the close of an idle provider
  # process (`State.provider_close_ms/0`, armed kill), then the stop of the
  # hands, which can finish one release (`Hands.State.release_ms/0`). Each
  # wait has a margin for load, so the supervisor does not kill it first.
  @load_hands_stop_ms 2_000
  @load_shutdown_ms 3_000
  @hands_stop_ms Hands.State.release_ms() + @load_hands_stop_ms
  use GenServer,
    restart: :temporary,
    shutdown: State.provider_close_ms() + @hands_stop_ms + @load_shutdown_ms

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
    {wait, effects} = Wait.abort(wait, from)
    state = drop_queues(state)
    {:noreply, progress(steer_effects(%{state | activity: wait}, effects))}
  end

  def handle_call({:prompt, _text}, _from, %State{activity: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  # A steer on a `submitted` turn goes to the provider process; in
  # `preparing` and `submitting` it stays in the local queue (see "Turn
  # states" in `docs/features/long-lived-harness.md`). A sent steer counts
  # in the 32 steers until its `user_message` and its answer (see `held/1`).
  def handle_call(
        {:steer, text},
        _from,
        %State{activity: %Turn{phase: :submitted}} = state
      ) do
    if Queues.steer_room?(state.queues, held(state)),
      do: {:reply, :ok, send_steer(text, state)},
      else: {:reply, {:error, :queue_full}, state}
  end

  def handle_call({:steer, text}, _from, %State{activity: %Turn{}} = state),
    do: queue_reply(state, :steers, text)

  def handle_call({:follow_up, text}, _from, %State{activity: %Turn{}} = state),
    do: queue_reply(state, :follow_ups, text)

  # A provider process that ended while the session was idle can still have
  # its handles in a release of the hands: the message waits for its
  # `:provider_down` as a follow-up.
  def handle_call({op, text}, _from, %State{} = state)
      when op in [:prompt, :steer, :follow_up] do
    case await_ended_provider(state) do
      %State{activity: :idle} = state -> {:reply, :ok, begin_turn(state, [text])}
      state -> queue_reply(state, :follow_ups, text)
    end
  end

  def handle_call(:snapshot, _from, %State{} = state) do
    snapshot = %Snapshot{
      instance_id: state.instance_id,
      seq: state.seq,
      messages: state.transcript,
      turn: if(match?(%Turn{}, state.activity), do: Turn.snapshot(state.activity)),
      model: ModelRef.to_string(state.model),
      queue: Queues.counts(state.queues)
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

  def handle_call(:abort, _from, %State{activity: :idle} = state), do: {:reply, :ok, state}

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
    %State{activity: turn} = state
    {:noreply, %{state | activity: %{turn | partial: nil, calls: calls}}}
  end

  # A result for a call of no completed message, or for a call that a
  # later message already closed, is dropped. A result goes
  # to the first open call with its id, the rule of `open_calls/1`, so the
  # transcript, the file, and the replay agree.
  def handle_info(
        {:stream_event, turn_id, {:tool_result, call_id, result}},
        %State{activity: %Turn{id: turn_id} = turn} = state
      ) do
    case Enum.find(turn.calls, &(&1.id == call_id)) do
      nil ->
        {:noreply, state}

      call ->
        state = %{state | activity: %{turn | calls: List.delete(turn.calls, call)}}
        {:noreply, Messages.record_result(call, result, state)}
    end
  end

  # The provider took a steer of this turn: its text, the one the session
  # checked at the client call, joins the transcript here (see
  # `Steers.take/2`).
  def handle_info(
        {:stream_event, turn_id, {:user_message, steer_id, _text}},
        %State{activity: %Turn{id: turn_id} = turn} = state
      ) do
    {steers, effects} = Steers.take(turn.steers, steer_id)
    {:noreply, steer_effects(put_in(state.activity.steers, steers), effects)}
  end

  # The provider asks for a Helyx tool (see "Helyx tool calls" in
  # `docs/features/long-lived-harness.md`). The loop owns the waiting
  # queue and sends a request only when the result of the one before came,
  # so `tool` holds only the running call. The call
  # and its result join the transcript from the program's own events, not
  # from here.
  def handle_info(
        {:stream_event, turn_id, {:tool_request, id, name, args}},
        %State{
          activity: %Turn{id: turn_id} = turn,
          conn: %ProviderConn{pid: pid}
        } = state
      ) do
    call = %Message.ToolCall{id: id, name: name, arguments: args}
    from = ask(state, pid, {:tool_start, turn_id, id}, :tool_start)
    {:noreply, %{state | activity: %{turn | tool: call, start: from}}}
  end

  # The loop's answer to the ask: only `:ok` runs the call. A missed
  # deadline stops the provider process, and its `:provider_down` fails the
  # turn; an answer after the turn goes to the wait after the turn.
  def handle_info(
        {:provider_reply, from, :tool_start, reply},
        %State{activity: %Turn{start: from, tool: call} = turn} = state
      ) do
    state = %{state | activity: %{turn | start: nil}}

    {:noreply,
     if(reply == :ok, do: run_on_hands(call, state), else: put_in(state.activity.tool, nil))}
  end

  # The provider withdrew a tool request: a running one is killed, and its
  # result, which the hands still send, is dropped by the loop.
  def handle_info(
        {:cancel_tool, turn_id, call_id},
        %State{activity: %Turn{id: turn_id, tool: %{id: call_id}}} = state
      ) do
    Hands.kill(state.hands, turn_id, call_id)
    {:noreply, state}
  end

  def handle_info(
        {:stream_event, turn_id, {:resume, id, cut}},
        %State{activity: %Turn{id: turn_id} = turn} = state
      ) do
    # The provider id is the prefix of the turn's model ref: `find/2`
    # matched it, so the session runs no plugin code for it.
    provider = turn.model.provider
    state = Record.persist(state, &Helyx.Session.File.append_harness_session(&1, provider, id))
    sessions = Map.put(state.resume_ids, provider, {id, length(state.transcript)})
    state = %{state | resume_ids: sessions}
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

  # A turn that the program started by itself (#240) opens only with no
  # turn and no wait: a submitted turn with no user message. Any other
  # time it is dropped with its events, also in the loop (#339).
  def handle_info(
        {:stream_event, turn_id, :turn_start},
        %State{activity: :idle, conn: %ProviderConn{ready: true, model: model}} = state
      ) do
    turn = %Turn{id: turn_id, model: model, provider: state.provider, phase: :submitted}
    {:noreply, open_turn(state, turn, %{origin: :program})}
  end

  def handle_info({:stream_event, id, :turn_start}, state), do: {:noreply, drop_turn(state, id)}

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

  # The result of a Helyx tool goes to the provider
  # process, with the tool result bound. Its answer is awaited, as a steer's
  # is, so no turn starts while its kill is armed.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{
          activity: %Turn{id: turn_id, tool: %{id: call_id}} = turn,
          conn: %ProviderConn{pid: pid}
        } = state
      ) do
    from = ask(state, pid, {:tool_result, turn_id, call_id, result}, :tool_result)

    {:noreply, %{state | activity: %{turn | tool: nil, results: [from | turn.results]}}}
  end

  # The messages of a turn (see "Turn states" in
  # `docs/features/long-lived-harness.md`). The turn is `preparing` until
  # the session sends `{:turn, ...}`, which needs a ready provider process
  # and the prepared context; `submitting` until the answer; then
  # `submitted`.
  def handle_info({:provider_ready, pid}, %State{conn: %ProviderConn{pid: pid} = conn} = state) do
    {:noreply, arm_idle(submit(%{state | conn: %{conn | ready: true}}))}
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

  # A context request (C1-C4, `one-provider-path.md`), only for the live
  # turn, after its events; the context is answered as a tool result is.
  def handle_info({:need_context, turn_id}, %State{activity: %Turn{id: turn_id}} = state),
    do: {:noreply, prepare(state)}

  def handle_info(
        {:prepared, turn_id, result},
        %State{activity: %Turn{id: turn_id} = turn, conn: %ProviderConn{pid: pid}} = state
      ) do
    from = ask(state, pid, {:context, turn_id, result}, :context)
    {:noreply, put_in(state.activity.results, [from | turn.results])}
  end

  # An answer other than `:ok` ends the provider process, and its
  # `:provider_down` fails the turn.
  def handle_info(
        {:provider_reply, from, :turn, reply},
        %State{activity: %Turn{pending: from} = turn} = state
      ) do
    phase = if reply == :ok, do: :submitted, else: :submitting
    state = %{state | activity: %{turn | pending: nil, phase: phase}}
    {:noreply, if(reply == :ok, do: send_local_steers(state), else: state)}
  end

  # The answer to a steer of the turn (see "Steer" in
  # `docs/features/long-lived-harness.md` and `Steers.answer/3`).
  def handle_info(
        {:provider_reply, from, :steer, reply},
        %State{activity: %Turn{} = turn} = state
      ) do
    {steers, effects} = Steers.answer(turn.steers, from, reply)
    {:noreply, steer_effects(put_in(state.activity.steers, steers), effects)}
  end

  # The answer to a tool result or a context of the turn: it was written.
  def handle_info(
        {:provider_reply, from, kind, _reply},
        %State{activity: %Turn{} = turn} = state
      )
      when kind in [:tool_result, :context] do
    {:noreply, put_in(state.activity.results, List.delete(turn.results, from))}
  end

  # A reply in the wait acts only on the part whose stored ref it matches
  # (see `Wait.answer/4`).
  def handle_info({:provider_reply, from, kind, reply}, %State{activity: %Wait{} = wait} = state) do
    {wait, effects} = Wait.answer(wait, kind, from, reply)
    {:noreply, progress(steer_effects(%{state | activity: wait}, effects))}
  end

  # The idle timer of the provider process. Only the current timer counts,
  # and only while the session is idle: a turn or a wait since it was armed
  # makes it old. The wait holds every message until the answer.
  def handle_info(
        {:timeout, ref, :idle_close},
        %State{idle: ref, activity: :idle, conn: %ProviderConn{pid: pid, ready: true}} = state
      ) do
    from = ask(state, pid, :idle_close, :close)
    {:noreply, %{state | idle: nil, activity: %Wait{idle: from, provider: pid}}}
  end

  def handle_info({:timeout, _ref, :idle_close}, state), do: {:noreply, state}

  # From the hands, after the release of the provider process's handles: the
  # end of the provider process that the wait is for, or of the one that
  # holds the requests of the turn that ended (see `Wait.provider_down/2`).
  def handle_info({:provider_down, pid, _reason}, %State{activity: %Wait{provider: pid}} = state),
    do: {:noreply, wait_provider_down(state, pid)}

  def handle_info(
        {:provider_down, pid, _reason},
        %State{conn: %ProviderConn{pid: pid}, activity: %Wait{}} = state
      ),
      do: {:noreply, wait_provider_down(state, pid)}

  def handle_info(
        {:provider_down, pid, reason},
        %State{conn: %ProviderConn{pid: pid}, activity: %Turn{}} = state
      ) do
    {:noreply, fail_turn(reason, %{state | conn: nil})}
  end

  def handle_info({:provider_down, pid, _reason}, %State{conn: %ProviderConn{pid: pid}} = state) do
    {:noreply, %{state | conn: nil}}
  end

  # A message for a turn, a call, or a provider process that is no longer
  # current, or a reply that nobody waits for.
  def handle_info({:provider_ready, _pid}, state), do: {:noreply, state}
  def handle_info({:provider_reply, _from, _kind, _reply}, state), do: {:noreply, state}
  def handle_info({:provider_down, _pid, _reason}, state), do: {:noreply, state}
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

  # The hands are linked and vital: their death takes the session with it.
  def handle_info({:EXIT, pid, reason}, %State{hands: pid} = state), do: {:stop, reason, state}

  # An exit from any other linked process, the sessions Registry for
  # example, is vital: a session that outlived its registration would keep working
  # where no client can reach it.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  # The answer of the hands to the cancel request of an abort. The hands are
  # vital, so a request that fails because they died stops the session, like
  # their exit signal. Every other message has a clause above, so any other
  # message is a bug and crashes the session.
  def handle_info(message, %State{activity: %Wait{hands: request} = wait} = state)
      when request != nil do
    case :gen_server.check_response(message, request) do
      {:reply, result} ->
        state = cleanup_notice(result, state)
        {:noreply, progress(%{state | activity: %{wait | hands: nil}})}

      {:error, {reason, _hands}} ->
        {:stop, reason, state}
    end
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
    end_work(state)
    stop_hands(state.hands)
  end

  defp end_work(%State{activity: %Turn{}}), do: :ok

  # A session that ends with no turn closes its provider processes: the
  # current one and the one its wait is for (an idle close, a switch
  # close, an abort). Each gets a close, end of input then the exit, after
  # any request it has open: a `:busy` answer to an idle close does not
  # keep it. The armed close kills bound the waits, which run in parallel,
  # and a provider process that is already gone gives its `:DOWN` at once.
  defp end_work(%State{activity: activity} = state) do
    pids = [provider_pid(state), wait_pid(activity)]

    refs =
      for pid <- Enum.uniq(pids), is_pid(pid) do
        ref = Process.monitor(pid)
        ask(state, pid, :close, :close)
        ref
      end

    for ref <- refs do
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end
  end

  defp wait_pid(%Wait{provider: pid}), do: pid
  defp wait_pid(:idle), do: nil

  # The hands take the messages before the exit signal first: the end of a
  # closed provider process gets its release. That end reaches the hands
  # before the provider process's `:DOWN` reaches the session, on one node.
  # If it came later, the hands would end with no release, and the port
  # would close with the provider process. Each release has its deadline,
  # so the wait is bounded; over @hands_stop_ms the hands are killed, and a
  # killed process runs no release. Hands that are already gone give their
  # `:DOWN` at once.
  defp stop_hands(hands) do
    ref = Process.monitor(hands)
    Process.exit(hands, :shutdown)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @hands_stop_ms ->
        Process.exit(hands, :kill)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        end
    end
  end

  # Turn machinery

  # Ends the turn at once, drops the queues, and asks the hands to release
  # its resources; the `callers` get their reply when the wait ends. A
  # turn that sent `{:turn, ...}` also gets an interrupt, after the hands
  # answer.
  defp abort_turn(%State{activity: turn} = state, callers) do
    request = Hands.request_cancel(state.hands, turn.id)
    {wait, effects} = Wait.after_turn(turn, provider_pid(state), false)

    state =
      state
      |> steer_effects(effects)
      |> Messages.abort_open_calls()
      |> Messages.close_partial_message(:aborted, :aborted)
      |> drop_queues()
      |> emit(:agent_end, %{stop_reason: :aborted})

    wait = %{wait | hands: request, callers: callers, interrupt: Wait.interrupt(turn, state.conn)}
    %{state | activity: wait}
  end

  # Runs the wait (see `Wait.next/2`): sends the requests it names, and at
  # its end replies to the abort callers and settles.
  defp progress(%State{activity: %Wait{} = wait} = state) do
    case Wait.next(wait, provider_pid(state)) do
      {:send, wait, pid, request} ->
        from = ask(state, pid, request, elem(request, 0))
        progress(%{state | activity: Wait.sent(wait, request, from)})

      {:done, callers} ->
        Enum.each(callers, &GenServer.reply(&1, :ok))
        settle(%{state | activity: :idle})

      :open ->
        state
    end
  end

  # A provider process ended in the wait: see `Wait.provider_down/2`.
  defp wait_provider_down(%State{activity: wait} = state, pid) do
    conn = if provider_pid(state) == pid, do: nil, else: state.conn
    {wait, effects} = Wait.provider_down(wait, pid)
    progress(steer_effects(%{state | conn: conn, activity: wait}, effects))
  end

  # With no turn and no wait, a provider process that ended is waited for
  # (its `:provider_down`), and one of another model than the session's
  # closes before the next turn starts (a provider or a model switch);
  # otherwise the queues start the next turn.
  defp settle(%State{activity: :idle} = state) do
    case await_ended_provider(state) do
      %State{activity: :idle} = state -> arm_idle(close_or_start(state))
      state -> state
    end
  end

  defp settle(state), do: state

  # Arms the idle timer when the session holds a ready provider process
  # with no turn and no wait. It cancels the earlier timer; a message of
  # it that is already in the mailbox has an old ref.
  defp arm_idle(%State{activity: :idle, conn: %ProviderConn{ready: true}} = state) do
    if state.idle, do: :erlang.cancel_timer(state.idle)
    %{state | idle: :erlang.start_timer(state.provider_ms.idle, self(), :idle_close)}
  end

  defp arm_idle(state), do: state

  defp close_or_start(%State{model: model, conn: %ProviderConn{pid: pid, model: other}} = state)
       when other != model do
    ask(state, pid, :close, :close)
    %{state | conn: nil, activity: %Wait{provider: pid}}
  end

  defp close_or_start(state), do: start_queued(state)

  # The hands send `:provider_down` only after the release of the provider
  # process's handles, so a turn does not start on a provider process that
  # ended until then: the session waits for it. A provider process that
  # ends after this check ends during the turn, and its `:provider_down`
  # fails the turn (see `Hands.prepare/3`).
  defp await_ended_provider(%State{conn: %ProviderConn{pid: pid}} = state) do
    if Process.alive?(pid),
      do: state,
      else: %{state | conn: nil, activity: %Wait{provider: pid}}
  end

  defp await_ended_provider(state), do: state

  # Starts a turn with one user message per text, in order.
  defp begin_turn(%State{} = state, texts) do
    turn = %Turn{id: Id.new(), model: state.model, provider: state.provider}
    state = open_turn(state, turn, %{})
    call_provider(Enum.reduce(texts, state, &Messages.append_user(&2, &1)))
  end

  defp open_turn(state, turn, data),
    do: %{state | activity: turn} |> emit(:agent_start, %{}) |> emit(:turn_start, data)

  defp queue_reply(%State{} = state, key, text) do
    held = if key == :steers, do: held(state), else: 0

    case Queues.push(state.queues, key, text, held) do
      {:ok, queues} -> {:reply, :ok, emit_queue(%{state | queues: queues})}
      {:error, :queue_full} = error -> {:reply, error, state}
    end
  end

  defp emit_queue(%State{} = state), do: emit(state, :queue_update, Queues.counts(state.queues))

  defp drop_queues(%State{queues: queues} = state) when queues == %Queues{}, do: state
  defp drop_queues(%State{} = state), do: emit_queue(%{state | queues: %Queues{}})

  # A normal turn end starts a new turn with everything still queued, steers
  # first. The drain event goes out between the turns, with a nil turn id.
  defp start_queued(%State{} = state) do
    case Queues.drain(state.queues) do
      {[], _queues} ->
        state

      {texts, queues} ->
        %{state | queues: queues}
        |> emit_queue()
        |> begin_turn(texts)
    end
  end

  # The queued steers join the transcript as user messages, in order.
  # Returns their texts.
  defp append_steers(%State{} = state) do
    case Queues.drain_steers(state.queues) do
      {[], _queues} ->
        {[], state}

      {steers, queues} ->
        state = Enum.reduce(steers, %{state | queues: queues}, &Messages.append_user(&2, &1))
        {steers, emit_queue(state)}
    end
  end

  # The steers of the turn that have no `user_message` or no answer yet,
  # and the open steer requests of the wait after it: they count in the 32
  # steers.
  defp held(%State{activity: %{steers: steers}}), do: Steers.held(steers)
  defp held(_state), do: 0

  # Sends a steer to the provider process with its own id and the steer
  # bound (see `Helyx.Session.ProviderProcess`).
  defp send_steer(text, %State{activity: turn, conn: %ProviderConn{pid: pid}} = state) do
    steer_id = Id.new()
    from = ask(state, pid, {:steer, turn.id, steer_id, text}, :steer)
    %{state | activity: %{turn | steers: Steers.sent(turn.steers, from, steer_id, text)}}
  end

  # At the `:ok` of the turn, the steers that waited in `submitting` go to
  # the provider process, in order.
  defp send_local_steers(%State{} = state) do
    case Queues.drain_steers(state.queues) do
      {[], _queues} ->
        state

      {steers, queues} ->
        emit_queue(Enum.reduce(steers, %{state | queues: queues}, &send_steer/2))
    end
  end

  # A confirmed rejection: the steer waits in the local queue for the next
  # turn. Its place in the limit was held, so it fits.
  defp requeue_steer(%State{} = state, text) do
    {:ok, queues} = Queues.push(state.queues, :steers, text, held(state))
    emit_queue(%{state | queues: queues})
  end

  # Applies the effects of the steer ledger (see `Helyx.Session.Steers`),
  # in order.
  defp steer_effects(state, effects), do: Enum.reduce(effects, state, &steer_effect/2)

  defp steer_effect({:take, text}, state), do: Messages.take_steer(state, text)
  defp steer_effect({:requeue, text}, state), do: requeue_steer(state, text)

  defp steer_effect({:notice, turn_id, text}, state),
    do: emit(state, turn_id, :steer_unconfirmed, %{text: text})

  # The provider process (started at the first turn) and a prepare Task of
  # the hands, which builds the context.
  defp call_provider(%State{} = state) do
    case connect(state) do
      {:ok, state} -> prepare(put_in(state.activity.phase, :preparing))
      {:error, text} -> fail_turn(text, state)
    end
  end

  defp base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]

  # The prepare Task of the hands builds the context, under `prepare_ms`.
  defp prepare(%State{activity: %Turn{id: turn_id}} = state) do
    session = self()
    %State{model_context: model_context, compaction: compaction} = state
    context = %Context{messages: state.transcript, tools: state.tools}
    opts = [turn_id: turn_id] ++ base_opts(state)

    :ok =
      Hands.prepare(state.hands, turn_id, fn tref ->
        result = Helyx.Session.Stream.prepare(model_context, compaction, context, opts)
        :timer.cancel(tref)
        send(session, {:prepared, turn_id, result})
      end)

    state
  end

  # `settle/1` closed a provider process of another model before the turn.
  defp connect(%State{conn: %ProviderConn{model: model}, activity: %Turn{model: model}} = state),
    do: {:ok, state}

  defp connect(%State{conn: nil, activity: turn} = state) do
    resumed = Transcript.resumable(state.transcript, state.resume_ids, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tools,
      opts: [resume_id: resumed] ++ base_opts(state),
      session: self()
    }

    with {:ok, pid} <-
           Hands.start_provider(state.hands, turn.provider, ProviderProcess.run(args)) do
      conn = %ProviderConn{pid: pid, model: turn.model}
      {:ok, %{state | conn: conn, activity: %{turn | resumed: resumed}}}
    end
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
    {steers, %State{activity: turn} = state} = append_steers(state)
    context = %{context | messages: context.messages ++ Enum.map(steers, &Message.user/1)}
    from = ask(state, pid, {:turn, turn.id, context}, :turn)
    %{state | activity: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  defp submit(state), do: state

  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    {%State{activity: turn} = state, assistant, _calls} =
      Messages.close_assistant(state, stop_reason, usage)

    # A call in the last message gets no result. A steer with no answer yet
    # can still be rejected: the session waits for its answer before the
    # next turn.
    {wait, effects} = Wait.after_turn(turn, provider_pid(state), true)

    state =
      state
      |> Messages.abort_open_calls()
      |> steer_effects(effects)
      |> emit(:turn_end, %{message: assistant})
      |> emit(:agent_end, %{stop_reason: stop_reason})

    # A Helyx tool that still runs: the turn cleanup of the hands runs
    # before the next turn.
    hands = if turn.tool, do: Hands.request_cancel(state.hands, turn.id)
    # A wait with nothing open ends at once and settles.
    progress(%{state | activity: %{wait | hands: hands}})
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # Runs a Helyx tool request on the hands, with no event: the provider's
  # own events show the call.
  defp run_on_hands(call, %State{activity: turn} = state) do
    :ok = Hands.run(state.hands, turn.id, call)
    state
  end

  # A partial assistant message is closed with a failure stop reason so
  # clients do not keep it open. It is not added to the transcript.
  # A turn can fail after a message whose calls have no result yet. A failed
  # turn runs the turn cleanup of the hands before the next turn: its
  # prepare Task can still run.
  defp fail_turn(reason, %State{activity: turn} = state) do
    {wait, effects} = Wait.after_turn(turn, provider_pid(state), false)

    state =
      state
      |> steer_effects(effects)
      |> Messages.abort_open_calls()
      |> Messages.close_partial_message(:error, reason)
      |> drop_queues()
      |> emit(:agent_end, %{stop_reason: :error, error: reason})

    hands = Hands.request_cancel(state.hands, turn.id)
    %{state | activity: %{wait | hands: hands}}
  end

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
