defmodule Helyx.Session.LockTest do
  # The writer lock of a session file (#579, docs/features/session-lock.md).
  # A second Core in the node takes the place of a second OS process: each
  # take runs its own perl process.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

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

  test "a session that another Core holds does not open, and its file is unchanged", %{
    core: core,
    tmp_dir: dir
  } do
    {session, path} = open_without_newline(core, dir)
    before = File.read!(path)
    id = session.id

    assert Session.resume(other_core(), sessions_dir: dir, id: id) ==
             {:error, {:session_locked, id}}

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
    stop_session(session, &Process.exit(&1, :kill))
    other = other_core()

    # perl exits when it reads the end of its stdin, after the kill.
    await(
      fn -> match?({:ok, _}, Session.resume(other, sessions_dir: dir, id: session.id)) end,
      "the lock of the killed session to free"
    )
  end

  test "perl killed while the session runs gives one notice, and the session goes on", %{
    core: core,
    tmp_dir: dir
  } do
    {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    {:ok, _, _} = Session.subscribe(session)
    pid = Session.pid(session)
    {:os_pid, os_pid} = Port.info(:sys.get_state(pid).lock, :os_pid)

    {_, 0} = System.cmd("kill", ["-9", Integer.to_string(os_pid)])

    assert_receive {:helyx_event, %Event{type: :notice, turn_id: nil, data: %{text: text}}}
    assert text =~ "the session lock is lost"
    assert :sys.get_state(pid).lock == nil

    # The session lives and still writes its file; the lock is free.
    refute Enum.any?(turn(session, "after"), &(&1.type == :notice))
    assert File.read!(path(dir, session.id)) =~ "after"
    assert {:ok, _} = Session.resume(other_core(), sessions_dir: dir, id: session.id)
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

  test "a start request that exits frees the lock", %{core: core, tmp_dir: dir} do
    sup = Process.whereis(Helyx.Core.session_supervisor(core))
    :ok = :sys.suspend(sup)

    {caller, ref} =
      spawn_monitor(fn -> Session.start(core, model: "test/ok", sessions_dir: dir) end)

    await(
      fn -> Process.info(sup, :message_queue_len) == {:message_queue_len, 1} end,
      "the start request to reach the supervisor"
    )

    Process.exit(sup, :kill)
    assert_receive {:DOWN, ^ref, :process, ^caller, {:killed, _call}}

    [path] = Path.wildcard(Path.join([dir, "*", "*.jsonl"]))
    assert {:ok, lock, :taken} = Lock.hold(path, fn -> {:ok, :taken} end)
    Lock.release(lock)
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

    await(
      fn ->
        case Lock.hold(path, fn -> {:ok, :taken} end) do
          {:ok, lock, :taken} -> Lock.release(lock) == :ok
          {:error, {:session_locked, _id}} -> false
        end
      end,
      "perl to free the lock when it ends"
    )
  end

  test "a raise after the take frees the lock", %{tmp_dir: dir} do
    path = Path.join(dir, "abc.jsonl")
    assert_raise RuntimeError, "boom", fn -> Lock.hold(path, fn -> raise "boom" end) end
    assert {:ok, lock, :taken} = Lock.hold(path, fn -> {:ok, :taken} end)
    Lock.release(lock)
  end

  test "the lock errors have their Helyx.Reason text" do
    assert Helyx.Reason.text({:session_locked, "abc"}) == "session abc is open in another process"

    assert Helyx.Reason.text({:lock_failed, "perl is not on the PATH"}) ==
             "could not lock the session: perl is not on the PATH"
  end
end
