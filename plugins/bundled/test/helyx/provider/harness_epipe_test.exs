defmodule Helyx.Provider.HarnessEpipeTest do
  # A write to a dead watchdog after the go-ahead (#167, #390). A `perl` on
  # PATH leaves a `sleep` with the port's stdout, but not its stdin, so the
  # port stays open after the watchdog dies. The `sleep` runs in a group of
  # its own, so the release does not wait for it in the watchdog's group.
  # PATH is global, so the module is not async.
  use ExUnit.Case, async: false

  import Helyx.Test.CodexFake, only: [j: 1, thread: 1, start: 1]
  import Helyx.Test.OSHelpers

  alias Helyx.Provider.{ClaudeCode, Codex}
  alias Helyx.Session

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    perl = Path.join(bin, "perl")

    File.write!(perl, """
    #!/bin/sh
    #{System.find_executable("perl")} -e 'setpgrp(0, 0); exec "sleep", 30' </dev/null &
    echo $! > #{Path.join(dir, "sleep")}
    exec #{System.find_executable("perl")} "$@"
    """)

    File.chmod!(perl, 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    on_exit(fn ->
      System.cmd("kill", ["-KILL", wait_for_pid(Path.join(dir, "sleep"))])
    end)

    %{bin: bin, dir: dir}
  end

  defp program(bin, name, script) do
    File.write!(Path.join(bin, name), "#!/bin/sh\n" <> script)
    File.chmod!(Path.join(bin, name), 0o755)
  end

  # Polls the port queue every 10 ms, for at least `ms`: the BEAM has no
  # event for bytes that wait in a port's driver queue.
  defp kill_when_queued(watchdog, ms \\ Helyx.Test.Events.wait_ms())

  defp kill_when_queued(_watchdog, ms) when ms <= 0, do: flunk("the port queue stayed empty")

  defp kill_when_queued(watchdog, ms) do
    if Enum.any?(Port.list(), &queued?(&1, watchdog)) do
      System.cmd("kill", ["-KILL", watchdog])
    else
      Process.sleep(10)
      kill_when_queued(watchdog, ms - 10)
    end
  end

  defp queued?(port, watchdog) do
    Port.info(port, :os_pid) == {:os_pid, String.to_integer(watchdog)} and
      match?({:queue_size, n} when n > 0, Port.info(port, :queue_size))
  end

  # The generic failure path (#390): the fake codex stops its watchdog,
  # then answers `initialize` and `thread/start`, so the `turn/start` line
  # with the prompt waits in the port's queue. The test kills the watchdog
  # only: the queued bytes get `EPIPE`, the port closes with `:epipe`, and
  # its exit signal ends the provider process. The session fails the turn
  # and lives on, and the hands' release ends the program group (ADR 0004).
  test "a write to a dead watchdog ends the provider process and fails the turn",
       %{bin: bin, dir: dir} do
    init = j(%{id: 1, result: %{userAgent: "fake", platformOs: "macos"}})
    start = j(%{id: 2, result: %{thread: thread("t1")}})

    program(bin, "codex", """
    echo $PPID > #{Path.join(dir, "watchdog")}
    echo $$ > #{Path.join(dir, "group")}
    kill -STOP $PPID
    printf '%s\\n' '#{init}' '#{start}'
    exec sleep 30
    """)

    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Codex]})
    session = start(%{core: core, work: dir, sessions: Path.join(dir, "sessions")})
    :ok = Session.prompt(session, String.duplicate("x", 400_000))

    group = wait_for_pid(Path.join(dir, "group"))
    kill_when_queued(wait_for_pid(Path.join(dir, "watchdog")))

    assert List.last(Helyx.Test.Events.collect_until(:turn_end)).data.error ==
             {:task_exit, :epipe}

    assert Process.alive?(Session.pid(session))
    assert group_gone_within?(group)
  end

  # The provider process does not trap exits: an abort while the start
  # waits for the hold of the command group ends it at once.
  # The name holds no quote: `tmp_dir` puts it in the path that the fake
  # perl of `setup` holds unquoted.
  test "Claude Code: a shutdown of the hands during the start ends the harness at once",
       %{bin: bin} do
    program(bin, "claude", "exec sleep 30\n")
    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:helyx_hands, test)
        ClaudeCode.init("haiku", [], cwd: File.cwd!())
      end)

    assert_receive {:"$gen_call", from, {:hold, {:watchdog, _watchdog}}}
    GenServer.reply(from, :ok)
    assert_receive {:"$gen_call", _from, {:hold, {:command, group}}}
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}
    assert group_gone_within?(group)
  end
end
