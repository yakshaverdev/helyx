defmodule Helyx.Session.Server.Open do
  @moduledoc false
  # The open of a session process, on both sides: the start in the caller,
  # with its attach to a running session, and the open in the session
  # process before its hands. It decides when a start returns a session,
  # attaches, or gives an error (server-management.md, session-lock.md).
  # `Helyx.Session.Server` keeps the GenServer callbacks and calls in here.

  alias Helyx.Session.{Background, Hands, Id, Lock, Queue}
  alias Helyx.Session.Server.State

  # Starts the session process under Core for `Helyx.Session.start/2` and
  # `resume/2`. `open` is nil with no session file, or `{path, fun}`: the
  # session takes the lock of `path` and runs `fun` on the state under it
  # (`Lock.hold/2`), so the port of the lock has one owner for its whole
  # life. The open runs after the supervisor started the process; the
  # caller waits for its result, and an error of the open comes back as it
  # is. Past the deadline `deadline_ms.open` of the state the session is killed, and
  # the caller gets `{:error, :open_timeout}`. The Registry rejects a
  # session that this Core runs before the init, and the start attaches to
  # the running process; so does a start at the cap whose id runs
  # (server-management.md, "Attach"). The second run of a start is its last.
  def start(%State{id: id, core: core} = state, tools, open, runs \\ 2) do
    ref = make_ref()
    session = %Helyx.Session{id: id, core: core}
    start = {state, tools, open, runs}

    case start_child(state, tools, {open, self(), ref}) do
      {:ok, pid} -> await_open(pid, ref, session)
      {:error, {:already_started, pid}} -> attach(pid, session, start)
      {:error, :max_children} -> attach(Helyx.Session.pid(session), session, start)
      error -> error
    end
  end

  # The process takes the call after its open. An open that failed exits
  # with its error, which the first caller got too; the kill of the deadline
  # is the error of `await_open/3`. Any other end of the process is no
  # result of a start, so the start runs again. At the cap, an id that does
  # not run has no process.
  defp attach(nil, _session, _start), do: {:error, :too_many_sessions}

  defp attach(pid, session, {state, tools, open, runs}) do
    GenServer.call(pid, :live, :infinity)
    {:ok, session}
  catch
    :exit, {{:shutdown, {:open_failed, reason}}, _call} -> {:error, reason}
    :exit, {:killed, _call} -> {:error, :open_timeout}
    :exit, _reason when runs > 1 -> start(state, tools, open, runs - 1)
    :exit, _reason -> {:error, :session_not_found}
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

  defp start_child(%State{core: core} = state, {tools, concurrent}, start) do
    # The plugin table of a Core does not change after start, so a plugin
    # resolved once here is the plugin a lookup per provider call would give.
    # The three interfaces are single-mode: one plugin or none (nil).
    session = %{
      state
      | model_context: List.first(Helyx.Core.plugins(core, Helyx.ModelContext)),
        compaction: List.first(Helyx.Core.plugins(core, Helyx.Compaction)),
        memory: List.first(Helyx.Core.plugins(core, Helyx.Memory)),
        tool_specs: Enum.map(tools, fn {_tool, spec} -> spec end),
        tools: Map.new(tools, fn {tool, %{name: name}} -> {name, {tool, name in concurrent}} end)
    }

    DynamicSupervisor.start_child(
      Helyx.Core.session_supervisor(core),
      {Helyx.Session.Server, {session, start}}
    )
  end

  # The init does no work that can wait: the supervisor waits for it.
  def init({%State{} = state, {open, caller, ref}}) do
    # The session traps exits: the hands are linked, so their crash arrives
    # as a message, and a death of the session takes them with it (ADR 0004).
    Process.flag(:trap_exit, true)
    {:ok, state, {:continue, {open, caller, ref, Process.monitor(caller)}}}
  end

  # The open waits for the go of the caller (`await_open/3`), and runs
  # before the hands, so no hands exist yet when it fails. A caller that
  # ended before the go or during the open gets no session: the stop
  # releases the lock (`Server.terminate/2`). A caller that ends after the check
  # below gets a session that runs, as after a start that returned.
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
            state = state |> init_hands() |> Helyx.Session.Sync.open()
            send(caller, {ref, :ok})
            {:noreply, state}
        end

      # The reason reaches the attaches that wait (`attach/3`).
      {:error, reason} ->
        send(caller, {ref, {:error, reason}})
        {:stop, {:shutdown, {:open_failed, reason}}, state}
    end
  end

  defp open_file(state, nil), do: {:ok, state}

  # A kill ends the session at the deadline of its open even when the caller
  # is gone, so the port closes and perl frees the lock (session-lock.md).
  defp open_file(state, {path, fun}) do
    killer = kill_after(state.deadline_ms.open)
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
        tools: Map.new(state.tools, fn {name, {tool, _concurrent?}} -> {name, tool} end)
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
end
