defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks. Each matches a message to
  # the current turn, call, or provider process, and the turn lifecycle is
  # in `Helyx.Session.Server.TurnLoop`. The client API and the docs of the
  # behaviour are in `Helyx.Session`.

  alias Helyx.ModelRef
  alias Helyx.Session.{Hands, Id, Queue, Snapshot, Transcript, Turn}

  alias Helyx.Session.Server.{
    Messages,
    ProviderConn,
    Record,
    State,
    Steering,
    Stop,
    Tools,
    TurnLoop,
    Wait
  }

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
      do: {:reply, :ok, TurnLoop.begin_turn(state, [text])}

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
    {:reply, :ok, TurnLoop.settle(emit(state, nil, :model_change, %{model: model}))}
  end

  # A steer of an ended turn can still wait for its answer: the abort gives
  # its notice now, so a late `:rejected` queues nothing.
  def handle_call(:abort, _from, %State{activity: :idle} = state),
    do: {:reply, :ok, Steering.abort(state)}

  # The release of the hands can take longer than the timeout of a client call
  # (issue #93), so the session does not wait in a call: the answer of the
  # hands arrives as a message, and the abort callers get their reply then.
  # An abort in a wait drops the queues too, so no message sent before it
  # starts a turn.
  def handle_call(:abort, from, %State{} = state), do: {:noreply, TurnLoop.abort(state, from)}

  @impl true
  def handle_info(
        {:stream_event, turn_id, {:message_end, stop_reason, usage}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, Messages.end_assistant(state, stop_reason, usage)}

  # The first result of a call in the open message closes that message
  # first. A result goes to the first open call with its id
  # (`Transcript.open_calls/1`), so the transcript, the file, and the
  # replay agree. A result for no open call is dropped.
  def handle_info(
        {:stream_event, turn_id, {:tool_result, call_id, result}},
        %State{activity: %Turn{id: turn_id}} = state
      ) do
    state = Messages.close_for_result(state, call_id)

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
  # provider's own events, not from here. A request of a turn that is not
  # current gets `aborted`.
  def handle_info(
        {:tool_request, _pid, turn_id, call, rejection},
        %State{activity: %Turn{id: turn_id}} = state
      ) do
    case Tools.request(state, call, rejection) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason} -> {:noreply, TurnLoop.stop_provider(state, reason)}
    end
  end

  def handle_info({:tool_request, pid, turn_id, call, _rejection}, state),
    do: {:noreply, Tools.late(state, pid, turn_id, call.id)}

  def handle_info({:cancel_tool, call_id}, %State{activity: %Turn{}} = state),
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

  # A turn that the provider started by itself (#240) opens only with no
  # turn and no wait: a submitted turn with no user message. Any other
  # time it is dropped with its events; its tool requests get `aborted`.
  def handle_info(
        {:stream_event, turn_id, :turn_start},
        %State{activity: :idle, conn: %ProviderConn{ready: true}} = state
      ),
      do: {:noreply, TurnLoop.program_turn(state, turn_id)}

  def handle_info({:stream_event, _id, :turn_start}, state), do: {:noreply, state}

  def handle_info({:stream_event, turn_id, event}, %State{activity: %Turn{id: turn_id}} = state) do
    %State{activity: turn} = state = Messages.start_assistant_message(state)

    {:noreply,
     %{state | activity: Turn.add_block(turn, event)}
     |> emit(:message_update, Map.new([event]))}
  end

  # The terminal of the turn, from the provider process.
  def handle_info({:stream_end, turn_id, terminal}, %State{activity: %Turn{id: turn_id}} = state),
    do: {:noreply, TurnLoop.end_turn(terminal, state)}

  # The hands' result of the running Helyx tool.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{activity: %Turn{id: turn_id, tools: %{running: call_id}}} = state
      ),
      do: {:noreply, Tools.result(state, result)}

  # The messages of a turn (see "Turn states" in
  # `docs/features/long-lived-harness.md`). The turn is `preparing` until
  # the session sends `{:turn, ...}`, which needs a ready provider process
  # and the prepared context; `submitting` until the answer; then
  # `submitted`.
  def handle_info({:provider_ready, pid}, %State{conn: %ProviderConn{pid: pid}} = state),
    do: {:noreply, TurnLoop.provider_ready(state)}

  # The result of the turn's prepare Task, at the turn start or for a
  # context request (C1-C4, `one-provider-path.md`). A request or a context
  # of a turn that ended is dropped.
  def handle_info(
        {:prepared, turn_id, result},
        %State{activity: %Turn{id: turn_id, phase: phase}} = state
      )
      when phase in [:preparing, :context],
      do: {:noreply, TurnLoop.prepared(state, result)}

  # A context request comes after the events before it, and is answered as
  # a tool result is.
  def handle_info({:need_context, turn_id}, %State{activity: %Turn{id: turn_id}} = state),
    do: {:noreply, TurnLoop.need_context(state)}

  def handle_info(
        {:provider_reply, from, :turn, reply},
        %State{activity: %Turn{pending: from}} = state
      ),
      do: {:noreply, TurnLoop.turn_reply(state, reply)}

  # The answer to a steer, also after its turn (see "Steer" in
  # `docs/features/long-lived-harness.md` and `Queue.answer/3`). A late
  # `:rejected` queues the steer, and an idle session starts it.
  def handle_info({:provider_reply, from, :steer, reply}, %State{} = state),
    do: {:noreply, TurnLoop.progress(Steering.answer(state, from, reply))}

  def handle_info(
        {:provider_reply, from, kind, reply},
        %State{activity: %Wait{reply: from}} = state
      ),
      do: {:noreply, TurnLoop.wait_reply(state, kind, reply)}

  # The idle timer of the provider process. Only the current timer counts,
  # and only while the session is idle: a turn or a wait since it was armed
  # makes it old. The wait holds every message until the answer.
  def handle_info(
        {:timeout, ref, :idle_close},
        %State{idle: ref, activity: :idle, conn: %ProviderConn{ready: true}} = state
      ),
      do: {:noreply, TurnLoop.idle_close(state)}

  def handle_info({:timeout, _ref, :idle_close}, state), do: {:noreply, state}

  # From the hands, after the release of the provider process's handles:
  # the end of the provider process that the wait is for, or of the current
  # one. Any other `:provider_down` is a bug and crashes the session.
  def handle_info({:provider_down, pid, reason}, %State{activity: %Wait{provider: pid}} = state),
    do: {:noreply, TurnLoop.provider_down(state, pid, reason)}

  def handle_info({:provider_down, pid, reason}, %State{conn: %ProviderConn{pid: pid}} = state),
    do: {:noreply, TurnLoop.provider_down(state, pid, reason)}

  # The session's monitor of the current provider process (#361).
  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %State{conn: %ProviderConn{pid: pid}} = state
      ),
      do: {:noreply, TurnLoop.monitor_down(state, pid)}

  # The end of the turn's prepare Task before its context. A Task that sent
  # its context is no longer `Turn.prepare`: its `:DOWN` comes after.
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %State{activity: %Turn{prepare: pid}} = state
      ),
      do: {:noreply, TurnLoop.prepare_down(state, reason)}

  # A message for a turn, a call, or a provider process that is no longer
  # current, or a reply that nobody waits for.
  def handle_info({:provider_ready, _pid}, state), do: {:noreply, state}
  def handle_info({:provider_reply, _from, _kind, _reply}, state), do: {:noreply, state}
  def handle_info({:prepared, _turn_id, _result}, state), do: {:noreply, state}
  def handle_info({:need_context, _turn_id}, state), do: {:noreply, state}
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:cancel_tool, _call_id}, state), do: {:noreply, state}
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

  # The `:DOWN` of a provider process that the session dropped already, of
  # a prepare Task that sent its context or was killed at its turn end, or
  # of the hands' cleanup request (their `:EXIT` stops the session).
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
  def handle_info(message, %State{activity: %Wait{hands: request}} = state)
      when request != nil do
    {:reply, result} = :gen_server.check_response(message, request)
    {:noreply, TurnLoop.cleanup_done(state, result)}
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

  defp queue_reply(state, key, text) do
    case Steering.queue(state, key, text) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, :queue_full} = error -> {:reply, error, state}
    end
  end

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
