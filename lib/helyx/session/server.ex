defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks. The turn lifecycle, with
  # the match of each lifecycle input to the current activity, is in
  # `Helyx.Session.Server.TurnLoop`; the callbacks here forward those
  # inputs and match the records of the current turn. The client API and
  # the docs of the behaviour are in `Helyx.Session`.

  alias Helyx.ModelRef
  alias Helyx.Session.{Hands, Id, Turn}
  alias Helyx.Session.Server.{Events, Records, State, Steering, Stop, ToolRuns, TurnLoop}

  use GenServer, restart: :temporary, shutdown: Stop.shutdown_ms()

  def start_link(%State{id: id, core: core} = state) do
    GenServer.start_link(__MODULE__, state, name: via(core, id))
  end

  @impl true
  def init(%State{} = state) do
    # The session traps exits: the hands are linked, so their crash arrives
    # as a message, and a death of the session takes them with it (ADR 0004).
    Process.flag(:trap_exit, true)

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

  def handle_call(:snapshot, _from, %State{} = state),
    do: {:reply, Events.snapshot(state), state}

  # The entry and the snapshot in one message, so every later event reaches
  # the caller. A repeated subscribe keeps the entry and its monitor.
  def handle_call({:subscribe, pid}, _from, %State{} = state) do
    state = Events.subscribe(state, pid)
    {:reply, Events.snapshot(state), state}
  end

  def handle_call({:set_model, %ModelRef{} = ref, provider}, _from, %State{} = state),
    do: {:reply, :ok, TurnLoop.settle(Records.set_model(state, ref, provider))}

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
      do: {:noreply, Records.end_assistant(state, stop_reason, usage)}

  # A tool result event of the provider: it closes the open message and
  # joins its open call (`Records.tool_result/3`).
  def handle_info(
        {:stream_event, turn_id, {:tool_result, call_id, result}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, Records.tool_result(state, call_id, result)}

  # The provider took a steer of this turn: its text, the one the session
  # checked at the client call, joins the transcript here (see
  # `Queue.take/2`).
  def handle_info(
        {:stream_event, turn_id, {:user_message, steer_id}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, Steering.take(state, steer_id)}

  # A Helyx tool request of the provider process `pid`, and its withdrawal
  # (`ToolRuns`). The call and its result join the transcript from the
  # provider's own events, not from here. A request of a turn that is not
  # current gets `aborted`.
  def handle_info(
        {:tool_request, _pid, turn_id, call, bytes, rejection},
        %State{activity: %Turn{id: turn_id}} = state
      ) do
    case ToolRuns.request(state, call, bytes, rejection) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason} -> {:noreply, TurnLoop.stop_provider(state, reason)}
    end
  end

  def handle_info({:tool_request, pid, turn_id, call, _bytes, _rejection}, state),
    do: {:noreply, ToolRuns.late(state, pid, turn_id, call.id)}

  def handle_info({:cancel_tool, call_id}, %State{activity: %Turn{}} = state),
    do: {:noreply, ToolRuns.cancel(state, call_id)}

  def handle_info(
        {:stream_event, turn_id, {:resume, id, cut}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, Records.resume(state, id, cut)}

  # An event that breaks the bound of the open message stops the provider
  # process (`Records.delta/2`).
  def handle_info({:stream_event, turn_id, event}, %State{activity: %Turn{id: turn_id}} = state) do
    case Records.delta(state, event) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, TurnLoop.stop_provider(state, reason)}
    end
  end

  # The hands' result of the running Helyx tool.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{activity: %Turn{id: turn_id, tool_queue: %{running: call_id}}} = state
      ),
      do: {:noreply, ToolRuns.result(state, result)}

  # A message for a turn or a call that is no longer current.
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:cancel_tool, _call_id}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}

  # The failed subscribe of `Helyx.Session.subscribe/1`, and the end of a
  # subscriber: only the monitor of its entry removes the entry.
  def handle_info({:unsubscribe, pid}, %State{} = state) do
    {:noreply, Events.unsubscribe(state, pid)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{subscribers: subscribers} = state)
      when :erlang.map_get(pid, subscribers) == ref,
      do: {:noreply, Events.subscriber_down(state, pid)}

  # An exit from a linked process is vital. The hands' death takes the
  # session with it, and a session that outlived its entry in the sessions
  # Registry would keep working where no client can reach it.
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
