defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks. The turn lifecycle, with
  # the match of each lifecycle input to the current activity, is in
  # `Helyx.Session.Server.TurnLoop`; the callbacks here forward those
  # inputs and match the records of the current turn. The client API and
  # the docs of the behaviour are in `Helyx.Session`.

  alias Helyx.ModelRef
  alias Helyx.Session.{Hands, Id, Queue, Snapshot, Transcript, Turn}
  alias Helyx.Session.Server.{Messages, Record, State, Steering, Stop, Tools, TurnLoop}

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

  # The admission of a client message by phase (`TurnLoop.admit/3`).
  @impl true
  def handle_call({op, text}, _from, %State{} = state) when op in [:prompt, :steer, :follow_up] do
    {reply, state} = TurnLoop.admit(op, text, state)
    {:reply, reply, state}
  end

  def handle_call(:snapshot, _from, %State{} = state) do
    snapshot = %Snapshot{
      instance_id: state.instance_id,
      seq: state.seq,
      messages: state.transcript,
      turn: if(match?(%Turn{}, state.activity), do: Turn.snapshot(state.activity)),
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

  # The abort replies through `GenServer.reply/2` (`TurnLoop.abort/2`).
  def handle_call(:abort, from, %State{} = state), do: {:noreply, TurnLoop.abort(state, from)}

  # A turn that the provider started by itself (#240), before the clauses
  # of the current turn's events.
  @impl true
  def handle_info({:stream_event, _turn_id, :turn_start} = message, state),
    do: {:noreply, TurnLoop.handle(message, state)}

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

  def handle_info({:stream_event, turn_id, event}, %State{activity: %Turn{id: turn_id}} = state) do
    %State{activity: turn} = state = Messages.start_assistant_message(state)

    case Turn.add_block(turn, event) do
      {:ok, turn} ->
        {:noreply, emit(%{state | activity: turn}, :message_update, Map.new([event]))}

      {:error, reason} ->
        {:noreply, TurnLoop.stop_provider(state, reason)}
    end
  end

  # The hands' result of the running Helyx tool.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{activity: %Turn{id: turn_id, tools: %{running: call_id}}} = state
      ),
      do: {:noreply, Tools.result(state, result)}

  # A message for a turn or a call that is no longer current.
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:cancel_tool, _call_id}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}

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

  # The lifecycle inputs (`TurnLoop.handle/2`): the provider process's
  # terminal, `provider_ready`, replies, and `provider_down`, the results
  # of the prepare Task and the context requests, the idle timer, every
  # other `:DOWN`, and the answer of the hands to the cleanup request. If
  # the hands die, the request's `:DOWN` is dropped and their `:EXIT`
  # stops the session. Any other message is a bug and crashes the session.
  def handle_info(message, state), do: {:noreply, TurnLoop.handle(message, state)}

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

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
