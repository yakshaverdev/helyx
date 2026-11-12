defmodule Helyx.Session.OpenTest do
  # The open of a session file (#579, #605, #665, #683, #718,
  # docs/features/session-lock.md). A second Core in the node takes the place
  # of a second OS process: each Core takes the lock of its data folder.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.Session
  alias Helyx.Test.UnsavedSession

  @moduletag :tmp_dir

  setup :start_core

  defp path(dir, id), do: hd(Path.wildcard(Path.join([dir, "*", id <> ".jsonl"])))

  defp turn(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
  end

  # A session file whose last line has no newline: a resume appends one, so
  # an unchanged file proves that nothing was written.
  defp open_without_newline(core, dir) do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    turn(session, "hi")
    path = path(dir, session.id)
    File.write!(path, String.trim_trailing(File.read!(path), "\n"))
    {session, path}
  end

  # The notice of a loss before the first subscribe reaches no client; the
  # snapshot tells the later client.
  test "the snapshot says whether the session saves", %{core: core, tmp_dir: dir} do
    {:ok, held} = Session.start(core, model: "test/ok", sessions_dir: dir)
    assert {:ok, %{persisting: true}, _ref} = Session.subscribe(held)

    {:ok, memory} = Session.start(core, model: "test/ok")
    assert {:ok, %{persisting: false}, _ref} = Session.subscribe(memory)

    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    UnsavedSession.stop_saving(session)
    assert {:ok, %{persisting: false}, _ref} = Session.subscribe(session)
  end

  test "a resume that fails leaves no session and changes nothing", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    turn(session, "hi")
    stop_session(session, &GenServer.stop/1)
    path = path(dir, session.id)
    changed = String.replace(File.read!(path), ~s("test/ok"), ~s("gone/ok"))
    File.write!(path, changed)

    assert {:error, {:unknown_provider, "gone"}} =
             Session.resume(core, sessions_dir: dir, id: session.id)

    assert File.read!(path) == changed
    assert Session.pid(session) == nil
  end

  # Holds the start request of `open` in the mailbox of the suspended
  # session supervisor.
  defp park_start(core, open) do
    sup = Process.whereis(Helyx.Core.session_supervisor(core))
    :ok = :sys.suspend(sup)
    {caller, ref} = spawn_monitor(open)

    await(
      fn -> Process.info(sup, :message_queue_len) == {:message_queue_len, 1} end,
      "the start request to reach the supervisor"
    )

    {sup, caller, ref}
  end

  # A stopped session whose resume waits in the supervisor, with its caller killed.
  defp park_resume_and_kill_caller(core, dir) do
    {session, path} = open_without_newline(core, dir)
    stop_session(session, &GenServer.stop/1)
    resume = fn -> Session.resume(core, sessions_dir: dir, id: session.id) end
    {sup, caller, ref} = park_start(core, resume)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, :killed}
    {session, path, sup}
  end

  # A start request that never reaches the supervisor writes nothing.
  test "a start request that exits writes nothing", %{core: core, tmp_dir: dir} do
    {sup, caller, ref} =
      park_start(core, fn -> Session.start(core, model: "test/ok", sessions_dir: dir) end)

    Process.exit(sup, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, {:killed, _call}}
    # The folders come before the request (#683), so only they are left.
    assert Path.wildcard(Path.join([dir, "**", "*.jsonl"])) == []
  end

  test "a caller killed during its start request leaves no session", %{
    core: core,
    tmp_dir: dir
  } do
    {session, path, sup} = park_resume_and_kill_caller(core, dir)
    Process.exit(sup, :kill)

    assert Session.pid(session) == nil
    assert File.exists?(path)
  end

  # The arguments of `Helyx.Session.Server.start/3` for a new session with no
  # file, whose open function a test gives.
  defp start_args(core, dir) do
    id = Helyx.Session.Id.new()
    {:ok, ref} = Helyx.ModelRef.parse("test/ok")
    {:ok, provider} = Helyx.Provider.find(core, ref.provider)
    {:ok, tools} = Helyx.Tool.specs(core)

    state = %Helyx.Session.Server.State{
      id: id,
      core: core,
      model: ref,
      provider: provider,
      cwd: File.cwd!()
    }

    {state, tools, Path.join(dir, id <> ".jsonl")}
  end

  # Starts, in a new caller, a session whose open waits until the test sends
  # `:go`. `bounds` sets fields of the state, such as `deadline_ms`, and
  # `:file_bytes` makes a sparse session file of that size before the start.
  # Returns the caller, the session process, and the session path.
  defp start_held(core, dir, bounds \\ []) do
    test = self()
    {file_bytes, bounds} = Keyword.pop(bounds, :file_bytes, 0)
    {state, tools, path} = start_args(core, dir)
    state = struct!(state, bounds)

    if file_bytes > 0,
      do: File.open!(path, [:write], &:file.pwrite(&1, file_bytes - 1, "\n"))

    open =
      {path,
       fn state ->
         send(test, {:in_open, self()})

         receive do
           :go -> {:ok, state}
         end
       end}

    {caller, _ref} =
      spawn_monitor(fn ->
        send(
          test,
          {:started,
           Helyx.Session.Server.start(state, {tools, Helyx.Tool.concurrent(tools), []}, open)}
        )
      end)

    assert_receive {:in_open, pid}
    {caller, pid, path}
  end

  # The deadline of the open kills the session process (#665). The rest is
  # the margin for load, so the open is reached (#718).
  @load_open_ms 2_000

  @tag :slow
  test "an open past its deadline gives :open_timeout, and no session is left", %{
    core: core,
    tmp_dir: dir
  } do
    {_caller, pid, _path} =
      start_held(core, dir,
        deadline_ms: %{open: @load_open_ms, prepare: Session.Server.State.prepare_ms()}
      )

    assert_receive {:started, {:error, :open_timeout}}
    refute Process.alive?(pid)
  end

  # The deadline of the load is `open` plus 1 ms for each 1,000 bytes of the
  # file (#834): 8,388,608 bytes give 8,388 ms more. The load here outlasts
  # `open` by its own length, and the go comes far before the end of the
  # deadline of the load: the rest is the margin.
  @tag :slow
  test "the deadline of the load grows with the file", %{core: core, tmp_dir: dir} do
    {_caller, pid, _path} =
      start_held(core, dir,
        file_bytes: 8 * 1024 * 1024,
        deadline_ms: %{open: @load_open_ms, prepare: Session.Server.State.prepare_ms()}
      )

    Process.sleep(2 * @load_open_ms)
    assert Process.alive?(pid)
    send(pid, :go)
    assert_receive {:started, {:ok, %Session{}}}
  end

  # A `receive` waits at most 4,294,967,295 ms; a longer deadline would
  # crash the process that kills. The session monitors it from the arm on.
  test "a deadline past the longest wait keeps its kill", %{core: core, tmp_dir: dir} do
    {caller, pid, _path} =
      start_held(core, dir, deadline_ms: %{open: 5_000_000_000, prepare: 1_000})

    # The caller watches the session too (`await_open/3`).
    {:monitored_by, watchers} = Process.info(pid, :monitored_by)
    assert Enum.any?(watchers, &(is_pid(&1) and &1 != caller and Process.alive?(&1)))
    send(pid, :go)
    assert_receive {:started, {:ok, %Session{}}}
  end

  @tag :slow
  test "a caller that ends during an open past its deadline leaves no session", %{
    core: core,
    tmp_dir: dir
  } do
    {caller, pid, _path} =
      start_held(core, dir,
        deadline_ms: %{open: @load_open_ms, prepare: Session.Server.State.prepare_ms()}
      )

    ref = Process.monitor(pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, _, :process, ^caller, :killed}

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  # The open runs in the session process after the supervisor started it,
  # so a slow open holds no other start of the Core (#605).
  test "a start does not wait for the open of another session", %{core: core, tmp_dir: dir} do
    {caller, pid, _path} = start_held(core, dir)

    other = Task.async(fn -> Session.start(core, model: "test/ok", sessions_dir: dir) end)
    assert {:ok, _} = Task.await(other, Helyx.Test.Events.wait_ms())

    send(pid, :go)
    assert_receive {:started, {:ok, %Session{}}}
    assert_receive {:DOWN, _ref, :process, ^caller, :normal}
  end

  test "a caller that ends during its open leaves no session", %{
    core: core,
    tmp_dir: dir
  } do
    {caller, pid, _path} = start_held(core, dir)
    ref = Process.monitor(pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, _, :process, ^caller, :killed}

    # The session checks for its `:DOWN` of the caller once, after the open.
    await_down(pid, caller, "the session to get the end of its caller")

    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  # The start request reaches the supervisor after its caller ended, so the
  # session gets no go and runs no open: the file keeps its missing newline.
  test "a caller killed before its start reaches the supervisor leaves no session", %{
    core: core,
    tmp_dir: dir
  } do
    {session, path, sup} = park_resume_and_kill_caller(core, dir)
    before = File.read!(path)
    :ok = :sys.resume(sup)
    # This call waits behind the parked start, so the session process exists
    # after it until it sees its caller gone.
    _ = :sys.get_state(sup)
    await(fn -> Session.pid(session) == nil end, "the session to stop")

    assert File.read!(path) == before
  end

  # The caller monitors the session before the go, so a crash of the open
  # reaches it with its reason, not `:noproc`.
  @tag capture_log: true
  test "an open that raises gives the crash as an error", %{core: core, tmp_dir: dir} do
    {state, tools, path} = start_args(core, dir)
    open = {path, fn _state -> raise "open" end}

    assert {:error, {%RuntimeError{message: "open"}, [_ | _]}} =
             Helyx.Session.Server.start(state, {tools, Helyx.Tool.concurrent(tools), []}, open)
  end
end
