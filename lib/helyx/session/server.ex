defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks and the turn loop. The
  # client API and the docs of the behaviour are in `Helyx.Session`.

  require Logger

  alias Helyx.{Context, Event, Message, ModelRef}
  alias Helyx.Session.{Hands, Harness, Id, Queues, Snapshot, Steers, Transcript, Turn, Wait}

  defmodule State do
    @moduledoc false
    @enforce_keys [:id, :core, :model, :provider, :turn_mode, :cwd]

    # The armed kill of a turn, interrupt, steer, tool result, or tool
    # start request: the loop writes one stdio line and replies, well under
    # 10 ms.
    @harness_reply_ms 2_000
    # The armed kill of a close: end of input, then the exit.
    @harness_close_ms 5_000
    def harness_close_ms, do: @harness_close_ms

    defstruct [
      :id,
      # A new id for each start of the process, a resume too (`Helyx.Event`).
      :instance_id,
      :core,
      :model,
      :provider,
      # The turn of `provider`, `:local` or `:connected`
      # (`Helyx.Provider.turn/1`).
      :turn_mode,
      :cwd,
      :hands,
      :file,
      # The registered ModelContext and Compaction plugins, or nil for none.
      :model_context,
      :compaction,
      # The checked tool specs of `Helyx.Tool.specs/1` at session start,
      # which every provider call uses, and the tool module by name for the
      # hands.
      tools: [],
      tool_modules: %{},
      transcript: [],
      seq: 0,
      # Each subscriber pid and the session's monitor of it (session-subscribers.md).
      subscribers: %{},
      # `:idle`, the turn in progress (a `%Turn{}`), or the wait before
      # the next turn can start (a `%Wait{}`, see `Helyx.Session.Wait`).
      activity: :idle,
      queues: %Queues{},
      # The last harness session per harness provider id: its id and the
      # number of transcript messages before it started.
      harness_sessions: %{},
      # The harness process of a connected provider (ADR 0007), a
      # `%Connection{}`, or nil.
      harness: nil,
      # The bounds of the requests to the harness process, in ms: the
      # armed kills (see `Helyx.Session.Harness`), and `idle`, the time with
      # no turn after which the session sends `:idle_close`. A seam for
      # tests.
      harness_ms: %{
        turn: @harness_reply_ms,
        interrupt: @harness_reply_ms,
        steer: @harness_reply_ms,
        tool_result: @harness_reply_ms,
        tool_start: @harness_reply_ms,
        close: @harness_close_ms,
        idle: 1_800_000
      },
      # The current idle timer (`:erlang.start_timer/3`, see `arm_idle/1`),
      # or nil.
      idle: nil
    ]
  end

  defmodule Connection do
    @moduledoc false
    # The harness process of a connected provider: its pid, the model it
    # runs, and whether `harness_init/3` returned (`{:harness_ready, pid}`).
    @enforce_keys [:pid, :model]
    defstruct [:pid, :model, ready: false]
  end

  # The stop of a session (`terminate/2`): the close of an idle harness
  # process (`State.harness_close_ms/0`, armed kill), then the stop of the
  # hands, which can finish one release (`Hands.State.release_ms/0`). Each
  # wait has a margin for load, so the supervisor does not kill the session
  # first.
  @load_hands_stop_ms 2_000
  @load_shutdown_ms 3_000
  @hands_stop_ms Hands.State.release_ms() + @load_hands_stop_ms
  use GenServer,
    restart: :temporary,
    shutdown: State.harness_close_ms() + @hands_stop_ms + @load_shutdown_ms

  def start_link(%State{id: id, core: core} = state) do
    GenServer.start_link(__MODULE__, state, name: via(core, id))
  end

  # Callbacks

  @impl true
  def init(%State{} = state) do
    # The session traps exits: the hands and the provider Task are linked,
    # so their crashes arrive as messages, and a death of the session takes
    # both with it (ADR 0004).
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

  # A steer on a `submitted` connected turn goes to the harness process; in
  # `preparing` and `submitting` it stays in the local queue (see "Turn
  # states" in `docs/features/long-lived-harness.md`). A sent steer counts
  # in the 32 steers until its `user_message` and its answer (see `held/1`).
  def handle_call(
        {:steer, text},
        _from,
        %State{activity: %Turn{turn_mode: :connected, phase: :submitted}} = state
      ) do
    if Queues.steer_room?(state.queues, held(state)),
      do: {:reply, :ok, send_steer(text, state)},
      else: {:reply, {:error, :queue_full}, state}
  end

  def handle_call({:steer, text}, _from, %State{activity: %Turn{}} = state),
    do: queue_reply(state, :steers, text)

  def handle_call({:follow_up, text}, _from, %State{activity: %Turn{}} = state),
    do: queue_reply(state, :follow_ups, text)

  # A harness process that ended while the session was idle can still have
  # its handles in a release of the hands: the message waits for its
  # `:harness_down` as a follow-up.
  def handle_call({op, text}, _from, %State{} = state)
      when op in [:prompt, :steer, :follow_up] do
    case await_ended_harness(state) do
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
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    handle_call(:snapshot, from, %{state | subscribers: subscribers})
  end

  def handle_call({:set_model, %ModelRef{} = ref, provider, turn_mode}, _from, %State{} = state) do
    model = ModelRef.to_string(ref)
    state = persist(state, &Helyx.Session.File.append_model_change(&1, model))
    state = %{state | model: ref, provider: provider, turn_mode: turn_mode}
    {:reply, :ok, settle(do_emit(state, nil, :model_change, %{model: model}))}
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
    {state, _assistant, calls} = close_assistant(state, stop_reason, usage)
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
        {:noreply, record_result(call, result, state)}
    end
  end

  # The harness took a steer of this turn: its text, the one the session
  # checked at the client call, joins the transcript here (see
  # `Steers.take/2`).
  def handle_info(
        {:stream_event, turn_id, {:user_message, steer_id, _text}},
        %State{activity: %Turn{id: turn_id} = turn} = state
      ) do
    {steers, effects} = Steers.take(turn.steers, steer_id)
    {:noreply, steer_effects(put_in(state.activity.steers, steers), effects)}
  end

  # The harness asks for a Helyx tool (see "Helyx tool calls" in
  # `docs/features/long-lived-harness.md`). The loop owns the waiting
  # queue and sends a request only when the result of the one before came,
  # so `tool` holds only the running call. The call
  # and its result join the transcript from the harness's own events, not
  # from here.
  def handle_info(
        {:stream_event, turn_id, {:tool_request, id, name, args}},
        %State{
          activity: %Turn{id: turn_id, turn_mode: :connected} = turn,
          harness: %Connection{pid: pid}
        } = state
      ) do
    call = %Message.ToolCall{id: id, name: name, arguments: args}
    from = Harness.request(pid, {:tool_start, turn_id, id}, state.harness_ms.tool_start)
    {:noreply, %{state | activity: %{turn | tool: call, start: from}}}
  end

  # The loop's answer to the ask: only `:ok` runs the call. A missed
  # deadline stops the harness process, and its `:harness_down` fails the
  # turn; an answer after the turn goes to the wait after the turn.
  def handle_info(
        {:harness_reply, from, :tool_start, reply},
        %State{activity: %Turn{start: from, tool: call} = turn} = state
      ) do
    state = %{state | activity: %{turn | start: nil}}

    {:noreply,
     if(reply == :ok, do: run_on_hands(call, state), else: put_in(state.activity.tool, nil))}
  end

  # The harness withdrew a tool request: a running one is killed, and its
  # result, which the hands still send, is dropped by the loop.
  def handle_info(
        {:cancel_tool, turn_id, call_id},
        %State{activity: %Turn{id: turn_id, tool: %{id: call_id}}} = state
      ) do
    Hands.kill(state.hands, turn_id, call_id)
    {:noreply, state}
  end

  # Only a connected turn runs Helyx tools for the harness.
  def handle_info({:stream_event, _turn_id, {:tool_request, _, _, _}}, state),
    do: {:noreply, state}

  def handle_info(
        {:stream_event, turn_id, {:harness_session, id, cut}},
        %State{activity: %Turn{id: turn_id} = turn} = state
      ) do
    # The provider id is the prefix of the turn's model ref: `find/2`
    # matched it, so the session runs no plugin code for it.
    provider = turn.model.provider
    state = persist(state, &Helyx.Session.File.append_harness_session(&1, provider, id))
    sessions = Map.put(state.harness_sessions, provider, {id, length(state.transcript)})
    state = %{state | harness_sessions: sessions}
    data = %{provider: provider, harness_session_id: id, lost: turn.resumed != nil, cut: cut}
    {:noreply, emit(state, :harness_session, data)}
  end

  # A notice of the provider is an event only: it joins no message, so the
  # transcript that the model gets again never holds it.
  def handle_info(
        {:stream_event, turn_id, {:notice, text}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, emit(state, :notice, %{text: text})}

  # A turn that the program started by itself (#240) opens only with no
  # turn and no wait: a submitted connected turn with no user message. Any
  # other time it is dropped, and so are its events.
  def handle_info(
        {:stream_event, turn_id, :program_turn},
        %State{activity: :idle, harness: %Connection{ready: true, model: model}} = state
      ) do
    turn = %Turn{
      id: turn_id,
      model: model,
      provider: state.provider,
      turn_mode: :connected,
      phase: :submitted
    }

    {:noreply, open_turn(state, turn, %{origin: :program})}
  end

  def handle_info({:stream_event, _turn_id, :program_turn}, state), do: {:noreply, state}

  def handle_info({:stream_event, turn_id, event}, %State{activity: %Turn{id: turn_id}} = state) do
    %State{activity: turn} = state = start_assistant_message(state)

    {:noreply,
     %{state | activity: Turn.add_block(turn, event)}
     |> emit(:message_update, Map.new([event]))}
  end

  # Arrives before the stream event of the call it names (see
  # `Helyx.Session.Stream`).
  def handle_info(
        {:rejected_call, turn_id, call, reason},
        %State{activity: %Turn{id: turn_id} = turn} = state
      ) do
    {:noreply, %{state | activity: Turn.reject(turn, call, reason)}}
  end

  # The Task's reply is the terminal stream event. Its :DOWN follows and is
  # flushed here, so a :DOWN only reaches the session when the Task crashed.
  # The Task is linked, so its exit signal follows the reply too; it is
  # taken here, so it never reaches the vital :EXIT clause.
  def handle_info(
        {ref, terminal},
        %State{activity: %Turn{task: %Task{ref: ref, pid: pid}}} = state
      ) do
    Process.demonitor(ref, [:flush])
    receive do: ({:EXIT, ^pid, _} -> :ok)
    {:noreply, end_turn(terminal, state)}
  end

  # A crashed Task gives both its :DOWN and its exit signal, in either
  # order. The first one fails the turn, and the other one is taken here.
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %State{activity: %Turn{task: %Task{ref: ref}}} = state
      ) do
    receive do: ({:EXIT, ^pid, _} -> :ok)
    {:noreply, fail_turn({:task_exit, Message.cap_integers(reason)}, state)}
  end

  def handle_info(
        {:EXIT, pid, reason},
        %State{activity: %Turn{task: %Task{ref: ref, pid: pid}}} = state
      ) do
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    {:noreply, fail_turn({:task_exit, Message.cap_integers(reason)}, state)}
  end

  # The terminal of a connected turn, from the harness process.
  def handle_info({:stream_end, turn_id, terminal}, %State{activity: %Turn{id: turn_id}} = state) do
    {:noreply, end_turn(terminal, state)}
  end

  # The result of a Helyx tool of a connected turn goes to the harness
  # process, with the tool result bound. Its answer is awaited, as a steer's
  # is, so no turn starts while its kill is armed.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{
          activity: %Turn{id: turn_id, turn_mode: :connected, tool: %{id: call_id}} = turn,
          harness: %Connection{pid: pid}
        } = state
      ) do
    from =
      Harness.request(pid, {:tool_result, turn_id, call_id, result}, state.harness_ms.tool_result)

    {:noreply, %{state | activity: %{turn | tool: nil, results: [from | turn.results]}}}
  end

  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{
          activity:
            %Turn{
              id: turn_id,
              turn_mode: :local,
              calls: [%Message.ToolCall{id: call_id} = call | rest]
            } =
              turn
        } =
          state
      ) do
    state = record_result(call, result, %{state | activity: %{turn | calls: rest}})

    case rest do
      [] -> {:noreply, start_provider_call(state)}
      [next | _] -> {:noreply, run_tool(next, state)}
    end
  end

  # The messages of a connected turn (see "Turn states" in
  # `docs/features/long-lived-harness.md`). The turn is `preparing` until
  # the session sends `{:turn, ...}`, which needs a ready harness process
  # and the prepared context; `submitting` until the answer; then
  # `submitted`.
  def handle_info({:harness_ready, pid}, %State{harness: %Connection{pid: pid} = harness} = state) do
    {:noreply, arm_idle(submit(%{state | harness: %{harness | ready: true}}))}
  end

  # The prepare Task checked the context (`Stream.prepare/4`): a plugin
  # that returned anything else fails the turn.
  def handle_info(
        {:prepared, turn_id, {:ok, context}},
        %State{activity: %Turn{id: turn_id, phase: :preparing} = turn} = state
      ) do
    {:noreply, submit(%{state | activity: %{turn | context: context}})}
  end

  def handle_info(
        {:prepared, turn_id, {:error, reason}},
        %State{activity: %Turn{id: turn_id, phase: :preparing}} = state
      ) do
    {:noreply, fail_turn(reason, state)}
  end

  def handle_info(
        {:prepare_failed, turn_id, reason},
        %State{activity: %Turn{id: turn_id, phase: :preparing}} = state
      ) do
    {:noreply, fail_turn({:task_exit, reason}, state)}
  end

  # An answer other than `:ok` ends the harness process, and its
  # `:harness_down` fails the turn.
  def handle_info(
        {:harness_reply, from, :turn, reply},
        %State{activity: %Turn{pending: from} = turn} = state
      ) do
    phase = if reply == :ok, do: :submitted, else: :submitting
    state = %{state | activity: %{turn | pending: nil, phase: phase}}
    {:noreply, if(reply == :ok, do: send_local_steers(state), else: state)}
  end

  # The answer to a steer of the turn (see "Steer" in
  # `docs/features/long-lived-harness.md` and `Steers.answer/3`).
  def handle_info(
        {:harness_reply, from, :steer, reply},
        %State{activity: %Turn{turn_mode: :connected} = turn} = state
      ) do
    {steers, effects} = Steers.answer(turn.steers, from, reply)
    {:noreply, steer_effects(put_in(state.activity.steers, steers), effects)}
  end

  # The answer to a tool result of the turn: it was written.
  def handle_info(
        {:harness_reply, from, :tool_result, _reply},
        %State{activity: %Turn{turn_mode: :connected} = turn} = state
      ) do
    {:noreply, put_in(state.activity.results, List.delete(turn.results, from))}
  end

  # A reply in the wait acts only on the part whose stored ref it matches
  # (see `Wait.answer/4`).
  def handle_info({:harness_reply, from, kind, reply}, %State{activity: %Wait{} = wait} = state) do
    {wait, effects} = Wait.answer(wait, kind, from, reply)
    {:noreply, progress(steer_effects(%{state | activity: wait}, effects))}
  end

  # The idle timer of the harness process. Only the current timer counts,
  # and only while the session is idle: a turn or a wait since it was armed
  # makes it old. The wait holds every message until the answer.
  def handle_info(
        {:timeout, ref, :idle_close},
        %State{idle: ref, activity: :idle, harness: %Connection{pid: pid, ready: true}} = state
      ) do
    from = Harness.request(pid, :idle_close, state.harness_ms.close)
    {:noreply, %{state | idle: nil, activity: %Wait{idle: from, harness: pid}}}
  end

  def handle_info({:timeout, _ref, :idle_close}, state), do: {:noreply, state}

  # From the hands, after the release of the harness process's handles: the
  # end of the harness process that the wait is for, or of the one that
  # holds the requests of the turn that ended (see `Wait.harness_down/2`).
  def handle_info({:harness_down, pid, _reason}, %State{activity: %Wait{harness: pid}} = state),
    do: {:noreply, wait_harness_down(state, pid)}

  def handle_info(
        {:harness_down, pid, _reason},
        %State{harness: %Connection{pid: pid}, activity: %Wait{}} = state
      ),
      do: {:noreply, wait_harness_down(state, pid)}

  def handle_info(
        {:harness_down, pid, reason},
        %State{harness: %Connection{pid: pid}, activity: %Turn{turn_mode: :connected}} = state
      ) do
    {:noreply, fail_turn(reason, %{state | harness: nil})}
  end

  def handle_info({:harness_down, pid, _reason}, %State{harness: %Connection{pid: pid}} = state) do
    {:noreply, %{state | harness: nil}}
  end

  # A message for a turn, a call, or a harness process that is no longer
  # current, or a reply that nobody waits for.
  def handle_info({:harness_ready, _pid}, state), do: {:noreply, state}
  def handle_info({:harness_reply, _from, _kind, _reply}, state), do: {:noreply, state}
  def handle_info({:harness_down, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:prepared, _turn_id, _result}, state), do: {:noreply, state}
  def handle_info({:prepare_failed, _turn_id, _reason}, state), do: {:noreply, state}
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:cancel_tool, _turn_id, _call_id}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}
  def handle_info({:stream_end, _turn_id, _terminal}, state), do: {:noreply, state}
  def handle_info({:rejected_call, _turn_id, _call, _reason}, state), do: {:noreply, state}

  # The failed subscribe of `Helyx.Session.subscribe/1`, and the end of a
  # subscriber: only the monitor of its entry removes the entry.
  def handle_info({:unsubscribe, pid}, %State{} = state) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    _ = ref && Process.demonitor(ref, [:flush])
    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{subscribers: subscribers} = state)
      when :erlang.map_get(pid, subscribers) == ref,
      do: {:noreply, %{state | subscribers: Map.delete(subscribers, pid)}}

  # The hands are linked and vital: their death takes the session with it.
  def handle_info({:EXIT, pid, reason}, %State{hands: pid} = state), do: {:stop, reason, state}

  # The exit signal of a provider Task never gets here: the clauses of its
  # reply and its crash take it, and `shutdown_stream/1` flushes it. An exit
  # from any other linked process, the sessions Registry for example, is
  # vital: a session that outlived its registration would keep working
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
    do_emit(state, nil, :notice, %{text: text})
  end

  # The session stops only for a trapped reason; on an untrappable kill the
  # link kills the provider Task, and the hands take the tool Tasks.
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

  defp end_work(%State{activity: %Turn{task: %Task{} = task}}),
    do: Task.shutdown(task, :brutal_kill)

  defp end_work(%State{activity: %Turn{}}), do: :ok

  # A session that ends with no turn closes its harness processes: the
  # current one and the one its wait is for (an idle close, a switch
  # close, an abort). Each gets a close, end of input then the exit, after
  # any request it has open: a `:busy` answer to an idle close does not
  # keep it. The armed close kills bound the waits, which run in parallel,
  # and a harness process that is already gone gives its `:DOWN` at once.
  defp end_work(%State{activity: activity} = state) do
    pids = [harness_pid(state), wait_pid(activity)]

    refs =
      for pid <- Enum.uniq(pids), is_pid(pid) do
        ref = Process.monitor(pid)
        Harness.request(pid, :close, state.harness_ms.close)
        ref
      end

    for ref <- refs do
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end
  end

  defp wait_pid(%Wait{harness: pid}), do: pid
  defp wait_pid(:idle), do: nil

  # The hands take the messages before the exit signal first: the end of a
  # closed harness process gets its release. That end reaches the hands
  # before the harness process's `:DOWN` reaches the session, on one node.
  # If it came later, the hands would end with no release, and the port
  # would close with the harness process. Each release has its deadline,
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
  # connected turn that sent `{:turn, ...}` also gets an interrupt, after
  # the hands answer.
  defp abort_turn(%State{activity: turn} = state, callers) do
    if turn.task, do: shutdown_stream(turn.task)
    request = Hands.request_cancel(state.hands, turn.id)
    {wait, effects} = Wait.after_turn(turn, harness_pid(state), false)

    state =
      state
      |> steer_effects(effects)
      |> abort_open_calls()
      |> close_partial_message(:aborted, :aborted)
      |> drop_queues()
      |> emit(:agent_end, %{stop_reason: :aborted})

    wait = %{wait | hands: request, callers: callers, interrupt: interrupt(turn, state.harness)}
    %{state | activity: wait}
  end

  defp interrupt(%Turn{turn_mode: :connected, phase: phase, id: id}, %{pid: pid})
       when phase in [:submitting, :submitted],
       do: {pid, id}

  defp interrupt(_turn, _harness), do: nil

  # Runs the wait (see `Wait.next/2`): sends the requests it names, and at
  # its end replies to the abort callers and settles.
  defp progress(%State{activity: %Wait{} = wait} = state) do
    case Wait.next(wait, harness_pid(state)) do
      {:send, wait, pid, request} ->
        from = Harness.request(pid, request, Map.fetch!(state.harness_ms, elem(request, 0)))
        progress(%{state | activity: Wait.sent(wait, request, from)})

      {:done, callers} ->
        Enum.each(callers, &GenServer.reply(&1, :ok))
        settle(%{state | activity: :idle})

      :open ->
        state
    end
  end

  defp harness_pid(%State{harness: %Connection{pid: pid}}), do: pid
  defp harness_pid(_state), do: nil

  # A harness process ended in the wait: see `Wait.harness_down/2`.
  defp wait_harness_down(%State{activity: wait} = state, pid) do
    harness = if harness_pid(state) == pid, do: nil, else: state.harness
    {wait, effects} = Wait.harness_down(wait, pid)
    progress(steer_effects(%{state | harness: harness, activity: wait}, effects))
  end

  # With no turn and no wait, a harness process that ended is waited for
  # (its `:harness_down`), and one of another model than the session's
  # closes before the next turn starts (a provider or a model switch);
  # otherwise the queues start the next turn.
  defp settle(%State{activity: :idle} = state) do
    case await_ended_harness(state) do
      %State{activity: :idle} = state -> arm_idle(close_or_start(state))
      state -> state
    end
  end

  defp settle(state), do: state

  # Arms the idle timer when the session holds a ready harness process
  # with no turn and no wait. It cancels the earlier timer; a message of
  # it that is already in the mailbox has an old ref.
  defp arm_idle(%State{activity: :idle, harness: %Connection{ready: true}} = state) do
    if state.idle, do: :erlang.cancel_timer(state.idle)
    %{state | idle: :erlang.start_timer(state.harness_ms.idle, self(), :idle_close)}
  end

  defp arm_idle(state), do: state

  defp close_or_start(%State{model: model, harness: %Connection{pid: pid, model: other}} = state)
       when other != model do
    Harness.request(pid, :close, state.harness_ms.close)
    %{state | harness: nil, activity: %Wait{harness: pid}}
  end

  defp close_or_start(state), do: start_queued(state)

  # The hands send `:harness_down` only after the release of the harness
  # process's handles, so a turn does not start on a harness process that
  # ended until then: the session waits for it. A harness process that
  # ends after this check ends during the turn, and its `:harness_down`
  # fails the turn (see `Hands.prepare/3`).
  defp await_ended_harness(%State{harness: %Connection{pid: pid}} = state) do
    if Process.alive?(pid),
      do: state,
      else: %{state | harness: nil, activity: %Wait{harness: pid}}
  end

  defp await_ended_harness(state), do: state

  # Starts a turn with one user message per text, in order.
  defp begin_turn(%State{} = state, texts) do
    turn = %Turn{
      id: Id.new(),
      model: state.model,
      provider: state.provider,
      turn_mode: state.turn_mode
    }

    state = open_turn(state, turn, %{})
    start_provider_call(Enum.reduce(texts, state, &append_user(&2, &1)))
  end

  defp open_turn(state, turn, data),
    do: %{state | activity: turn} |> emit(:agent_start, %{}) |> emit(:turn_start, data)

  defp append_user(state, text) do
    user = Message.user(text)

    append_message(state, user)
    |> emit(:message_start, %{message: user})
    |> emit(:message_end, %{message: user})
  end

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

  # Queued steers join the transcript before the provider call they precede.
  defp start_provider_call(%State{} = state) do
    {_steers, state} = append_steers(state)
    call_provider(state)
  end

  # The queued steers join the transcript as user messages, in order.
  # Returns their texts.
  defp append_steers(%State{} = state) do
    case Queues.drain_steers(state.queues) do
      {[], _queues} ->
        {[], state}

      {steers, queues} ->
        state = Enum.reduce(steers, %{state | queues: queues}, &append_user(&2, &1))
        {steers, emit_queue(state)}
    end
  end

  # The steers of the turn that have no `user_message` or no answer yet,
  # and the open steer requests of the wait after it: they count in the 32
  # steers.
  defp held(%State{activity: %{steers: steers}}), do: Steers.held(steers)
  defp held(_state), do: 0

  # Sends a steer to the harness process with its own id and the steer
  # bound (see `Helyx.Session.Harness`).
  defp send_steer(text, %State{activity: turn, harness: %Connection{pid: pid}} = state) do
    steer_id = Id.new()
    from = Harness.request(pid, {:steer, turn.id, steer_id, text}, state.harness_ms.steer)
    %{state | activity: %{turn | steers: Steers.sent(turn.steers, from, steer_id, text)}}
  end

  # At the `:ok` of the turn, the steers that waited in `submitting` go to
  # the harness process, in order.
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

  # The harness took a steer. The open assistant message closes first, and
  # every call still open gets its `aborted` result, as at a `message_end`:
  # no message goes between a call and its result.
  defp take_steer(%State{activity: %Turn{partial: nil}} = state, text),
    do: state |> abort_turn_calls() |> append_user(text)

  defp take_steer(%State{activity: %Turn{partial: partial}} = state, text) do
    stop = if Enum.any?(partial, &match?(%Message.ToolCall{}, &1)), do: :tool_use, else: :end_turn
    {state, _assistant, calls} = close_assistant(state, stop, %{})
    take_steer(%{state | activity: %{state.activity | partial: nil, calls: calls}}, text)
  end

  # Applies the effects of the steer ledger (see `Helyx.Session.Steers`),
  # in order.
  defp steer_effects(state, effects), do: Enum.reduce(effects, state, &steer_effect/2)

  defp steer_effect({:take, text}, state), do: take_steer(state, text)
  defp steer_effect({:requeue, text}, state), do: requeue_steer(state, text)

  defp steer_effect({:notice, turn_id, text}, state),
    do: do_emit(state, turn_id, :steer_unconfirmed, %{text: text})

  # A connected turn: the harness process (started at the first connected
  # turn) and a prepare Task of the hands, which builds the context.
  defp call_provider(%State{activity: %Turn{turn_mode: :connected}} = state) do
    case connect(state) do
      {:ok, %State{activity: turn} = state} ->
        session = self()
        turn_id = turn.id
        %State{model_context: model_context, compaction: compaction} = state
        context = %Context{messages: state.transcript, tools: state.tools}
        opts = [turn_id: turn_id] ++ base_opts(state)

        :ok =
          Hands.prepare(state.hands, turn_id, fn tref ->
            result =
              Helyx.Session.Stream.prepare(model_context, compaction, context, opts)

            :timer.cancel(tref)
            send(session, {:prepared, turn_id, result})
          end)

        %{state | activity: %{turn | phase: :preparing}}

      {:error, text} ->
        fail_turn(text, state)
    end
  end

  # A local turn: the stream runs in a Task under Core's task supervisor,
  # linked, so a crash stays a message (the session traps exits), and a
  # death of the session kills the stream.
  defp call_provider(%State{activity: %Turn{id: turn_id} = turn} = state) do
    args = %{
      model_context: state.model_context,
      compaction: state.compaction,
      provider: turn.provider,
      model: turn.model.model,
      context: %Context{messages: state.transcript, tools: state.tools},
      opts: [turn_id: turn_id] ++ base_opts(state),
      session: self(),
      turn_id: turn_id
    }

    task =
      Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), fn ->
        Helyx.Session.Stream.run(args)
      end)

    %{state | activity: %{turn | rejected: %{}, task: task}}
  end

  defp base_opts(state), do: [core: state.core, session_id: state.id, cwd: state.cwd]

  # `settle/1` closed a harness process of another model before the turn.
  defp connect(%State{harness: %Connection{model: model}, activity: %Turn{model: model}} = state),
    do: {:ok, state}

  defp connect(%State{harness: nil, activity: turn} = state) do
    resumed = Transcript.resumable(state.transcript, state.harness_sessions, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tools,
      opts: [harness_session_id: resumed] ++ base_opts(state),
      session: self()
    }

    with {:ok, pid} <- Hands.connect(state.hands, turn.provider, &Harness.run(args, &1)) do
      harness = %Connection{pid: pid, model: turn.model}
      {:ok, %{state | harness: harness, activity: %{turn | resumed: resumed}}}
    end
  end

  # Sends `{:turn, ...}` when the harness process is ready and the context
  # is prepared. The steers queued in `preparing` join the transcript and
  # the end of the context: they are part of the prompt, not steers.
  defp submit(
         %State{
           activity: %Turn{phase: :preparing, context: context},
           harness: %Connection{pid: pid, ready: true}
         } = state
       )
       when context != nil do
    {steers, %State{activity: turn} = state} = append_steers(state)
    context = %{context | messages: context.messages ++ Enum.map(steers, &Message.user/1)}
    from = Harness.request(pid, {:turn, turn.id, context}, state.harness_ms.turn)
    %{state | activity: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  defp submit(state), do: state

  # `Task.shutdown/2` unlinks the Task before it kills it, so no exit
  # signal from it arrives later; one that came before the unlink is
  # flushed here.
  defp shutdown_stream(%Task{pid: pid} = task) do
    Task.shutdown(task, :brutal_kill)

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    {%State{activity: turn} = state, assistant, calls} =
      close_assistant(state, stop_reason, usage)

    case {calls, turn.turn_mode} do
      {[first | _], :local} ->
        run_tool(first, %{state | activity: %{turn | task: nil, partial: nil, calls: calls}})

      # A connected provider ran its calls itself; one in the last message
      # gets no result. A steer with no answer yet can still be rejected:
      # the session waits for its answer before the next turn.
      _no_calls_or_connected ->
        {wait, effects} = Wait.after_turn(turn, harness_pid(state), true)

        state =
          state
          |> abort_open_calls()
          |> steer_effects(effects)
          |> emit(:turn_end, %{message: assistant})
          |> emit(:agent_end, %{stop_reason: stop_reason})

        # A Helyx tool that still runs: the turn cleanup of the hands
        # runs before the next turn.
        hands = if turn.tool, do: Hands.request_cancel(state.hands, turn.id)
        # A wait with nothing open ends at once and settles.
        progress(%{state | activity: %{wait | hands: hands}})
    end
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # Appends the assistant message of the stream so far and emits its
  # message_end. Returns it and its tool calls. No message goes between a
  # call and its result: the calls still open (only a connected turn has any
  # here) get their aborted results first, and a later result is dropped.
  defp close_assistant(state, stop_reason, usage) do
    state = state |> abort_turn_calls() |> start_assistant_message()
    assistant = Turn.assistant_message(state.activity, stop_reason: stop_reason, usage: usage)
    state = emit(append_message(state, assistant), :message_end, %{message: assistant})
    {state, assistant, for(%Message.ToolCall{} = call <- assistant.content, do: call)}
  end

  # Each call of the turn still open gets its `aborted` result: no message
  # goes between a call and its result.
  defp abort_turn_calls(%State{activity: %Turn{calls: calls}} = state) do
    state = put_in(state.activity.calls, [])
    Enum.reduce(calls, state, &record_result(&1, {:error, "aborted"}, &2))
  end

  defp run_tool(call, state),
    do: call |> run_on_hands(state) |> emit(:tool_execution_start, %{tool_call: call})

  # Runs a tool call on the hands. A Helyx tool request of a connected turn
  # runs this way with no event: the harness's own events show the call.
  defp run_on_hands(call, %State{activity: turn} = state) do
    case Turn.rejection(turn, call) do
      nil ->
        :ok = Hands.run(state.hands, turn.id, call)

      # The result takes the path of a result from the hands, so the events
      # and the order of the calls stay the same.
      reason ->
        send(self(), {:tool_result, turn.id, call.id, {:error, "tool call not run: " <> reason}})
    end

    state
  end

  # Appends the tool result message to the transcript and emits
  # tool_execution_end.
  defp record_result(call, result, state) do
    message = Message.tool_result(call, result)
    emit(append_message(state, message), :tool_execution_end, %{message: message})
  end

  # Appends a completed message to the transcript and, when the session has
  # a file, to disk. Streamed partial messages never come through here.
  defp append_message(%State{} = state, %Message{} = message) do
    state = persist(state, &Helyx.Session.File.append_message(&1, message))
    %{state | transcript: state.transcript ++ [message]}
  end

  defp persist(%State{file: nil} = state, _append), do: state

  defp persist(%State{file: file} = state, append) do
    %{state | file: append.(file)}
  rescue
    # A disk failure must not take the session down. The turn, or the model
    # switch, goes on in memory; persistence stays off for this session. Only
    # the disk write is caught: a value the file cannot encode is rejected
    # at the stream boundary (see `Helyx.Session.Stream`), and a model ref by
    # `ModelRef.parse/1`, so an encode error here is a
    # bug and crashes loudly rather than silently losing the rest of the
    # session. One notice tells the clients; its fixed text stays in the
    # bound of a notice, and the log has the error.
    error in File.Error ->
      Logger.warning("session file append failed, persistence off: " <> Exception.message(error))
      text = "the session file could not be written; the rest of this session is not saved"
      do_emit(%{state | file: nil}, turn_id(state.activity), :notice, %{text: text})
  end

  # Each tool call without a result gets an `aborted` error result in the
  # transcript, so the next provider call sees a complete pair.
  defp abort_open_calls(%State{} = state) do
    Enum.reduce(
      Transcript.open_calls(state.transcript),
      state,
      &record_result(&1, {:error, "aborted"}, &2)
    )
  end

  # A partial assistant message is closed with a failure stop reason so
  # clients do not keep it open. It is not added to the transcript.
  # A connected turn can fail after a message whose calls have no result yet.
  # A failed connected turn runs the turn cleanup of the hands before the
  # next turn: its prepare Task can still run.
  defp fail_turn(reason, %State{activity: turn} = state) do
    {wait, effects} = Wait.after_turn(turn, harness_pid(state), false)

    state =
      state
      |> steer_effects(effects)
      |> abort_open_calls()
      |> close_partial_message(:error, reason)
      |> drop_queues()
      |> emit(:agent_end, %{stop_reason: :error, error: reason})

    case turn.turn_mode do
      :connected ->
        hands = Hands.request_cancel(state.hands, turn.id)
        %{state | activity: %{wait | hands: hands}}

      :local ->
        settle(%{state | activity: :idle})
    end
  end

  defp close_partial_message(%State{activity: %Turn{partial: nil}} = state, _stop, _reason),
    do: state

  defp close_partial_message(state, stop_reason, reason) do
    emit(state, :message_end, %{
      message: Turn.assistant_message(state.activity, stop_reason: stop_reason),
      error: reason
    })
  end

  # Emits message_start for the assistant message on the first stream event.
  defp start_assistant_message(%State{activity: %Turn{partial: nil} = turn} = state) do
    state = %{state | activity: %{turn | partial: []}}
    emit(state, :message_start, %{message: Turn.assistant_message(state.activity, [])})
  end

  defp start_assistant_message(state), do: state

  # Only the queue drain at a normal turn end fires between turns; every
  # other emit with no turn is a bug and crashes here.
  defp emit(%State{activity: %Turn{id: turn_id}} = state, type, data),
    do: do_emit(state, turn_id, type, data)

  defp emit(%State{} = state, :queue_update, data),
    do: do_emit(state, nil, :queue_update, data)

  defp turn_id(%Turn{id: id}), do: id
  defp turn_id(_idle_or_wait), do: nil

  defp do_emit(state, turn_id, type, data) do
    seq = state.seq + 1

    event = %Event{
      type: type,
      session_id: state.id,
      instance_id: state.instance_id,
      turn_id: turn_id,
      seq: seq,
      data: data
    }

    for {pid, _ref} <- state.subscribers, do: send(pid, {:helyx_event, event})

    %{state | seq: seq}
  end

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
