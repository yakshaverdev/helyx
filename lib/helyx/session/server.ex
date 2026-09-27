defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks and the turn loop. The
  # client API and the docs of the behaviour are in `Helyx.Session`.

  use GenServer, restart: :temporary

  require Logger

  alias Helyx.{Context, Event, Message, ModelRef}
  alias Helyx.Session.{Hands, Harness, Id, Queues, Snapshot, Transcript, Turn}

  defmodule State do
    @moduledoc false
    @enforce_keys [:id, :core, :model, :provider, :turn_mode, :cwd]
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
      provider_pids: MapSet.new(),
      # The last harness session per harness provider id: its id and the
      # number of transcript messages before it started.
      harness_sessions: %{},
      # The harness process of a connected provider (ADR 0007), a
      # `%Connection{}`, or nil.
      harness: nil,
      # The bounds of the requests to the harness process, in ms: the
      # armed kills (see `Helyx.Session.Harness`). A seam for tests.
      harness_ms: %{turn: 2_000, interrupt: 2_000, close: 5_000},
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
    defstruct [:hands, :interrupt, :reply, :harness, callers: []]
  end

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
  def handle_call(:abort, from, %State{aborting: %Wait{callers: callers} = aborting} = state) do
    {:noreply, %{drop_queues(state) | aborting: %{aborting | callers: [from | callers]}}}
  end

  def handle_call({:prompt, _text}, _from, %State{turn: %Turn{}} = state) do
    {:reply, {:error, :turn_running}, state}
  end

  # A connected turn takes no steer yet (#202): the steer waits for the next
  # turn, as a follow-up.
  def handle_call({:steer, text}, _from, %State{turn: %Turn{turn_mode: :connected}} = state) do
    queue_reply(state, :follow_ups, text)
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

  def handle_call(:model, _from, %State{model: ref} = state) do
    {:reply, ModelRef.to_string(ref), state}
  end

  def handle_call({:set_model, %ModelRef{} = ref, provider, turn_mode}, _from, %State{} = state) do
    model = ModelRef.to_string(ref)
    file = persist(state.file, &Helyx.Session.File.append_model_change(&1, model))
    state = %{state | model: ref, provider: provider, turn_mode: turn_mode, file: file}
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

  def handle_info(
        {:stream_event, turn_id, {:harness_session, id, cut}},
        %State{turn: %Turn{id: turn_id} = turn} = state
      ) do
    # The provider id is the prefix of the turn's model ref: `find/2`
    # matched it, so the session runs no plugin code for it.
    provider = turn.model.provider
    file = persist(state.file, &Helyx.Session.File.append_harness_session(&1, provider, id))
    sessions = Map.put(state.harness_sessions, provider, {id, length(state.transcript)})
    state = %{state | file: file, harness_sessions: sessions}
    data = %{provider: provider, harness_session_id: id, lost: turn.resumed != nil, cut: cut}
    {:noreply, emit(state, :harness_session, data)}
  end

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
  def handle_info({ref, terminal}, %State{turn: %Turn{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, end_turn(terminal, state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{turn: %Turn{task: %Task{ref: ref}}} = state
      ) do
    {:noreply, fail_turn({:task_exit, Message.cap_integers(reason)}, state)}
  end

  # The terminal of an external turn's stream, from the hands after the release.
  def handle_info({:stream_end, turn_id, terminal}, %State{turn: %Turn{id: turn_id}} = state) do
    {:noreply, end_turn(terminal, state)}
  end

  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{
          turn: %Turn{id: turn_id, calls: [%Message.ToolCall{id: call_id} = call | rest]} = turn
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
    {:noreply, submit(%{state | harness: %{harness | ready: true}})}
  end

  # The prepare Task checked the context (`Stream.prepare_checked/4`): a
  # plugin that returned anything else fails the turn.
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
    {:noreply, %{state | turn: %{turn | pending: nil, phase: phase}}}
  end

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
        %State{aborting: %Wait{harness: pid} = aborting} = state
      ) do
    harness = if match?(%Connection{pid: ^pid}, state.harness), do: nil, else: state.harness
    aborting = %{aborting | harness: nil, reply: nil}
    {:noreply, progress(%{state | harness: harness, aborting: aborting})}
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
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}
  def handle_info({:stream_end, _turn_id, _terminal}, state), do: {:noreply, state}
  def handle_info({:rejected_call, _turn_id, _call, _reason}, state), do: {:noreply, state}

  # The hands are linked and vital: their death takes the session with it.
  def handle_info({:EXIT, pid, reason}, %State{hands: pid} = state) do
    {:stop, reason, state}
  end

  # A provider Task's exit signal is expected; its reply or :DOWN carries
  # the outcome. An exit from any other linked process, the sessions
  # Registry for example, is vital: a session that outlived its registration
  # would keep working where no client can reach it. A pid whose exit was
  # consumed by Task.shutdown on abort stays in the set, because a late exit
  # signal for it can still arrive; the set grows by one pid per abort.
  def handle_info({:EXIT, pid, reason}, %State{provider_pids: pids} = state) do
    if MapSet.member?(pids, pid) do
      {:noreply, %{state | provider_pids: MapSet.delete(pids, pid)}}
    else
      {:stop, reason, state}
    end
  end

  # The answer of the hands to the cancel request of an abort. The hands are
  # vital, so a request that fails because they died stops the session, like
  # their exit signal. Every other message has a clause above, so any other
  # message is a bug and crashes the session.
  def handle_info(message, %State{aborting: %Wait{hands: request} = aborting} = state)
      when request != nil do
    case :gen_server.check_response(message, request) do
      {:reply, result} ->
        with {:error, reason} <- result, do: Logger.warning("abort cleanup failed: " <> reason)
        {:noreply, progress(%{state | aborting: %{aborting | hands: nil}})}

      {:error, {reason, _hands}} ->
        {:stop, reason, state}
    end
  end

  # The session stops only for a trapped reason; on an untrappable kill the
  # link kills the provider Task, and the hands take the tool Tasks.
  @impl true
  def terminate(_reason, %State{turn: %Turn{task: %Task{} = task}}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  # A session that ends with no turn closes its harness process: end of
  # input, then the exit. The armed close kill bounds the wait, and a
  # harness process that is already gone gives its `:DOWN` at once.
  def terminate(_reason, %State{turn: nil, aborting: nil, harness: %Connection{pid: pid}} = state) do
    ref = Process.monitor(pid)
    Harness.request(pid, :close, state.harness_ms.close)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  def terminate(_reason, _state), do: :ok

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
    if turn.task, do: Task.shutdown(turn.task, :brutal_kill)
    request = Hands.request_cancel(state.hands, turn.id)

    state =
      state
      |> abort_open_calls()
      |> close_partial_message(:aborted, :aborted)
      |> queues.()
      |> emit(:agent_end, %{stop_reason: :aborted})
      |> close_turn()

    wait(state, %{hands: request, callers: callers, interrupt: interrupt(turn, state.harness)})
  end

  defp interrupt(%Turn{turn_mode: :connected, phase: phase, id: id}, %{pid: pid})
       when phase in [:submitting, :submitted],
       do: {pid, id}

  defp interrupt(_turn, _harness), do: nil

  # The session starts no turn until the wait ends: the answer of the
  # hands to `request_cancel/2` (`hands`), then the interrupt of a
  # connected turn (`interrupt`, `{pid, turn_id}`) with its answer
  # (`reply`), and the `:harness_down` of a harness process that ends
  # (`harness`). Every part is bounded: the hands by their release
  # deadlines, a harness process by the kill armed with its request.
  # `callers` are the abort callers, who get their reply at the end.
  defp wait(state, fields) do
    %{state | aborting: struct!(Wait, fields)}
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
         %State{aborting: %Wait{hands: nil, reply: nil, harness: nil, callers: callers}} = state
       ) do
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
      %State{aborting: nil} = state -> close_or_start(state)
      state -> state
    end
  end

  defp settle(state), do: state

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

    state = %{state | turn: turn}
    state = state |> emit(:agent_start, %{}) |> emit(:turn_start, %{})
    start_provider_call(Enum.reduce(texts, state, &append_user(&2, &1)))
  end

  defp append_user(state, text) do
    user = Message.user(text)

    append_message(state, user)
    |> emit(:message_start, %{message: user})
    |> emit(:message_end, %{message: user})
  end

  defp queue_reply(%State{} = state, key, text) do
    case Queues.push(state.queues, key, text) do
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
    case Queues.drain_steers(state.queues) do
      {[], _queues} ->
        call_provider(state)

      {steers, queues} ->
        Enum.reduce(steers, %{state | queues: queues}, &append_user(&2, &1))
        |> emit_queue()
        |> call_provider()
    end
  end

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
              Helyx.Session.Stream.prepare_checked(model_context, compaction, context, opts)

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
  # is prepared.
  defp submit(
         %State{
           turn: %Turn{phase: :preparing, context: context} = turn,
           harness: %Connection{pid: pid, ready: true}
         } = state
       )
       when context != nil do
    from = Harness.request(pid, {:turn, turn.id, context}, state.harness_ms.turn)
    %{state | turn: %{turn | phase: :submitting, pending: from, context: nil}}
  end

  defp submit(state), do: state

  # The Task is linked: the session traps exits, so a crash stays a message,
  # and a death of the session kills the stream.
  defp start_stream(:local, run, %State{turn: turn} = state) do
    task = Task.Supervisor.async(Helyx.Core.task_supervisor(state.core), run)

    %{
      state
      | turn: %{turn | task: task},
        provider_pids: MapSet.put(state.provider_pids, task.pid)
    }
  end

  # An external turn's stream is a Task of the hands (see the moduledoc).
  defp start_stream(:external, run, %State{turn: turn} = state) do
    :ok = Hands.stream(state.hands, turn.id, turn.provider, run)
    state
  end

  defp end_turn({:done, %{stop_reason: stop_reason, usage: usage}}, state) do
    {%State{turn: turn} = state, assistant, calls} = close_assistant(state, stop_reason, usage)

    case {calls, turn.turn_mode} do
      {[first | _], :local} ->
        run_tool(first, %{state | turn: %{turn | task: nil, partial: nil, calls: calls}})

      # A provider with an external turn ran its calls itself; one in the
      # last message gets no result.
      _no_calls_or_external ->
        state
        |> abort_open_calls()
        |> emit(:turn_end, %{message: assistant})
        |> emit(:agent_end, %{stop_reason: stop_reason})
        |> close_turn()
        |> settle()
    end
  end

  defp end_turn({:error, reason}, state), do: fail_turn(reason, state)
  defp end_turn(:stream_ended, state), do: fail_turn(:stream_ended, state)

  # Appends the assistant message of the stream so far and emits its
  # message_end. Returns it and its tool calls. No message goes between a
  # call and its result: the calls still open (only an external turn has any
  # here) get their aborted results first, and a later result is dropped.
  defp close_assistant(%State{turn: turn} = state, stop_reason, usage) do
    state = put_in(state.turn.calls, [])
    state = Enum.reduce(turn.calls, state, &record_result(&1, {:error, "aborted"}, &2))
    state = start_assistant_message(state)
    assistant = Turn.assistant_message(state.turn, stop_reason: stop_reason, usage: usage)
    state = emit(append_message(state, assistant), :message_end, %{message: assistant})
    {state, assistant, for(%Message.ToolCall{} = call <- assistant.content, do: call)}
  end

  defp run_tool(call, %State{turn: turn} = state) do
    case Turn.rejection(turn, call) do
      nil ->
        :ok = Hands.run(state.hands, turn.id, call)

      # The result takes the path of a result from the hands, so the events
      # and the order of the calls stay the same.
      reason ->
        send(self(), {:tool_result, turn.id, call.id, {:error, "tool call not run: " <> reason}})
    end

    emit(state, :tool_execution_start, %{tool_call: call})
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
    file = persist(state.file, &Helyx.Session.File.append_message(&1, message))
    %{state | transcript: state.transcript ++ [message], file: file}
  end

  defp persist(nil, _append), do: nil

  defp persist(file, append) do
    append.(file)
  rescue
    # A disk failure must not take the session down. The turn, or the model
    # switch, goes on in memory; persistence stays off for this session. Only
    # the disk write is caught: a value the file cannot encode is rejected
    # at the stream boundary (see `Helyx.Session.Stream`), and a model ref by
    # `ModelRef.parse/1`, so an encode error here is a
    # bug and crashes loudly rather than silently losing the rest of the
    # session.
    error in File.Error ->
      Logger.warning("session file append failed, persistence off: " <> Exception.message(error))
      nil
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
    state =
      state
      |> abort_open_calls()
      |> close_partial_message(:error, reason)
      |> drop_queues()
      |> emit(:agent_end, %{stop_reason: :error, error: reason})
      |> close_turn()

    case turn.turn_mode do
      :connected -> wait(state, %{hands: Hands.request_cancel(state.hands, turn.id)})
      _local_or_external -> settle(state)
    end
  end

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
