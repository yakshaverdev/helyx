defmodule Helyx.Session.Server do
  @moduledoc false
  # The session process: the GenServer callbacks. The turn lifecycle, with
  # the match of each lifecycle input to the current activity, is in
  # `Helyx.Session.Server.TurnLoop`; the callbacks here forward those
  # inputs and match the records of the current turn. The client API and
  # the docs of the behaviour are in `Helyx.Session`.

  alias Helyx.Session.{Background, Hands, Id, Lock, Queue, Turn}
  alias Helyx.Session.Server.{Calls, Events, ProviderConn, Records, State, Steering, Stop}
  alias Helyx.Session.Server.Summary
  alias Helyx.Session.Server.ToolRuns
  alias Helyx.Session.Server.{TurnLoop, Wait}

  use GenServer, restart: :temporary, shutdown: Stop.shutdown_ms()

  # Starts the session process under Core for `Helyx.Session.start/2` and
  # `resume/2`. `open` is nil with no session file, or `{path, fun}`: the
  # session takes the lock of `path` and runs `fun` on the state under it
  # (`Lock.hold/2`), so the port of the lock has one owner for its whole
  # life. The open runs after the supervisor started the process; the
  # caller waits for its result, and an error of the open comes back as it
  # is. The Registry rejects a session that this Core runs before the init:
  # it is open in another process, as a lock held by another Core
  # (session-lock.md). Past the deadline `open_ms` of the state the session
  # is killed, and the caller gets `{:error, :open_timeout}`.
  def start(%State{id: id, core: core} = state, tools, open) do
    ref = make_ref()

    case start_child(state, tools, {open, self(), ref}) do
      {:ok, pid} -> await_open(pid, ref, %Helyx.Session{id: id, core: core})
      {:error, {:already_started, _pid}} -> {:error, {:session_locked, id}}
      error -> error
    end
  end

  # The go comes after the monitor, so a crash of the open reaches the
  # caller with its reason. The session sends the result before it ends.
  # A kill before the result is the deadline of the open: the kill of a Core
  # stop comes after `Stop.shutdown_ms/0`, which is longer.
  defp await_open(pid, ref, session) do
    monitor = Process.monitor(pid)
    send(pid, {ref, :go})

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        with :ok <- result, do: {:ok, session}

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :open_timeout}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    end
  end

  defp start_child(%State{core: core} = state, tools, start) do
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
      {__MODULE__, {session, start}}
    )
  end

  def start_link({%State{id: id, core: core}, _start} = args) do
    GenServer.start_link(__MODULE__, args, name: via(core, id))
  end

  # The init does no work that can wait: the supervisor waits for it.
  @impl true
  def init({%State{} = state, {open, caller, ref}}) do
    # The session traps exits: the hands are linked, so their crash arrives
    # as a message, and a death of the session takes them with it (ADR 0004).
    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, {open, caller, ref, Process.monitor(caller)}}}
  end

  # The open waits for the go of the caller (`await_open/3`), and runs
  # before the hands, so no hands exist yet when it fails. A caller that
  # ended before the go or during the open gets no session: the stop
  # releases the lock (`terminate/2`). A caller that ends after the check
  # below gets a session that runs, as after a start that returned.
  @impl true
  def handle_continue({open, caller, ref, monitor}, state) do
    receive do
      {^ref, :go} -> run_open(state, open, caller, ref, monitor)
      {:DOWN, ^monitor, :process, _pid, _reason} -> {:stop, :normal, state}
    end
  end

  defp run_open(state, open, caller, ref, monitor) do
    case open_file(state, open) do
      {:ok, state} ->
        receive do
          {:DOWN, ^monitor, :process, _pid, _reason} -> {:stop, :normal, state}
        after
          0 ->
            Process.demonitor(monitor, [:flush])
            state = init_hands(state)
            send(caller, {ref, :ok})
            {:noreply, state}
        end

      {:error, reason} ->
        send(caller, {ref, {:error, reason}})
        {:stop, :normal, state}
    end
  end

  defp open_file(state, nil), do: {:ok, state}

  # A kill ends the session at the deadline of its open even when the caller
  # is gone, so the port closes and perl frees the lock (session-lock.md).
  defp open_file(state, {path, fun}) do
    killer = kill_after(state.open_ms)
    result = Lock.hold(path, fn -> fun.(state) end)
    cancel_kill(killer)
    with {:ok, lock, state} <- result, do: {:ok, %{state | lock: lock}}
  end

  # `:timer.kill_after/1` cannot be cancelled once it fires: its kill can
  # reach the session after the cancel. This cancel waits for the end of the
  # killer, and a signal of a process comes before its `:DOWN`.
  defp kill_after(ms) do
    session = self()

    spawn_monitor(fn ->
      monitor = Process.monitor(session)

      receive do
        :cancel -> :ok
        {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
      after
        ms -> Process.exit(session, :kill)
      end
    end)
  end

  defp cancel_kill({pid, monitor}) do
    send(pid, :cancel)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    end
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
        background_dir: background_dir,
        session: self(),
        tools: state.tool_modules
      )

    # A run that was live at the stop of a resumed session ended with it:
    # its lost end waits for the next turn (docs/features/background-bash.md).
    # A new session has no ends, so the hold matters only at a resume.
    queue = %Queue{
      ends: Background.lost(state.transcript),
      hold: true
    }

    %{
      state
      | hands: hands,
        instance_id: instance_id,
        background_dir: background_dir,
        queue: queue
    }
  end

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
  #
  # A session with no hands ended in its open: it holds the lock at most.
  @impl true
  def terminate(_reason, %State{hands: nil} = state), do: Lock.release(state.lock)
  def terminate(_reason, state), do: Stop.run(state)

  def via(core, id), do: {:via, Registry, {Helyx.Core.sessions_registry(core), id}}
end
