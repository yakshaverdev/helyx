defmodule Helyx.Provider.HarnessEpipeTest do
  # A write to a dead watchdog after the go-ahead (issue #167). A `perl` on
  # PATH leaves a `sleep` with the port's stdout, but not its stdin, so the
  # port stays open after the watchdog dies. The watchdog is stopped, a
  # write of 400,000 bytes fills its stdin pipe and waits in the port's
  # queue, and the stand-in hands then kill the watchdog: the queued bytes
  # get `EPIPE` every time. PATH is global, so the module is not async.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  alias Helyx.Message
  alias Helyx.Provider.{ClaudeCode, Codex}

  @moduletag :tmp_dir

  @big String.duplicate("x", 400_000)

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    perl = Path.join(bin, "perl")

    File.write!(perl, """
    #!/bin/sh
    sleep 30 </dev/null &
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

    %{bin: bin}
  end

  defp program(bin, name, script) do
    File.write!(Path.join(bin, name), "#!/bin/sh\n" <> script)
    File.chmod!(Path.join(bin, name), 0o755)
  end

  # Stands in for the hands. At the hold of the command group it calls
  # `on_command` with the watchdog, then replies. When the port has bytes
  # in its queue, it kills the watchdog and the command group. It ends
  # after the stream process, so no exit signal of its own reaches it. Its
  # link ends it with the stream process when `run/3` kills that one.
  defp hands(on_command) do
    stream = self()

    hands =
      spawn_link(fn ->
        ref = Process.monitor(stream)

        watchdog =
          receive do
            {:"$gen_call", from, {:hold, {:watchdog, watchdog}}} ->
              GenServer.reply(from, :ok)
              watchdog
          end

        receive do
          {:"$gen_call", from, {:hold, {:command, group}}} ->
            on_command.(watchdog)
            GenServer.reply(from, :ok)
            kill_when_queued(watchdog, group)
        end

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        end
      end)

    Process.put(:helyx_hands, hands)
  end

  defp kill_when_queued(watchdog, group) do
    if Enum.any?(Port.list(), &queued?(&1, watchdog)) do
      System.cmd("kill", ["-KILL", "#{watchdog}"])
      System.cmd("kill", ["-KILL", "--", "-#{group}"], stderr_to_stdout: true)
    else
      Process.sleep(10)
      kill_when_queued(watchdog, group)
    end
  end

  defp queued?(port, watchdog) do
    Port.info(port, :os_pid) == {:os_pid, watchdog} and
      match?({:queue_size, n} when n > 0, Port.info(port, :queue_size))
  end

  # The connected provider runs in a process that does not trap exits, as
  # the harness process does not. Its turn writes the prompt, and the
  # port's `:DOWN` stops it.
  test "Claude Code: queued input to a dead watchdog stops the harness", %{bin: bin} do
    program(bin, "claude", "exec sleep 30\n")
    stop = fn watchdog -> System.cmd("kill", ["-STOP", "#{watchdog}"]) end
    test = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        hands(stop)
        {:ok, state} = ClaudeCode.harness_init("haiku", [], cwd: File.cwd!())
        context = %Helyx.Context{messages: [Message.user(@big)]}

        {:ok, _actions, state} =
          ClaudeCode.harness_request({:turn, "t1", context}, make_ref(), state)

        send(test, {:stopped, stopped(state)})
      end)

    receive do
      {:stopped, reason} -> assert reason == {:claude_code_exit, :epipe}
      {:DOWN, ^ref, :process, _pid, reason} -> flunk("the harness ended on #{inspect(reason)}")
    after
      5_000 -> flunk("the harness did not stop")
    end
  end

  defp stopped(state) do
    receive do
      message ->
        case ClaudeCode.harness_info(message, state) do
          {:ok, _actions, state} -> stopped(state)
          {:stop, reason, _state} -> reason
        end
    end
  end

  # The harness process does not trap exits: an abort while the start
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
        ClaudeCode.harness_init("haiku", [], cwd: File.cwd!())
      end)

    assert_receive {:"$gen_call", from, {:hold, {:watchdog, _watchdog}}}, 5_000
    GenServer.reply(from, :ok)
    assert_receive {:"$gen_call", _from, {:hold, {:command, group}}}, 5_000
    Process.exit(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, _pid, :shutdown}, 500
    assert group_gone_within?(group, 200)
  end

  # The fake codex stops its watchdog, then answers `initialize` and
  # `thread/start`, so the `turn/start` line with the prompt waits in the
  # queue. The harness process does not trap exits: the port's `:DOWN`
  # stops it.
  test "Codex: a queued line to a dead watchdog stops the harness process", %{bin: bin} do
    thread = %{id: "t1", cwd: "/work", model: "m", path: "/r.jsonl"}
    init = JSON.encode!(%{id: 1, result: %{userAgent: "fake", platformOs: "macos"}})
    start = JSON.encode!(%{id: 3, result: %{thread: thread}})

    program(bin, "codex", """
    kill -STOP $PPID
    printf '%s\\n' '#{init}' '#{start}'
    exec sleep 30
    """)

    test = self()

    {pid, ref} =
      spawn_monitor(fn ->
        hands(fn _watchdog -> :ok end)
        {:ok, state} = Codex.harness_init("m", [], cwd: File.cwd!())
        context = %Helyx.Context{messages: [Message.user(@big)]}
        {:ok, _actions, state} = Codex.harness_request({:turn, "t", context}, make_ref(), state)
        send(test, {:stop, stop(state)})
      end)

    receive do
      {:stop, reason} -> assert reason == {:codex_exit, :epipe}
      {:DOWN, ^ref, :process, _pid, reason} -> flunk("the harness ended on #{inspect(reason)}")
    after
      5_000 ->
        Process.exit(pid, :kill)
        flunk("the harness did not stop")
    end
  end

  defp stop(state) do
    receive do
      message ->
        case Codex.harness_info(message, state) do
          {:ok, _actions, state} -> stop(state)
          {:stop, reason, _state} -> reason
        end
    end
  end
end
