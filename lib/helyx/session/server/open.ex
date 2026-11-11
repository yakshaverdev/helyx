defmodule Helyx.Session.Server.Open do
  @moduledoc false
  # The open of a session process, on both sides: the start in the caller,
  # with its attach to a running session, and the open in the session process
  # before its hands. It decides when a start returns a session, attaches, or
  # gives an error (docs/features/server-management.md,
  # docs/features/session-lock.md).

  alias Helyx.Session.{Background, Hands, Id, Input, Killer, Queue, Transcript}
  alias Helyx.Session.Server.{Sources, State}

  # `open` is nil with no session file, or `{path, fun}`: the session runs
  # `fun` to make or read the file. Past the deadline of the load the
  # session is killed, and the caller gets `{:error, :open_timeout}`. A start
  # of an id that this Core runs attaches
  # (docs/features/server-management.md). The second run of a start is its
  # last.
  def start(%State{} = state, tools, open, runs \\ 2) do
    start = {state, tools, open, runs}

    case launch(state, tools, open) do
      {:error, {:already_started, pid}} -> attach(pid, session(state), start)
      {:error, :max_children} -> attach(Helyx.Session.pid(session(state)), session(state), start)
      {:started, result} -> result
      error -> error
    end
  end

  # The open of `Helyx.Session.resume/2`: the read of the locked file and its
  # model ref. A repair of a crash may leave tool calls with no result, and
  # the disk may hold a result with no open call (#269, #417, #584).
  def load(state, path) do
    with {:ok, resumed} <- Helyx.Session.File.resume_picked(path, state.cwd),
         {:ok, {ref, provider}} <- Input.model(state.core, resumed.model) do
      {:ok,
       %{
         state
         | model: ref,
           provider: provider,
           parent: resumed.parent,
           save: {:saving, resumed.file},
           transcript: Transcript.repair(resumed.messages),
           sync: {:replay, resumed.messages},
           summary: resumed.summary,
           resume_ids: resumed.resume_ids,
           compacted: resumed.compacted,
           registry: Helyx.Session.ToolRegistry.restore(state.registry, resumed.activated)
       }}
    end
  end

  # The file of a new session, which the session process makes at its start
  # (`create/3`), or nil with no sessions dir.
  def create_spec(nil, _id, _cwd, _model, _parent), do: nil

  def create_spec(dir, id, cwd, model, parent) do
    {Helyx.Session.File.path(dir, cwd, id, parent),
     fn state ->
       with {:ok, file} <- Helyx.Session.File.create(dir, id, cwd, model, parent),
            do: {:ok, %{state | save: {:saving, file}}}
     end}
  end

  # A new id is random, or derived from a parent link, so a process with the
  # id is an earlier child of that link, not this start
  # (docs/features/agent-tool.md).
  def create(%State{} = state, tools, open) do
    case launch(state, tools, open) do
      {:error, {:already_started, _pid}} -> {:error, {:create_failed, :eexist}}
      {:error, :max_children} -> {:error, :too_many_sessions}
      {:started, result} -> result
      error -> error
    end
  end

  defp launch(state, tools, open) do
    ref = make_ref()

    case start_child(state, tools, {open, self(), ref}) do
      {:ok, pid} -> {:started, await_open(pid, ref, session(state))}
      error -> error
    end
  end

  defp session(%State{id: id, core: core}), do: %Helyx.Session{id: id, core: core}

  # The process takes the call after its open. An open that failed exits with
  # its error, which the first caller got too. Any other end of the process
  # is no result of a start, so the start runs again. At the cap, an id that
  # does not run has no process.
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

  # The go comes after the monitor, so a crash of the open reaches the caller
  # with its reason. A kill before the result is the deadline of the open, or
  # the kill of a Core stop after `Stop.shutdown_ms/0` during a long load.
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
    # resolved once here is the plugin that a lookup per provider call would
    # give. Compaction and Memory are single-mode. The ModelContext is the one
    # that the start named (docs/features/session-model-context.md).
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

  # The open waits for the go of the caller (`await_open/3`) and runs before
  # the hands, so no hands exist when it fails. A caller that ended before
  # the go or during the open gets no session.
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

  # The load reads at least this many bytes of the session file in each ms: a
  # third of the slowest content that a session writes
  # (docs/features/session-lock.md).
  @load_bytes_per_ms 1_000

  # A file edit of the id in this Core refuses the open. The session is in
  # the Registry under its id from before its `init/1`, and the edit
  # registers `{:edit, id}` before it looks up the id, so at least one of
  # the two sees the other (`Helyx.Session.File.Edit`).
  defp open_file(state, {path, fun}) do
    if Registry.lookup(Helyx.Core.sessions_registry(state.core), {:edit, state.id}) == [] do
      # A kill ends the open at its deadline, also when the caller is gone.
      # The deadline grows with the file.
      killer = Killer.arm(state.deadline_ms.open + div(file_size(path), @load_bytes_per_ms))
      result = fun.(state)
      Killer.cancel(killer)
      result
    else
      {:error, :editing}
    end
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

    # A run that was live at the stop of a resumed session ended with it: its
    # lost end waits for the next turn
    # (docs/features/background-bash.md). A new session has no ends.
    queue = %Queue{
      ends: %Queue.Ends{items: Background.lost(state.transcript), wake: :off}
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
