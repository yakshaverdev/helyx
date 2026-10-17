defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks. The turn lifecycle, with
  # the match of each lifecycle input to the current activity, is in
  # `Helyx.Session.Server.TurnLoop`; the callbacks here forward those
  # inputs and match the records of the current turn. The client API and
  # the docs of the behaviour are in `Helyx.Session`.

  alias Helyx.Session.{Lock, Turn}
  alias Helyx.Session.Server.{Calls, Events, Open, ProviderConn, Records, State, Steering}
  alias Helyx.Session.Server.{Stop, Summary, ToolRuns, TurnLoop, Wait}

  use GenServer, restart: :temporary, shutdown: Stop.shutdown_ms()

  # The start and the open of the session process (`Open`).
  defdelegate start(state, tools, open), to: Open

  def start_link({%State{id: id, core: core}, _start} = args) do
    GenServer.start_link(__MODULE__, args, name: via(core, id))
  end

  @impl true
  def init(args), do: Open.init(args)

  @impl true
  def handle_continue(continue, state), do: Open.handle_continue(continue, state)

  # The calls of the client API, with their deadline (`Calls`).
  @impl true
  def handle_call(request, from, state), do: Calls.handle(request, from, state)

  # The messages of the summary call's process, by its pid or by the id of
  # its turn, before every other clause (`Summary.handle/2`).
  @impl true
  def handle_info(
        {:provider_ready, pid} = message,
        %State{summary_call: %Summary{pid: pid}} = state
      ),
      do: {:noreply, Summary.handle(message, state)}

  def handle_info({tag, id, _} = message, %State{summary_call: %Summary{id: id}} = state)
      when tag in [:stream_event, :stream_end, :need_context],
      do: {:noreply, Summary.handle(message, state)}

  def handle_info({:need_context, id} = message, %State{summary_call: %Summary{id: id}} = state),
    do: {:noreply, Summary.handle(message, state)}

  def handle_info(
        {:provider_down, pid, _} = message,
        %State{summary_call: %Summary{pid: pid}} = state
      ),
      do: {:noreply, Summary.handle(message, state)}

  def handle_info(
        {:tool_request, pid, _, _, _, _} = message,
        %State{summary_call: %Summary{pid: pid}} = state
      ),
      do: {:noreply, Summary.handle(message, state)}

  # A turn that the provider started by itself (#240), before the clauses
  # of the current turn's events.
  def handle_info({:stream_event, _turn_id, :turn_start} = message, state),
    do: {:noreply, TurnLoop.handle(message, state)}

  def handle_info(
        {:stream_event, turn_id, {:message_end, stop_reason, usage}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, Records.end_assistant(state, stop_reason, usage)}

  def handle_info(
        {:stream_event, turn_id, {:compaction, before, after_}},
        %State{activity: %Turn{id: turn_id}} = state
      ),
      do: {:noreply, Records.compaction(state, before, after_)}

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

  # A Helyx tool request of the provider process `pid` (`ToolRuns`). The call
  # and its result join the transcript from the provider's own events, not
  # from here. A request of a turn that is not current gets `aborted`.
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

  # A resume id of the session's live provider process, for its turn or
  # for the turn that the current wait ended (#518). An ended process,
  # another pid, or another turn records nothing.
  def handle_info(
        {:resume_id, pid, turn_id, id, cut},
        %State{activity: %Turn{id: turn_id}, conn: %ProviderConn{pid: pid, status: :ready}} =
          state
      ),
      do: {:noreply, Records.resume_id(state, turn_id, id, cut)}

  def handle_info(
        {:resume_id, pid, turn_id, id, cut},
        %State{activity: %Wait{turn: turn_id}, conn: %ProviderConn{pid: pid, status: :ready}} =
          state
      ),
      do: {:noreply, Records.resume_id(state, turn_id, id, cut)}

  def handle_info({:resume_id, _pid, _turn_id, _id, _cut}, state), do: {:noreply, state}

  # An event that breaks the bound of the open message stops the provider
  # process (`Records.delta/2`).
  def handle_info({:stream_event, turn_id, event}, %State{activity: %Turn{id: turn_id}} = state) do
    case Records.delta(state, event) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, TurnLoop.stop_provider(state, reason)}
    end
  end

  # The hands' start answer of a background run: the run counts from here,
  # also when its call is no longer current, and its end counts down
  # (`{:background_end, message}`). The transcript and the provider get a
  # plain `:ok` result.
  def handle_info({:tool_result, turn_id, call_id, {:started, text}}, state),
    do: handle_info({:tool_result, turn_id, call_id, {:ok, text}}, Steering.started(state))

  # The hands' result of the running Helyx tool.
  def handle_info(
        {:tool_result, turn_id, call_id, result},
        %State{activity: %Turn{id: turn_id, tool_queue: %{running: call_id}}} = state
      ),
      do: {:noreply, ToolRuns.result(state, result)}

  # The end of a background run (docs/features/background-bash.md): a
  # steer in a submitted turn, else it waits; an idle session with no hold
  # starts a turn for it.
  def handle_info({:background_end, message}, state),
    do: {:noreply, state |> Steering.push_end(message) |> TurnLoop.settle()}

  # A message for a turn or a call that is no longer current.
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}

  # A notice of the sync worker of this instance.
  def handle_info({:memory_notice, pid, text}, %State{sync: pid} = state),
    do: {:noreply, Events.emit(state, nil, :notice, %{text: text})}

  # A failed subscribe (`Helyx.Session.subscribe/1`), an ack (`ack/2`), and the
  # end of a subscriber: only the monitor of its entry removes the entry.
  def handle_info({:unsubscribe, pid}, %State{} = state),
    do: {:noreply, Events.unsubscribe(state, pid)}

  def handle_info({:ack, pid, seq}, state), do: {:noreply, Events.ack(state, pid, seq)}

  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{subscribers: subscribers} = state)
      when elem(:erlang.map_get(pid, subscribers), 0) == ref,
      do: {:noreply, Events.subscriber_down(state, pid)}

  # The lock's port closed while the session runs: perl ended, so the
  # kernel released the lock (docs/features/session-lock.md). Its exit
  # status comes first, then the exit of the port, also of a port that
  # closed without a status. Another process can now append to the file, so
  # the session stops saving and goes on in memory (`Records.stop_saving/3`).
  def handle_info({port, {:exit_status, _status}}, %State{lock: port} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, port, reason}, %State{lock: port} = state) do
    state = %{state | lock: nil}
    {:noreply, Records.stop_saving(state, "the session lock is lost", inspect(reason))}
  end

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
  #
  # A session with no hands ended in its open: it holds the lock at most.
  @impl true
  def terminate(_reason, %State{hands: nil} = state), do: Lock.release(state.lock)
  def terminate(_reason, state), do: Stop.run(state)

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
