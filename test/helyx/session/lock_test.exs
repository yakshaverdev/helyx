defmodule Helyx.Session.LockTest do
  # The writer lock of a session file (#579, docs/features/session-lock.md).
  # A second Core in the node takes the place of a second OS process: each
  # take runs its own perl process.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase
  import Helyx.Test.SessionFile, only: [await_lock_free: 2]

  alias Helyx.{Event, Session}
  alias Helyx.Session.Lock

  @moduletag :tmp_dir

  setup :start_core

  defp other_core, do: start_core([Helyx.Test.Provider])

  defp path(dir, id), do: hd(Path.wildcard(Path.join([dir, "*", id <> ".jsonl"])))

  defp turn(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
  end

  # A session file whose last line has no newline: a resume that gets the
  # lock appends one, so an unchanged file proves that nothing was written.
  defp open_without_newline(core, dir) do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    turn(session, "hi")
    path = path(dir, session.id)
    File.write!(path, String.trim_trailing(File.read!(path), "\n"))
    {session, path}
  end

  defp port_messages,
    do: for({port, _} = message <- mailbox(), is_port(port), do: message)

  # The same Core rejects a second process in its Registry, before the
  # session process takes the lock, and the resume attaches to the running
  # one (docs/features/server-management.md).
  test "a session that another Core holds does not open, the same Core attaches, and its file is unchanged",
       %{core: core, tmp_dir: dir} do
    {session, path} = open_without_newline(core, dir)
    before = File.read!(path)
    id = session.id
    pid = Session.pid(session)

    assert Session.resume(other_core(), sessions_dir: dir, id: id) ==
             {:error, {:session_locked, id}}

    assert Session.resume(core, sessions_dir: dir, id: id) == {:ok, session}
    assert Session.pid(session) == pid
    assert File.read!(path) == before
    # The failed take leaves the caller no link and no message of its port.
    assert {:links, links} = Process.info(self(), :links)
    refute Enum.any?(links, &is_port/1)
    assert port_messages() == []
  end

  test "the newest session of the folder is not skipped when it is locked", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, older} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(older)
    turn(older, "first")
    stop_session(older, &GenServer.stop/1)

    {:ok, newest} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(newest)
    turn(newest, "second")

    assert Session.resume(other_core(), sessions_dir: dir) ==
             {:error, {:session_locked, newest.id}}
  end

  test "a normal stop frees the lock before it returns", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    turn(session, "hi")
    :ok = GenServer.stop(Session.pid(session))

    assert {:ok, _} = Session.resume(other_core(), sessions_dir: dir, id: session.id)
  end

  test "a killed session frees its lock", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    turn(session, "hi")
    # perl exits when it reads the end of its stdin, after the kill, and
    # `stop_session/2` waits for the free lock.
    stop_session(session, &Process.exit(&1, :kill))
    assert {:ok, _} = Session.resume(other_core(), sessions_dir: dir, id: session.id)
  end

  test "perl killed while the session runs gives one notice, and the session stops saving", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    before = File.read!(path(dir, session.id))

    Helyx.Test.LostLock.kill(session)

    assert_receive {:helyx_event, %Event{type: :notice, turn_id: nil, data: %{text: text}}}
    assert text == "the session lock is lost; the rest of this session is not saved"

    # The session lives in memory and no longer writes its file; the lock is free.
    refute Enum.any?(turn(session, "after"), &(&1.type == :notice))
    assert File.read!(path(dir, session.id)) == before
    assert {:ok, _} = Session.resume(other_core(), sessions_dir: dir, id: session.id)
  end

  # The notice of a loss before the first subscribe reaches no client; the
  # snapshot tells the later client.
  test "the snapshot says whether the session saves", %{core: core, tmp_dir: dir} do
    {:ok, held} = Session.start(core, model: "test/ok", sessions_dir: dir)
    assert {:ok, %{persisting: true}, _ref} = Session.subscribe(held)

    {:ok, memory} = Session.start(core, model: "test/ok")
    assert {:ok, %{persisting: false}, _ref} = Session.subscribe(memory)

    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    Helyx.Test.LostLock.kill(session)
    assert {:ok, %{persisting: false}, _ref} = Session.subscribe(session)
  end

  test "a start whose lock file cannot be opened fails and writes nothing", %{
    core: core,
    tmp_dir: dir
  } do
    project = Helyx.Session.File.Scan.project_dir(dir, File.cwd!())
    File.mkdir_p!(project)
    File.chmod!(project, 0o500)
    on_exit(fn -> File.chmod(project, 0o700) end)

    assert {:error, {:lock_failed, "cannot open the lock file: " <> _}} =
             Session.start(core, model: "test/ok", sessions_dir: dir)

    assert File.ls!(project) == []
  end

  # Helyx.Session.File.mkdir/2 makes the folders before a start (#683).
  test "a take whose folder is missing makes no folder", %{tmp_dir: dir} do
    path = Path.join([dir, "gone", "sess00000001.jsonl"])

    assert {:error, {:lock_failed, "cannot open the lock file: " <> _}} =
             Lock.hold(path, fn -> {:ok, :taken} end)

    refute File.exists?(Path.dirname(path))
  end

  test "a resume whose lock file cannot be opened fails and changes nothing", %{
    core: core,
    tmp_dir: dir
  } do
    {session, path} = open_without_newline(core, dir)
    before = File.read!(path)
    stop_session(session, &GenServer.stop/1)
    File.rm!(Path.rootname(path) <> ".lock")
    File.mkdir!(Path.rootname(path) <> ".lock")

    assert {:error, {:lock_failed, "cannot open the lock file: " <> _}} =
             Session.resume(core, sessions_dir: dir, id: session.id)

    assert File.read!(path) == before
  end

  test "a resume that fails after the lock frees it", %{core: core, tmp_dir: dir} do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    turn(session, "hi")
    stop_session(session, &GenServer.stop/1)
    path = path(dir, session.id)
    File.write!(path, String.replace(File.read!(path), ~s("test/ok"), ~s("gone/ok")))

    assert {:error, {:unknown_provider, "gone"}} =
             Session.resume(core, sessions_dir: dir, id: session.id)

    assert {:ok, lock, :taken} = Lock.hold(path, fn -> {:ok, :taken} end)
    Lock.release(lock)
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

  # The lock is taken in the session process, so a start request that never
  # reaches the supervisor takes no lock and writes nothing.
  test "a start request that exits takes no lock and writes nothing", %{core: core, tmp_dir: dir} do
    {sup, caller, ref} =
      park_start(core, fn -> Session.start(core, model: "test/ok", sessions_dir: dir) end)

    Process.exit(sup, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, {:killed, _call}}
    # The folders come before the request (#683), so only they are left.
    assert Path.wildcard(Path.join([dir, "**"])) |> Enum.filter(&File.regular?/1) == []
  end

  # The caller never owns the port, so its death holds no lock (#589).
  test "a caller killed during its start request leaves the lock free", %{
    core: core,
    tmp_dir: dir
  } do
    {_session, path, sup} = park_resume_and_kill_caller(core, dir)
    Process.exit(sup, :kill)

    assert {:ok, lock, :taken} = Lock.hold(path, fn -> {:ok, :taken} end)
    Lock.release(lock)
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

  # Starts, in a new caller, a session whose open waits under the lock until
  # the test sends `:go`. `bounds` sets fields of the state, such as
  # `open_ms`. Returns the caller, the session process, and the session path.
  defp start_held(core, dir, bounds \\ []) do
    test = self()
    {state, tools, path} = start_args(core, dir)
    state = struct!(state, bounds)

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
        send(test, {:started, Helyx.Session.Server.start(state, tools, open)})
      end)

    assert_receive {:in_open, pid}
    {caller, pid, path}
  end

  # The deadline of the open kills the session process, so its port closes
  # and perl frees the lock (#665). It counts from before the take, which
  # takes a few ms; the rest is the margin for load, so the open is reached.
  @load_open_ms 500

  test "an open past its deadline gives :open_timeout, and no session and no lock are left", %{
    core: core,
    tmp_dir: dir
  } do
    {_caller, pid, path} = start_held(core, dir, open_ms: @load_open_ms)

    assert_receive {:started, {:error, :open_timeout}}
    refute Process.alive?(pid)
    await_lock_free(path, "the lock of the killed session to free")
  end

  test "a caller that ends during an open past its deadline leaves no session and no lock", %{
    core: core,
    tmp_dir: dir
  } do
    {caller, pid, path} = start_held(core, dir, open_ms: @load_open_ms)
    ref = Process.monitor(pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, _, :process, ^caller, :killed}

    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    await_lock_free(path, "the lock of the killed session to free")
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

  test "a caller that ends during its open leaves no session and no lock", %{
    core: core,
    tmp_dir: dir
  } do
    {caller, pid, path} = start_held(core, dir)
    ref = Process.monitor(pid)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, _, :process, ^caller, :killed}

    # The session checks for its `:DOWN` of the caller once, after the open.
    await_down(pid, caller, "the session to get the end of its caller")

    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    await_lock_free(path, "the lock of the session to free")
  end

  # The start request reaches the supervisor after its caller ended, so the
  # session gets no go and runs no open: the file keeps its missing newline.
  test "a caller killed before its start reaches the supervisor leaves no session and no lock", %{
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
    await_lock_free(path, "the lock to be free")
  end

  # The release waits 1000 ms for a perl that does not end.
  @tag :slow
  test "a stop past the release bound returns, and perl frees the lock when it ends", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    pid = Session.pid(session)
    {:os_pid, os_pid} = Port.info(:sys.get_state(pid).lock, :os_pid)
    os_pid = Integer.to_string(os_pid)

    {_, 0} = System.cmd("kill", ["-STOP", os_pid])
    :ok = GenServer.stop(pid)

    path = path(dir, session.id)
    assert Lock.hold(path, fn -> {:ok, :taken} end) == {:error, {:session_locked, session.id}}

    {_, 0} = System.cmd("kill", ["-CONT", os_pid])

    await_lock_free(path, "perl to free the lock when it ends")
  end

  # perl ends during the open, as during the resume read in the session's
  # open: the open returns, and the owner, which traps exits as the session
  # does, gets the exit of the port. The session handles it as a lock lost
  # while it runs.
  test "an open whose perl ends during it sends the exit of the port", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    path = Path.join(dir, "abc.jsonl")

    kill_own_perl = fn ->
      [port] = for p <- Port.list(), Port.info(p, :connected) == {:connected, self()}, do: p
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])
      await(fn -> Port.info(port) == nil end, "the port of the killed perl to close")
      {:ok, :taken}
    end

    assert {:ok, lock, :taken} = Lock.hold(path, kill_own_perl)
    assert_receive {:EXIT, ^lock, _reason}
    assert Lock.release(lock) == :ok

    assert {:ok, lock, :taken} = Lock.hold(path, fn -> {:ok, :taken} end)
    Lock.release(lock)
  end

  # The disk is a boundary: a lock path that is not a regular file fails at
  # once, and no perl process is left. perl's arguments hold the lock path,
  # so pgrep finds it.
  test "a lock path that is not a regular file fails, and no perl is left", %{tmp_dir: dir} do
    fifo = Path.join(dir, "fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])

    for {name, make} <- [
          {"fifo", &System.cmd("mkfifo", [&1])},
          {"link", &File.ln_s!(fifo, &1)},
          {"device", &File.ln_s!("/dev/null", &1)},
          {"dir", &File.mkdir!/1}
        ] do
      lock = Path.join(dir, name <> ".lock")
      make.(lock)

      assert {:error, {:lock_failed, "cannot open the lock file: " <> _}} =
               Lock.hold(Path.join(dir, name <> ".jsonl"), fn -> {:ok, :taken} end)

      await(
        fn -> match?({_, 1}, System.cmd("pgrep", ["-f", lock])) end,
        "no perl process for #{name}"
      )
    end
  end

  # The caller monitors the session before the go, so a crash of the open
  # reaches it with its reason, not `:noproc`.
  @tag capture_log: true
  test "an open that raises gives the crash as an error, and the lock is free", %{
    core: core,
    tmp_dir: dir
  } do
    {state, tools, path} = start_args(core, dir)
    open = {path, fn _state -> raise "open" end}

    assert {:error, {%RuntimeError{message: "open"}, [_ | _]}} =
             Helyx.Session.Server.start(state, tools, open)

    await_lock_free(path, "the lock of the crashed session to free")
  end
end
