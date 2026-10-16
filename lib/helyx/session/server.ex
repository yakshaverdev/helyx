defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks. The turn lifecycle, with
  # the match of each lifecycle input to the current activity, is in
  # `Helyx.Session.Server.TurnLoop`; the callbacks here forward those
  # inputs and match the records of the current turn. The client API and
  # the docs of the behaviour are in `Helyx.Session`.

  alias Helyx.ModelRef
  alias Helyx.Session.{Background, Hands, Id, Lock, Queue, Turn}
  alias Helyx.Session.Server.{Compaction, Events, ProviderConn, Records, State, Steering, Stop}
  alias Helyx.Session.Server.ToolRuns
  alias Helyx.Session.Server.{TurnLoop, Wait}

  use GenServer, restart: :temporary, shutdown: Stop.shutdown_ms()

  # Starts the session process under Core for `Helyx.Session.start/2` and
  # `resume/2`. `open` is nil with no session file, or `{path, fun}`: the
  # init takes the lock of `path` and runs `fun` on the state under it
  # (`Lock.hold/2`), so the port of the lock has one owner for its whole
  # life. An error of the init comes back as it is. The Registry
  # rejects a session that this Core runs before the init: it is open in
  # another process, as a lock held by another Core (session-lock.md).
  def start(%State{id: id, core: core} = state, tools, open) do
    case start_child(state, tools, open) do
      {:ok, _pid} -> {:ok, %Helyx.Session{id: id, core: core}}
      {:error, {:already_started, _pid}} -> {:error, {:session_locked, id}}
      error -> error
    end
  end

  defp start_child(%State{core: core} = state, tools, open) do
    # The plugin table of a Core does not change after start, so a plugin
    # resolved once here is the plugin a lookup per provider call would give.
    # Both interfaces are single-mode: one plugin or none (nil).
    session = %{
      state
      | model_context: List.first(Helyx.Core.plugins(core, Helyx.ModelContext)),
        compaction: List.first(Helyx.Core.plugins(core, Helyx.Compaction)),
        tool_specs: Enum.map(tools, fn {_tool, spec} -> spec end),
        tool_modules: Map.new(tools, fn {tool, spec} -> {spec.name, tool} end)
    }

    DynamicSupervisor.start_child(
      Helyx.Core.session_supervisor(core),
      {__MODULE__, {session, open}}
    )
  end

  def start_link({%State{id: id, core: core}, _open} = args) do
    GenServer.start_link(__MODULE__, args, name: via(core, id))
  end

  @impl true
  def init({%State{} = state, open}) do
    # The session traps exits: the hands are linked, so their crash arrives
    # as a message, and a death of the session takes them with it (ADR 0004).
    Process.flag(:trap_exit, true)

    # First, so no hands exist yet when the open fails.
    case open_file(state, open) do
      {:ok, state} -> init_hands(state)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp open_file(state, nil), do: {:ok, state}

  defp open_file(state, {path, fun}) do
    with {:ok, lock, state} <- Lock.hold(path, fn -> fun.(state) end),
         do: {:ok, %{state | lock: lock}}
  end

  defp init_hands(state) do
    instance_id = Id.new()
    # One folder per process start, so two Cores that hold one session id
    # never share it. `Stop.run/1` deletes it.
    background_dir = Path.join(System.tmp_dir() || "/tmp", "helyx-" <> instance_id)

    {:ok, hands} =
      Hands.start_link(
        core: state.core,
        cwd: state.cwd,
        dir: background_dir,
        session: self(),
        tools: state.tool_modules
      )

    # A run that was live at the stop of a resumed session ended with it:
    # its lost end waits for the next turn (docs/features/background-bash.md).
    # A new session has no ends, so the hold matters only at a resume.
    queue = %Queue{ends: Background.lost(state.transcript), hold: true}

    {:ok,
     %{
       state
       | hands: hands,
         instance_id: instance_id,
         background_dir: background_dir,
         queue: queue
     }}
  end

  # The admission of a client message by phase (`TurnLoop.admit/3`).
  @impl true
  def handle_call({op, text}, _from, %State{} = state) when op in [:prompt, :steer, :follow_up] do
    {reply, state} = TurnLoop.admit(op, text, state)
    {:reply, reply, state}
  end

  def handle_call({:compact, text}, _from, %State{} = state) do
    {reply, state} = Compaction.admit(text, state)
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
  # (`{:background_end, text}`). The transcript and the provider get a
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
  def handle_info({:background_end, text}, state),
    do: {:noreply, state |> Steering.push_end(text) |> TurnLoop.settle()}

  # A message for a turn or a call that is no longer current.
  def handle_info({:tool_result, _turn_id, _call_id, _result}, state), do: {:noreply, state}
  def handle_info({:stream_event, _turn_id, _event}, state), do: {:noreply, state}

  # The failed subscribe of `Helyx.Session.subscribe/1`, and the end of a
  # subscriber: only the monitor of its entry removes the entry.
  def handle_info({:unsubscribe, pid}, %State{} = state) do
    {:noreply, Events.unsubscribe(state, pid)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{subscribers: subscribers} = state)
      when :erlang.map_get(pid, subscribers) == ref,
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
  @impl true
  def terminate(_reason, state) do
    Stop.run(state)
  end

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
