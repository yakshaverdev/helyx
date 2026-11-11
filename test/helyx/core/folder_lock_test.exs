defmodule Helyx.Core.FolderLockTest do
  # The lock of the data folder of a Core (#579, #589, #833,
  # docs/features/session-lock.md). A second Core in the node takes the place
  # of a second OS process: each take runs its own perl process.
  use ExUnit.Case, async: true

  import Helyx.Test.SessionCase, only: [await: 2]

  alias Helyx.Session
  alias Helyx.Session.Lock
  alias Helyx.Test.PerlSignal

  @moduletag :tmp_dir

  @plugins [Helyx.Test.Provider]

  # A start that fails ends the supervisor it linked, and the caller gets
  # that exit.
  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp core_name, do: :"core_#{System.unique_integer([:positive])}"

  defp start_supervised_core(dir) do
    core = core_name()
    start_supervised!({Helyx.Core, name: core, plugins: @plugins, sessions_dir: dir}, id: core)
    core
  end

  defp start_bare_core do
    core = core_name()
    start_supervised!({Helyx.Core, name: core, plugins: @plugins}, id: core)
    core
  end

  defp start_core_link(dir) do
    core = core_name()
    {:ok, pid} = Helyx.Core.start_link(name: core, plugins: @plugins, sessions_dir: dir)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {core, pid}
  end

  defp lock_path(dir), do: Path.join(dir, "core.lock")

  defp perl_of(core, dir) do
    {_id, pid, _type, _modules} =
      Enum.find(Supervisor.which_children(core), fn {id, _, _, _} ->
        id == Helyx.Core.FolderLock
      end)

    %{port: port} = :sys.get_state(pid)
    PerlSignal.pid(port, lock_path(dir))
  end

  test "a second Core on one sessions folder fails at its start with :data_folder_locked", %{
    tmp_dir: dir
  } do
    _a = start_supervised_core(dir)
    b = core_name()

    assert Helyx.Core.start_link(name: b, plugins: @plugins, sessions_dir: dir) ==
             {:error, {:data_folder_locked, dir}}

    assert Process.whereis(b) == nil
  end

  test "a stop of Core frees the folder for the next Core", %{tmp_dir: dir} do
    {_a, pid} = start_core_link(dir)
    ref = Process.monitor(pid)
    :ok = Supervisor.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert_receive {:EXIT, ^pid, :normal}

    {b, pid} = start_core_link(dir)
    assert Process.alive?(pid)
    assert Process.whereis(b) == pid
  end

  test "a Core whose lock ends stops", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    {a, pid} = start_core_link(dir)
    ref = Process.monitor(pid)
    perl = perl_of(a, dir)

    PerlSignal.send!(perl, "KILL", lock_path(dir))

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000
    assert_receive {:EXIT, ^pid, :shutdown}

    {_b, pid} = start_core_link(dir)
    assert Process.alive?(pid)
  end

  # The session writes only in the folder that the Core locks
  # (docs/features/session-lock.md, decision 4).
  test "a sessions_dir that is not the folder of the Core is refused, and the same folder is accepted",
       %{tmp_dir: dir} do
    core = start_supervised_core(dir)
    other = Path.join(dir, "other")

    assert Session.start(core, model: "test/ok", sessions_dir: other) ==
             {:error, {:invalid_option, :sessions_dir}}

    assert Session.resume(core, sessions_dir: other, id: Helyx.Session.Id.new()) ==
             {:error, {:invalid_option, :sessions_dir}}

    refute File.exists?(other)

    assert {:ok, session} = Session.start(core, model: "test/ok", sessions_dir: dir)
    assert {:ok, ^session} = Session.resume(core, sessions_dir: dir, id: session.id)

    bare = start_bare_core()
    bare_other = Path.join(dir, "bare_other")

    assert Session.start(bare, model: "test/ok", sessions_dir: bare_other) ==
             {:error, {:invalid_option, :sessions_dir}}

    assert Session.resume(bare, sessions_dir: bare_other, id: Helyx.Session.Id.new()) ==
             {:error, {:invalid_option, :sessions_dir}}

    refute File.exists?(bare_other)
  end

  # Helyx.Session.File.mkdir/2 makes the folders before a start (#683).
  test "a take whose folder is missing makes no folder", %{tmp_dir: dir} do
    path = Path.join([dir, "gone", "sess00000001.jsonl"])

    assert {:error, {:lock_failed, "cannot open the lock file: " <> _}} = Lock.take(path)

    refute File.exists?(Path.dirname(path))
  end

  # The disk is a boundary: a lock path that is not a regular file fails at
  # once, and no perl process is left. perl's arguments hold the lock path,
  # so pgrep finds it.
  test "a core.lock that is not a regular file fails the start, and no perl is left", %{
    tmp_dir: dir
  } do
    fifo = Path.join(dir, "fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])

    for {name, make} <- [
          {"fifo", fn path -> System.cmd("mkfifo", [path]) end},
          {"link", &File.ln_s!(fifo, &1)},
          {"device", &File.ln_s!("/dev/null", &1)},
          {"dir", &File.mkdir!/1}
        ] do
      lock = lock_path(dir)
      make.(lock)
      core = core_name()

      assert {:error, {:lock_failed, "cannot open the lock file: " <> _}} =
               Helyx.Core.start_link(name: core, plugins: @plugins, sessions_dir: dir)

      await(
        fn -> match?({_, 1}, System.cmd("pgrep", ["-f", lock])) end,
        "no perl process for #{name}"
      )

      File.rm_rf!(lock)
    end
  end

  # The signals of these tests go only to the perl of a lock: a pid of 0
  # would signal the process group of the test VM (#833).
  test "the signal helper refuses a pid that is not the perl of the lock", %{tmp_dir: dir} do
    lock_path = Path.join(dir, "s.lock")
    assert_raise FunctionClauseError, fn -> PerlSignal.send!(0, "STOP", lock_path) end
    assert_raise FunctionClauseError, fn -> PerlSignal.send!(-1, "STOP", lock_path) end

    sleep = Port.open({:spawn_executable, System.find_executable("sleep")}, args: ["30"])
    {:os_pid, pid} = Port.info(sleep, :os_pid)
    # The check fails before the `kill`.
    assert_raise ExUnit.AssertionError, fn -> PerlSignal.send!(pid, "KILL", lock_path) end
    Port.close(sleep)
  end
end
