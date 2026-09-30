defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks and the turn loop. The
  # client API and the docs of the behaviour are in `Helyx.Session`.

  require Logger

  alias Helyx.{Context, Event, Message, ModelRef}
  alias Helyx.Session.{Hands, Harness, Id, Queues, Snapshot, Transcript, Turn}

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
      # The turn of `provider`, `:local` or `:external` (`Helyx.Provider.turn/1`),
      # or `:connected` for an external provider with `harness_init/3`.
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
      turn: nil,
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
      idle: nil,
      # The wait before the next turn can start, a `%Wait{}`, or nil (see
      # `wait/2`).
      aborting: nil
    ]
  end

  defmodule Connection do
    @moduledoc false
    # The harness process of a connected provider: its pid, the model it
    # runs, and whether `harness_init/3` returned (`{:harness_ready, pid}`).
    @enforce_keys [:pid, :model]
    defstruct [:pid, :model, ready: false]
  end

  defmodule Wait do
    @moduledoc false
    # The parts of the wait before the next turn can start (see `wait/2`).
    defstruct [:hands, :interrupt, :reply, :idle, :harness, :tool, callers: [], steers: %{}]
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

    state = %{state | hands: hands, instance_id: Id.new()}

    # A resumed transcript can end mid-turn, after a crash. Each open tool
    # call gets an `aborted` error result before anyone can subscribe, so
    # the next provider call sees complete call and result pairs.
    aborted =
      Enum.map(
        Transcript.open_calls(state.transcript),
        &Message.tool_result(&1, {:error, "aborted"})
      )

    {:ok, Enum.reduce(aborted, state, &append_message(&2, &1))}
  end

  # An abort waits for the hands. A turn that starts now could send a tool
  # call to the hands during their release, and that call would block the
  # session, so every message queues until the hands answer.
  @impl true
  def handle_call({:steer, text}, _from, %State{aborting: %Wait{}} = state) do
    queue_reply(state, :steers, text)
  end

  def handle_call({op, text}, _from, %State{aborting: %Wait{}} = state)
      when op in [:prompt, :follow_up] do
    queue_reply(state, :follow_ups, text)
  end

  # An abort drops the queues, like the abort that started the wait, so no
  # message sent before it starts a turn.
  # A steer that still waits for its answer gets its notice now: a late
  # `:rejected` must not queue it again after the abort.
  def handle_call(:abort, from, %State{aborting: %Wait{}} = state) do
    state = state |> drop_queues() |> drop_wait_steers()
    {:noreply, progress(update_in(state.aborting.callers, &[from | &1]))}
  end

  def handle_call({:prompt, _text}, _from, %State{turn: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  # A steer on a `submitted` connected turn goes to the harness process; in
  # `preparing` and `submitting` it stays in the local queue (see "Turn
  # states" in `docs/features/long-lived-harness.md`). A sent steer counts
  # in the 32 steers until its `user_message` and its answer (see `held/1`).
  def handle_call(
        {:steer, text},
        _from,
        %State{turn: %Turn{turn_mode: :connected, phase: :submitted}} = state
      ) do
    if Queues.steer_room?(state.queues, held(state)),
      do: {:reply, :ok, send_steer(text, state)},
      else: {:reply, {:error, :queue_full}, state}
  end

  def handle_call({:steer, text}, _from, %State{turn: %Turn{turn_mode: :connected}} = state) do
    queue_reply(state, :steers, text)
  end

  # An external turn takes no message inside its call: the steer aborts it,
  # and the queues start the next one when the hands answer.
  def handle_call({:steer, text}, _from, %State{turn: %Turn{} = turn} = state) do
    case {queue_reply(state, :steers, text), turn.turn_mode} do
      {{:reply, :ok, state}, :external} -> {:reply, :ok, abort_turn(state, [], & &1)}
      {reply, _turn_mode} -> reply
    end
  end

  def handle_call({:follow_up, text}, _from, %State{turn: %Turn{}} = state) do
    queue_reply(state, :follow_ups, text)
  end

  # A harness process that ended while the session was idle can still have
  # its handles in a release of the hands: the message waits for its
  # `:harness_down` as a follow-up.
  def handle_call({op, text}, _from, %State{} = state)
      when op in [:prompt, :steer, :follow_up] do
    case await_ended_harness(state) do
      %State{aborting: nil} = state -> {:reply, :ok, begin_turn(state, [text])}
      state -> queue_reply(state, :follow_ups, text)
    end
  end

  def handle_call({:snapshot}, _from, %State{} = state) do
    snapshot = %Snapshot{
      instance_id: state.instance_id,
      seq: state.seq,
      messages: state.transcript,
      turn: snapshot_turn(state.turn),
      model: ModelRef.to_string(state.model),
      queue: Queues.counts(state.queues)
    }

    {:reply, snapshot, state}
  end

  def handle_call({:set_model, %ModelRef{} = ref, provider, turn_mode}, _from, %State{} = state) do
    model = ModelRef.to_string(ref)
    state = persist(state, &Helyx.Session.File.append_model_change(&1, model))
    state = %{state | model: ref, provider: provider, turn_mode: turn_mode}
    {:reply, :ok, settle(do_emit(state, nil, :model_change, %{model: model}))}
  end

  def handle_call(:abort, _from, %State{turn: nil} = state), do: {:reply, :ok, state}

  # The release of the hands can take longer than the timeout of a client call
  # (issue #93), so the session does not wait in a call: the answer of the
  # hands arrives as a message, and the abort callers get their reply then.
  def handle_call(:abort, from, %State{turn: %Turn{}} = state) do
    {:noreply, abort_turn(state, [from], &drop_queues/1)}
  end

  @impl true
  def handle_info(
        {:stream_event, turn_id, {:message_end, stop_reason, usage}},
        %State{turn: %Turn{id: turn_id}} = state
      ) do
    {state, _assistant, calls} = close_assistant(state, stop_reason, usage)
    state = Enum.reduce(calls, state, &emit(&2, :tool_execution_start, %{tool_call: &1}))
    %State{turn: turn} = state
    {:noreply, %{state | turn: %{turn | partial: nil, calls: calls}}}
  end

  # A result for a call of no completed message, or for a call that a
  # later message already closed, is dropped. A result goes
  # to the first open call with its id, the rule of `open_calls/1`, so the
  # transcript, the file, and the replay agree.
  def handle_info(
        {:stream_event, turn_id, {:tool_result, call_id, result}},
        %State{turn: %Turn{id: turn_id} = turn} = state
      ) do
    case Enum.find(turn.calls, &(&1.id == call_id)) do
      nil ->
        {:noreply, state}

      call ->
        state = %{state | turn: %{turn | calls: List.delete(turn.calls, call)}}
        {:noreply, record_result(call, result, state)}
    end
  end

  # The harness took a steer of this turn: its text, the one the session
  # checked at the client call, joins the transcript here. A steer id that
  # is not open (unknown, or taken already) is dropped. A taken steer with
  # no answer yet stays, with a nil text, until its answer: no turn starts
  # while a steer request is open.
  def handle_info(
        {:stream_event, turn_id, {:user_message, steer_id, _text}},
        %State{turn: %Turn{id: turn_id} = turn} = state
      ) do
    case List.keyfind(turn.steers, steer_id, 0) do
      {^steer_id, text, :answered} ->
        steers = List.keydelete(turn.steers, steer_id, 0)
        {:noreply, take_steer(put_in(state.turn.steers, steers), text)}

      {^steer_id, text, from} when is_binary(text) ->
        steers = List.keyreplace(turn.steers, steer_id, 0, {steer_id, nil, from})
        {:noreply, take_steer(put_in(state.turn.steers, steers), text)}

      _unknown_or_taken ->
        {:noreply, state}
    end
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
          turn: %Turn{id: turn_id, turn_mode: :connected} = turn,
          harness: %Connection{pid: pid}
        } = state
      ) do
    call = %Message.ToolCall{id: id, name: name, arguments: args}
    from = Harness.request(pid, {:tool_start, turn_id, id}, state.harness_ms.tool_start)
    turn = %{turn | tool: call, start: from, results: [from | turn.results]}
    {:noreply, %{state | turn: turn}}
  end

  # The loop's answer to the ask: only `:ok` runs the call. A missed
  # deadline stops the harness process, and its `:harness_down` fails the
  # turn; an answer after the turn goes to the wait after the turn.
  def handle_info(
        {:harness_reply, from, reply},
        %State{turn: %Turn{start: from, tool: call} = turn} = state
      ) do
    state = %{state | turn: %{turn | start: nil, results: List.delete(turn.results, from)}}

    {:noreply,
     if(reply == :ok, do: run_harness_tool(call, state), else: put_in(state.turn.tool, nil))}
  end

  # The harness withdrew a tool request: a running one is killed, and its
  # result, which the hands still send, is dropped by the loop.
  def handle_info(
        {:cancel_tool, turn_id, call_id},
        %State{turn: %Turn{id: turn_id, tool: %{id: call_id}}} = state
      ) do
    Hands.kill(state.hands, turn_id, call_id)
    {:noreply, state}
  end

  # Only a connected turn runs Helyx tools for the harness.
  def handle_info({:stream_event, _turn_id, {:tool_request, _, _, _}}, state),
    do: {:noreply, state}

  def handle_info(
        {:stream_event, turn_id, {:harness_session, id, cut}},
        %State{turn: %Turn{id: turn_id} = turn} = state
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
        %State{turn: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, emit(state, :notice, %{text: text})}

  # A turn that the program started by itself (#240) opens only with no
  # turn and no wait: a submitted connected turn with no user message. Any
  # other time it is dropped, and so are its events.
  def handle_info(
        {:stream_event, turn_id, :program_turn},
        %State{turn: nil, aborting: nil, harness: %Connection{ready: true, model: model}} = state
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

  def handle_info({:stream_event, turn_id, event}, %State{turn: %Turn{id: turn_id}} = state) do
    %State{turn: turn} = state = start_assistant_message(state)

    {:noreply,
     %{state | turn: Turn.add_block(turn, event)}
     |> emit(:message_update, Map.new([event]))}
  end

  # Arrives before the stream event of the call it names (see
  # `Helyx.Session.Stream`).
  def handle_info(
        {:rejected_call, turn_id, call, reason},
        %State{turn: %Turn{id: turn_id} = turn} = state
      ) do
    {:noreply, %{state | turn: Turn.reject(turn, call, reason)}}
  end

  # The Task's reply is the terminal stream event. Its :DOWN follows and is
  # flushed here, so a :DOWN only reaches the session when the Task crashed.
  # The Task is linked, so its exit signal follows the reply too; it is
  # taken here, so it never reaches the vital :EXIT clause.
  def handle_info({ref, terminal}, %State{turn: %Turn{task: %Task{ref: ref, pid: pid}}} = state) do
    Process.demonitor(ref, [:flush])
    receive do: ({:EXIT, ^pid, _} -> :ok)
    {:noreply, end_turn(terminal, state)}
  end

  # A crashed Task gives both its :DOWN and its exit signal, in either
  # order. The first one fails the turn, and the other one is taken here.
  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %State{turn: %Turn{task: %Task{ref: ref}}} = state
      ) do
    receive do: ({:EXIT, ^pid, _} -> :ok)
    {:noreply, fail_turn({:task_exit, Message.cap_integers(reason)}, state)}
  end

  def handle_info(
        {:EXIT, pid, reason},
        %State{turn: %Turn{task: %Task{ref: ref, pid: pid}}} = state
      ) do
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    {:noreply, fail_turn({:task_exit, Message.cap_integers(reason)}, state)}
  end

  # The terminal of an external turn's stream, from the hands after the release.
  def handle_info({:stream_end, turn_id, terminal}, %State{turn: %Turn{id: turn_id}} = state) do
    {:noreply, end_turn(terminal, state)}
  end

  # The result of a Helyx tool of a connected turn goes to the harness
  # process, with the tool result bound. Its answer is awaited, as a steer's
  # is, so no turn starts while its kill is armed.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{
          turn: %Turn{id: turn_id, turn_mode: :connected, tool: %{id: call_id}} = turn,
          harness: %Connection{pid: pid}
        } = state
      ) do
    from =
      Harness.request(pid, {:tool_result, turn_id, call_id, result}, state.harness_ms.tool_result)

    {:noreply, %{state | turn: %{turn | tool: nil, results: [from | turn.results]}}}
  end

  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{
          turn:
            %Turn{
              id: turn_id,
              turn_mode: :local,
              calls: [%Message.ToolCall{id: call_id} = call | rest]
            } =
              turn
        } =
          state
      ) do
    state = record_result(call, result, %{state | turn: %{turn | calls: rest}})

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
        %State{turn: %Turn{id: turn_id, phase: :preparing} = turn} = state
      ) do
    {:noreply, submit(%{state | turn: %{turn | context: context}})}
  end

  def handle_info(
        {:prepared, turn_id, {:error, reason}},
        %State{turn: %Turn{id: turn_id, phase: :preparing}} = state
      ) do
    {:noreply, fail_turn(reason, state)}
  end

  def handle_info(
        {:prepare_failed, turn_id, reason},
        %State{turn: %Turn{id: turn_id, phase: :preparing}} = state
      ) do
    {:noreply, fail_turn({:task_exit, reason}, state)}
  end

  # An answer other than `:ok` ends the harness process, and its
  # `:harness_down` fails the turn.
  def handle_info(
        {:harness_reply, from, reply},
        %State{turn: %Turn{pending: from} = turn} = state
      ) do
    phase = if reply == :ok, do: :submitted, else: :submitting
    state = %{state | turn: %{turn | pending: nil, phase: phase}}
    {:noreply, if(reply == :ok, do: send_local_steers(state), else: state)}
  end

  # The answer to a steer of the turn (see "Steer" in
  # `docs/features/long-lived-harness.md`). `:rejected` is confirmed: the
  # steer goes to the local queue for the next turn. Any other answer
  # waits for the `user_message`, or ends in a notice. A reply to no steer
  # answers a tool result of the turn: it was written.
  def handle_info(
        {:harness_reply, from, reply},
        %State{turn: %Turn{turn_mode: :connected} = turn} = state
      ) do
    case List.keytake(turn.steers, from, 2) do
      {{_steer_id, nil, ^from}, steers} ->
        {:noreply, put_in(state.turn.steers, steers)}

      {{_steer_id, text, ^from}, steers} when reply == :rejected ->
        {:noreply, requeue_steer(put_in(state.turn.steers, steers), text)}

      {{steer_id, text, ^from}, _steers} ->
        steers = List.keyreplace(turn.steers, steer_id, 0, {steer_id, text, :answered})
        {:noreply, put_in(state.turn.steers, steers)}

      nil ->
        {:noreply, put_in(state.turn.results, List.delete(turn.results, from))}
    end
  end

  # The answer to an idle close. `:ok`: the program exited, and the wait
  # goes on until its `:harness_down`. `:busy`: the program stays, and the
  # wait ends, which arms the timer again.
  def handle_info(
        {:harness_reply, from, reply},
        %State{aborting: %Wait{idle: from} = aborting} = state
      ) do
    aborting = if reply == :busy, do: %{aborting | harness: nil}, else: aborting
    {:noreply, progress(%{state | aborting: %{aborting | idle: nil}})}
  end

  # The answer to an open steer request of the wait (see `end_steers/2`).
  # After a normal end, `:rejected` queues the steer for the next turn, and
  # any other answer is a notice, because the turn ended with no
  # `user_message`. A nil text (taken, or noticed at an abort or a failure)
  # only ends the wait.
  def handle_info(
        {:harness_reply, from, reply},
        %State{aborting: %Wait{steers: steers} = aborting} = state
      )
      when is_map_key(steers, from) do
    {{turn_id, text}, steers} = Map.pop!(steers, from)
    state = %{state | aborting: %{aborting | steers: steers}}

    state =
      if reply == :rejected and text != nil,
        do: requeue_steer(state, text),
        else: notice(state, turn_id, text)

    {:noreply, progress(state)}
  end

  # The idle timer of the harness process. Only the current timer counts,
  # and only while the session is idle: a turn or a wait since it was armed
  # makes it old. The wait holds every message until the answer.
  def handle_info(
        {:timeout, ref, :idle_close},
        %State{idle: ref, turn: nil, aborting: nil, harness: %Connection{pid: pid, ready: true}} =
          state
      ) do
    from = Harness.request(pid, :idle_close, state.harness_ms.close)
    {:noreply, wait(%{state | idle: nil}, %{idle: from, harness: pid})}
  end

  def handle_info({:timeout, _ref, :idle_close}, state), do: {:noreply, state}

  # The answer to the interrupt of an abort. `:ok` keeps the harness
  # process; any other answer ends it, and the wait goes on until its
  # `:harness_down`.
  def handle_info(
        {:harness_reply, from, reply},
        %State{aborting: %Wait{reply: from} = aborting} = state
      ) do
    harness = if reply == :ok, do: nil, else: aborting.harness
    aborting = %{aborting | reply: nil, harness: harness}

    {:noreply, progress(%{state | aborting: aborting})}
  end

  # From the hands, after the release of the harness process's handles.
  def handle_info(
        {:harness_down, pid, _reason},
        %State{aborting: %Wait{harness: pid}} = state
      ) do
    harness = if match?(%Connection{pid: ^pid}, state.harness), do: nil, else: state.harness
    %State{aborting: aborting} = state = end_wait_steers(state)
    aborting = %{aborting | harness: nil, reply: nil}
    {:noreply, progress(%{state | harness: harness, aborting: aborting})}
  end

  # The harness process ended before it answered the steers of a turn that
  # ended: they are unknown.
  def handle_info(
        {:harness_down, pid, _reason},
        %State{harness: %Connection{pid: pid}, aborting: %Wait{steers: steers}} = state
      )
      when map_size(steers) > 0 do
    {:noreply, progress(%{end_wait_steers(state) | harness: nil})}
  end

  def handle_info(
        {:harness_down, pid, reason},
        %State{harness: %Connection{pid: pid}, turn: %Turn{turn_mode: :connected}} = state
      ) do
    {:noreply, fail_turn(reason, %{state | harness: nil})}
  end

  def handle_info({:harness_down, pid, _reason}, %State{harness: %Connection{pid: pid}} = state) do
    {:noreply, %{state | harness: nil}}
  end

  # A message for a turn, a call, or a harness process that is no longer
  # current, or a reply that nobody waits for.
  def handle_info({:harness_ready, _pid}, state), do: {:noreply, state}
  def handle_info({:harness_reply, _from, _reply}, state), do: {:noreply, state}
  def handle_info({:harness_down, _pid, _reason}, state), do: {:noreply, state}
  def handle_info({:prepared, _turn_id, _result}, state), do: {:noreply, state}
  def handle_info({:prepare_failed, _turn_id, _reason}, state), do: {:noreply, state}
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:cancel_tool, _turn_id, _call_id}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}
  def handle_info({:stream_end, _turn_id, _terminal}, state), do: {:noreply, state}
  def handle_info({:rejected_call, _turn_id, _call, _reason}, state), do: {:noreply, state}

  # The hands are linked and vital: their death takes the session with it.
  def handle_info({:EXIT, pid, reason}, %State{hands: pid} = state) do
    {:stop, reason, state}
  end

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
  def handle_info(message, %State{aborting: %Wait{hands: request} = aborting} = state)
      when request != nil do
    case :gen_server.check_response(message, request) do
      {:reply, result} ->
        state = cleanup_notice(result, state)
        {:noreply, progress(%{state | aborting: %{aborting | hands: nil}})}

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

  defp end_work(%State{turn: %Turn{task: %Task{} = task}}), do: Task.shutdown(task, :brutal_kill)

  # A session that ends with no turn closes its harness processes: the
  # current one and the one its wait is for (an idle close, a switch
  # close, an abort). Each gets a close, end of input then the exit, after
  # any request it has open: a `:busy` answer to an idle close does not
  # keep it. The armed close kills bound the waits, which run in parallel,
  # and a harness process that is already gone gives its `:DOWN` at once.
  defp end_work(%State{turn: nil, harness: harness, aborting: aborting} = state) do
    pids = [harness && harness.pid, aborting && aborting.harness]

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

  defp end_work(_state), do: :ok

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

  defp snapshot_turn(nil), do: nil

  defp snapshot_turn(%Turn{} = turn) do
    partial = if turn.partial, do: Turn.assistant_message(turn, [])
    %{id: turn.id, partial: partial, running: Enum.map(started_calls(turn), & &1.id)}
  end

  # The calls that have had their `tool_execution_start`: a local turn runs
  # its calls one at a time, the head first; an external turn started them
  # all at its message end.
  defp started_calls(%Turn{turn_mode: :local, calls: [head | _]}), do: [head]
  defp started_calls(%Turn{turn_mode: :local, calls: []}), do: []
  defp started_calls(%Turn{calls: calls}), do: calls

  # Turn machinery

  # Ends the turn at once and asks the hands to release its resources; the
  # `callers` get their reply when the wait ends. `queues` drops the
  # queues for an abort and keeps them for the steer of an external turn.
  # A connected turn that sent `{:turn, ...}` also gets an interrupt, after
  # the hands answer.
  defp abort_turn(%State{turn: turn} = state, callers, queues) do
    if turn.task, do: shutdown_stream(turn.task)
    request = Hands.request_cancel(state.hands, turn.id)
    {state, open} = end_steers(state, false)

    state =
      state
      |> abort_open_calls()
      |> close_partial_message(:aborted, :aborted)
      |> queues.()
      |> emit(:agent_end, %{stop_reason: :aborted})
      |> close_turn()

    wait(state, %{
      hands: request,
      tool: wait_tool(turn),
      callers: callers,
      interrupt: interrupt(turn, state.harness),
      steers: open
    })
  end

  defp interrupt(%Turn{turn_mode: :connected, phase: phase, id: id}, %{pid: pid})
       when phase in [:submitting, :submitted],
       do: {pid, id}

  defp interrupt(_turn, _harness), do: nil

  # The session starts no turn until the wait ends: the answer of the
  # hands to `request_cancel/2` (`hands`), then the interrupt of a
  # connected turn (`interrupt`, `{pid, turn_id}`) with its answer
  # (`reply`), the answer to an idle close (`idle`), the answers to the
  # open steer requests of the turn that ended (`steers`, `from` to
  # `{turn_id, text}`, see `end_steers/2`), and the `:harness_down` of a harness process that
  # ends (`harness`). Every part is bounded: the hands by their release
  # deadlines, a harness process by the kill armed with its request (a
  # steer by the steer bound).
  # `callers` are the abort callers, who get their reply at the end.
  defp wait(state, fields) do
    %{state | aborting: struct!(Wait, fields)}
  end

  # The hands killed the Helyx tool of the turn, so its result is
  # `aborted`: the answer comes after the kill and before the interrupt.
  # The loop writes it only for a call that it confirmed at the ask, also
  # after the turn; it answered any other call itself. Its request waits as
  # an open steer request does.
  defp progress(%State{aborting: %Wait{hands: nil, tool: {turn_id, call_id}} = aborting} = state) do
    steers =
      case state.harness do
        %Connection{pid: pid} ->
          request = {:tool_result, turn_id, call_id, {:error, "aborted"}}
          from = Harness.request(pid, request, state.harness_ms.tool_result)
          Map.put(aborting.steers, from, {turn_id, nil})

        nil ->
          aborting.steers
      end

    progress(%{state | aborting: %{aborting | tool: nil, steers: steers}})
  end

  defp progress(%State{aborting: %Wait{hands: nil, interrupt: {pid, turn_id}} = aborting} = state) do
    aborting =
      case state.harness do
        %Connection{pid: ^pid} ->
          from = Harness.request(pid, {:interrupt, turn_id}, state.harness_ms.interrupt)
          %{aborting | interrupt: nil, reply: from, harness: pid}

        # The harness process ended before the hands answered.
        _gone ->
          %{aborting | interrupt: nil}
      end

    progress(%{state | aborting: aborting})
  end

  defp progress(
         %State{
           aborting: %Wait{hands: nil, reply: nil, harness: nil, callers: callers, steers: steers}
         } = state
       )
       when map_size(steers) == 0 do
    Enum.each(callers, &GenServer.reply(&1, :ok))
    settle(%{state | aborting: nil})
  end

  defp progress(state), do: state

  # With no turn and no wait, a harness process that ended is waited for
  # (its `:harness_down`), and one of another model than the session's
  # closes before the next turn starts (a provider or a model switch);
  # otherwise the queues start the next turn.
  defp settle(%State{turn: nil, aborting: nil} = state) do
    case await_ended_harness(state) do
      %State{aborting: nil} = state -> arm_idle(close_or_start(state))
      state -> state
    end
  end

  defp settle(state), do: state

  # Arms the idle timer when the session holds a ready harness process
  # with no turn and no wait. It cancels the earlier timer; a message of
  # it that is already in the mailbox has an old ref.
  defp arm_idle(%State{turn: nil, aborting: nil, harness: %Connection{ready: true}} = state) do
    if state.idle, do: :erlang.cancel_timer(state.idle)
    %{state | idle: :erlang.start_timer(state.harness_ms.idle, self(), :idle_close)}
  end

  defp arm_idle(state), do: state

  defp close_or_start(%State{model: model, harness: %Connection{pid: pid, model: other}} = state)
       when other != model do
    Harness.request(pid, :close, state.harness_ms.close)
    wait(%{state | harness: nil}, %{harness: pid})
  end

  defp close_or_start(state), do: start_queued(state)

  # The hands send `:harness_down` only after the release of the harness
  # process's handles, so a turn does not start on a harness process that
  # ended until then: the session waits for it. A harness process that
  # ends after this check ends during the turn, and its `:harness_down`
  # fails the turn (see `Hands.prepare/3`).
  defp await_ended_harness(%State{harness: %Connection{pid: pid}} = state) do
    if Process.alive?(pid), do: state, else: wait(%{state | harness: nil}, %{harness: pid})
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
    do: %{state | turn: turn} |> emit(:agent_start, %{}) |> emit(:turn_start, data)

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

  # The steers that wait for their answer after their turn get their
  # notice now, and a nil text: the wait still holds each open request
  # until its answer, but a late `:rejected` no longer queues it.
  defp drop_wait_steers(%State{aborting: %Wait{steers: steers} = aborting} = state) do
    state =
      Enum.reduce(steers, state, fn {_from, {turn_id, text}}, state ->
        notice(state, turn_id, text)
      end)

    steers = Map.new(steers, fn {from, {turn_id, _text}} -> {from, {turn_id, nil}} end)
    %{state | aborting: %{aborting | steers: steers}}
  end

  # The harness process ended: no open steer request is left.
  defp end_wait_steers(state) do
    %State{aborting: aborting} = state = drop_wait_steers(state)
    %{state | aborting: %{aborting | steers: %{}}}
  end

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
  defp held(%State{turn: %Turn{steers: steers}}), do: length(steers)
  defp held(%State{aborting: %Wait{steers: steers}}), do: map_size(steers)
  defp held(_state), do: 0

  # Sends a steer to the harness process with its own id and the steer
  # bound (see `Helyx.Session.Harness`).
  defp send_steer(text, %State{turn: turn, harness: %Connection{pid: pid}} = state) do
    steer_id = Id.new()
    from = Harness.request(pid, {:steer, turn.id, steer_id, text}, state.harness_ms.steer)
    %{state | turn: %{turn | steers: turn.steers ++ [{steer_id, text, from}]}}
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
  defp take_steer(%State{turn: %Turn{partial: nil}} = state, text),
    do: state |> abort_turn_calls() |> append_user(text)

  defp take_steer(%State{turn: %Turn{partial: partial}} = state, text) do
    stop = if Enum.any?(partial, &match?(%Message.ToolCall{}, &1)), do: :tool_use, else: :end_turn
    {state, _assistant, calls} = close_assistant(state, stop, %{})
    take_steer(%{state | turn: %{state.turn | partial: nil, calls: calls}}, text)
  end

  # At the end of a turn, each steer with no `user_message` gets a notice,
  # except, at a normal end (`normal?`), one with no answer yet. Every
  # steer request that is still open goes to the wait after the turn, by
  # its `from`: no turn starts while its armed kill can fire. After an
  # abort or a failure its text is nil, so its answer only ends the wait.
  # With the harness process gone (a failure at its `:harness_down`), no
  # request is open any more.
  defp end_steers(%State{turn: turn} = state, normal?) do
    {state, open} =
      Enum.reduce(turn.steers, {state, %{}}, fn
        {_id, text, from}, {state, open} when is_reference(from) and normal? ->
          {state, Map.put(open, from, {turn.id, text})}

        {_id, text, from}, {state, open} when is_reference(from) ->
          {notice(state, turn.id, text), Map.put(open, from, {turn.id, nil})}

        {_id, text, :answered}, {state, open} ->
          {notice(state, turn.id, text), open}
      end)

    open = Enum.reduce(turn.results, open, &Map.put(&2, &1, {turn.id, nil}))
    {state, if(state.harness, do: open, else: %{})}
  end

  # The notice of a steer with no `user_message`. A taken steer (nil text)
  # waited only for its answer, so it gets none.
  defp notice(state, _turn_id, nil), do: state

  defp notice(state, turn_id, text),
    do: do_emit(state, turn_id, :steer_unconfirmed, %{text: text})

  # A connected turn: the harness process (started at the first connected
  # turn) and a prepare Task of the hands, which builds the context.
  defp call_provider(%State{turn: %Turn{turn_mode: :connected}} = state) do
    case connect(state) do
      {:ok, %State{turn: turn} = state} ->
        session = self()
        turn_id = turn.id
        %State{model_context: model_context, compaction: compaction} = state
        context = %Context{messages: state.transcript, tools: state.tools}
        opts = [core: state.core, session_id: state.id, turn_id: turn_id, cwd: state.cwd]

        :ok =
          Hands.prepare(state.hands, turn_id, fn tref ->
            result =
              Helyx.Session.Stream.prepare(model_context, compaction, context, opts)

            :timer.cancel(tref)
            send(session, {:prepared, turn_id, result})
          end)

        %{state | turn: %{turn | phase: :preparing}}

      {:error, text} ->
        fail_turn(text, state)
    end
  end

  defp call_provider(%State{turn: %Turn{id: turn_id} = turn} = state) do
    external? = turn.turn_mode == :external

    resumed =
      if external?,
        do: Transcript.resumable(state.transcript, state.harness_sessions, turn.model.provider)

    opts = [core: state.core, session_id: state.id, turn_id: turn_id, cwd: state.cwd]
    opts = if external?, do: opts ++ [harness_session_id: resumed], else: opts

    args = %{
      model_context: state.model_context,
      compaction: state.compaction,
      provider: turn.provider,
      model: turn.model.model,
      context: %Context{messages: state.transcript, tools: state.tools},
      opts: opts,
      session: self(),
      turn_id: turn_id,
      external?: external?
    }

    run = fn -> Helyx.Session.Stream.run(args) end

    start_stream(turn.turn_mode, run, %{state | turn: %{turn | rejected: %{}, resumed: resumed}})
  end

  # `settle/1` closed a harness process of another model before the turn.
  defp connect(%State{harness: %Connection{model: model}, turn: %Turn{model: model}} = state),
    do: {:ok, state}

  defp connect(%State{harness: nil, turn: turn} = state) do
    resumed = Transcript.resumable(state.transcript, state.harness_sessions, turn.model.provider)

    args = %{
      provider: turn.provider,
      model: turn.model.model,
      tools: state.tools,
      opts: [core: state.core, session_id: state.id, cwd: state.cwd, harness_session_id: resumed],
      session: self()
    }

    with {:ok, pid} <- Hands.connect(state.hands, turn.provider, &Harness.run(args, &1)) do
      harness = %Connection{pid: pid, model: turn.model}
      {:ok, %{state | harness: harness, turn: %{turn | resumed: resumed}}}
    end
  end

  # Sends `{:turn, ...}` when the harness process is ready and the context
  # is prepared. The steers queued in `preparing` join the transcript and
  # the end of the context: they are part of the prompt, not steers.
  defp submit(
         %State{
           turn: %Turn{phase: :preparing, context: context},
           harness: %Connection{pid: pid, ready: true}
         } = state
       )
       when context != nil do
    {steers, %State{turn: turn} = state} = append_steers(state)
    context = %{context | messages: context.messages ++ Enum.map(steers, &Message.user/1)}
    from = Harness.request(pid, {:turn, turn.id, context}, state.harness_ms.turn)
    %{state | turn: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  defp submit(state), do: state

  # The Task is linked: the session traps exits, so a crash stays a message,
  # and a death of the session kills the stream.
  defp start_stream(:local, run, %State{turn: turn} = state) do
    task = Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), run)

    %{state | turn: %{turn | task: task}}
  end

  # An external turn's stream is a Task of the hands (see the moduledoc).
  defp start_stream(:external, run, %State{turn: turn} = state) do
    :ok = Hands.stream(state.hands, turn.id, turn.provider, run)
    state
  end

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
    {%State{turn: turn} = state, assistant, calls} = close_assistant(state, stop_reason, usage)

    case {calls, turn.turn_mode} do
      {[first | _], :local} ->
        run_tool(first, %{state | turn: %{turn | task: nil, partial: nil, calls: calls}})

      # A provider with an external turn ran its calls itself; one in the
      # last message gets no result.
      # A steer with no answer yet can still be rejected: the session
      # waits for its answer before the next turn.
      _no_calls_or_external ->
        {state, open} = state |> abort_open_calls() |> end_steers(true)

        state =
          state
          |> emit(:turn_end, %{message: assistant})
          |> emit(:agent_end, %{stop_reason: stop_reason})
          |> close_turn()

        # A Helyx tool that still runs: the turn cleanup of the hands
        # runs before the next turn.
        hands = if turn.tool, do: Hands.request_cancel(state.hands, turn.id)

        if open == %{} and hands == nil,
          do: settle(state),
          else: wait(state, %{steers: open, hands: hands, tool: wait_tool(turn)})
    end
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # Appends the assistant message of the stream so far and emits its
  # message_end. Returns it and its tool calls. No message goes between a
  # call and its result: the calls still open (only an external turn has any
  # here) get their aborted results first, and a later result is dropped.
  defp close_assistant(state, stop_reason, usage) do
    state = state |> abort_turn_calls() |> start_assistant_message()
    assistant = Turn.assistant_message(state.turn, stop_reason: stop_reason, usage: usage)
    state = emit(append_message(state, assistant), :message_end, %{message: assistant})
    {state, assistant, for(%Message.ToolCall{} = call <- assistant.content, do: call)}
  end

  # Each call of the turn still open gets its `aborted` result: no message
  # goes between a call and its result.
  defp abort_turn_calls(%State{turn: %Turn{calls: calls}} = state) do
    state = put_in(state.turn.calls, [])
    Enum.reduce(calls, state, &record_result(&1, {:error, "aborted"}, &2))
  end

  defp run_tool(call, state),
    do: call |> run_harness_tool(state) |> emit(:tool_execution_start, %{tool_call: call})

  # Runs a tool call on the hands. A Helyx tool request of a connected turn
  # runs this way with no event: the harness's own events show the call.
  defp run_harness_tool(call, %State{turn: turn} = state) do
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
      do_emit(%{state | file: nil}, state.turn && state.turn.id, :notice, %{text: text})
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
  # An external turn can fail after a message whose calls have no result yet.
  # A failed connected turn runs the turn cleanup of the hands before the
  # next turn: its prepare Task can still run.
  defp fail_turn(reason, %State{turn: turn} = state) do
    {state, open} = end_steers(state, false)

    state =
      state
      |> abort_open_calls()
      |> close_partial_message(:error, reason)
      |> drop_queues()
      |> emit(:agent_end, %{stop_reason: :error, error: reason})
      |> close_turn()

    case turn.turn_mode do
      :connected ->
        hands = Hands.request_cancel(state.hands, turn.id)
        wait(state, %{hands: hands, steers: open, tool: wait_tool(turn)})

      _local_or_external ->
        settle(state)
    end
  end

  # The Helyx tool of a connected turn that ends, for the wait (`tool`).
  defp wait_tool(%Turn{tool: %{id: id}, id: turn_id}), do: {turn_id, id}
  defp wait_tool(_turn), do: nil

  defp close_partial_message(%State{turn: %Turn{partial: nil}} = state, _stop, _reason), do: state

  defp close_partial_message(state, stop_reason, reason) do
    emit(state, :message_end, %{
      message: Turn.assistant_message(state.turn, stop_reason: stop_reason),
      error: reason
    })
  end

  defp close_turn(%State{} = state), do: %{state | turn: nil}

  # Emits message_start for the assistant message on the first stream event.
  defp start_assistant_message(%State{turn: %Turn{partial: nil} = turn} = state) do
    state = %{state | turn: %{turn | partial: []}}
    emit(state, :message_start, %{message: Turn.assistant_message(state.turn, [])})
  end

  defp start_assistant_message(state), do: state

  # Only the queue drain at a normal turn end fires between turns; every
  # other emit with no turn is a bug and crashes here.
  defp emit(%State{turn: nil} = state, :queue_update, data),
    do: do_emit(state, nil, :queue_update, data)

  defp emit(%State{turn: %Turn{id: turn_id}} = state, type, data),
    do: do_emit(state, turn_id, type, data)

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

    Registry.dispatch(Helyx.Core.events_registry(state.core), state.id, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:helyx_event, event})
    end)

    %{state | seq: seq}
  end

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
