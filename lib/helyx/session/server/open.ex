defmodule Helyx.Session.Server.Open do
  @moduledoc false
  # The open of a session process, on both sides: the start in the caller,
  # with its attach to a running session, and the open in the session
  # process before its hands. It decides when a start returns a session,
  # attaches, or gives an error (server-management.md, session-lock.md).
  # `Helyx.Session.Server` keeps the GenServer callbacks and calls in here.

  alias Helyx.Session.{Background, Hands, Id, Input, Killer, Lock, Queue, Transcript}
  alias Helyx.Session.Server.{Sources, State}

  # Starts the session process under Core for `resume/2`. `open` is nil
  # with no session file, or `{path, fun}`: the session takes the lock of
  # `path` and runs `fun` on the state under it (`Lock.hold/2`), so the port
  # of the lock has one owner for its whole life. The open runs after the
  # supervisor started the process; the caller waits for its result, and an
  # error of the open comes back as it is. Past the deadline of the take
  # (`deadline_ms.open` of the state) or of the load, which grows with the
  # file (`open_file/2`), the session is killed, and the caller gets
  # `{:error, :open_timeout}`. The Registry rejects a session that this
  # Core runs before the init, and the start attaches to the running
  # process; so does a start at the cap whose id runs (server-management.md,
  # "Attach"). The second run of a start is its last.
  def start(%State{} = state, tools, open, runs \\ 2) do
    start = {state, tools, open, runs}

    case launch(state, tools, open) do
      {:error, {:already_started, pid}} -> attach(pid, session(state), start)
      {:error, :max_children} -> attach(Helyx.Session.pid(session(state)), session(state), start)
      {:started, result} -> result
      error -> error
    end
  end

  # The open of `Helyx.Session.resume/2`: the read of the locked file and
  # its model ref.
  # A crash can leave tool calls with no result, and the disk can hold a
  # result with no open call. The session reads them with interrupted
  # results and without the stray results, and writes nothing (#269, #417, #584).
  def load(state, path) do
    with {:ok, resumed} <- Helyx.Session.File.resume_picked(path, state.cwd),
         {:ok, {ref, provider}} <- Input.model(state.core, resumed.model) do
      {:ok,
       %{
         state
         | model: ref,
           provider: provider,
           file: resumed.file,
           transcript: Transcript.repair(resumed.messages),
           sync: {:replay, resumed.messages},
           summary: resumed.summary,
           resume_ids: resumed.resume_ids,
           compacted: resumed.compacted,
           registry: Helyx.Session.ToolRegistry.restore(state.registry, resumed.activated)
       }}
    end
  end

  # The open of the file of a new session, which the session process runs
  # at its start under the lock of `path` (`create/3`), or nil with no
  # sessions dir.
  def create_spec(nil, _id, _cwd, _model, _parent), do: nil

  def create_spec(dir, id, cwd, model, parent) do
    {Helyx.Session.File.path(dir, cwd, id, parent),
     fn state ->
       with {:ok, file} <- Helyx.Session.File.create(dir, id, cwd, model, parent),
            do: {:ok, %{state | file: file}}
     end}
  end

  # The start of a new session for `Helyx.Session.start/2`, as `start/4`
  # but with no attach: a new id is random, or derived from a parent link,
  # so a process with the id is an earlier child of that link, not this
  # start (docs/features/agent-tool.md, "A reused call id").
  def create(%State{} = state, tools, open) do
    case launch(state, tools, open) do
      {:error, {:already_started, _pid}} -> {:error, {:create_failed, :eexist}}
      {:error, :max_children} -> {:error, :too_many_sessions}
      {:started, result} -> result
      error -> error
    end
  end

  # The result of the open, or the error of the supervisor start.
  defp launch(state, tools, open) do
    ref = make_ref()

    case start_child(state, tools, {open, self(), ref}) do
      {:ok, pid} -> {:started, await_open(pid, ref, session(state))}
      error -> error
    end
  end

  defp session(%State{id: id, core: core}), do: %Helyx.Session{id: id, core: core}

  # The process takes the call after its open. An open that failed exits
  # with its error, which the first caller got too; the kill of the deadline
  # is the error of `await_open/3`. Any other end of the process is no
  # result of a start, so the start runs again. At the cap, an id that does
  # not run has no process. A running session with other provider options
  # gives `{:error, :provider_opts_differ}`.
  defp attach(nil, _session, _start), do: {:error, :too_many_sessions}

  defp attach(pid, session, {state, tools, open, runs}) do
    with :ok <- GenServer.call(pid, {:attach, state.init.provider_opts}, :infinity),
         do: {:ok, session}
  catch
    :exit, {{:shutdown, {:open_failed, reason}}, _call} -> {:error, reason}
    :exit, {:killed, _call} -> {:error, :open_timeout}
    :exit, _reason when runs > 1 -> start(state, tools, open, runs - 1)
    :exit, _reason -> {:error, :session_not_found}
  end

  # The go comes after the monitor, so a crash of the open reaches the
  # caller with its reason. The session sends the result before it ends.
  # A kill before the result is the deadline of the open, or the kill of a
  # Core stop after `Stop.shutdown_ms/0` during a long load.
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

  defp start_child(%State{core: core} = state, {tools, concurrent, sources}, start) do
    # The plugin table of a Core does not change after start, so a plugin
    # resolved once here is the plugin a lookup per provider call would give.
    # Compaction and Memory are single-mode: one plugin or none (nil). The
    # ModelContext is the one that the start named, else the first, so a
    # resume gets the first (docs/features/session-model-context.md).
    plugins = %{
      model_context:
        state.plugins.model_context || List.first(Helyx.Core.plugins(core, Helyx.ModelContext)),
      compaction: List.first(Helyx.Core.plugins(core, Helyx.Compaction)),
      memory: List.first(Helyx.Core.plugins(core, Helyx.Memory))
    }

    registry = Helyx.Session.ToolRegistry.new(tools, concurrent, sources)
    session = %{state | plugins: plugins, registry: registry}

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
            state = state |> init_hands() |> Sources.start() |> Helyx.Session.Sync.open()
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

  # The load reads at least this many bytes of the session file in each ms:
  # a third of the slowest content that a session writes (session-lock.md,
  # row "wait of the caller").
  @load_bytes_per_ms 1_000

  # A kill ends the session at the deadline of its open even when the caller
  # is gone, so the port closes and perl frees the lock (session-lock.md).
  # After the take, the deadline of the load grows with the file.
  defp open_file(state, {path, fun}) do
    killer = Killer.arm(state.deadline_ms.open)

    result =
      Lock.hold(path, fn ->
        Killer.move(killer, state.deadline_ms.open + div(file_size(path), @load_bytes_per_ms))
        fun.(state)
      end)

    Killer.cancel(killer)
    with {:ok, lock, state} <- result, do: {:ok, %{state | lock: lock}}
  end

  # A file that is not there, as for a new session, or not readable, loads
  # nothing; the load gives its own error for it.
  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> 0
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
        tools: Helyx.Session.ToolRegistry.modules(state.registry),
        hooks: Helyx.Core.hooks(state.core)
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
