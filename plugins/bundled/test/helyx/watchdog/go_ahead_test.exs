defmodule Helyx.Watchdog.GoAheadTest do
  # A go-ahead write to a dead watchdog (issue #131). A `perl` on PATH that
  # leaves a `sleep` with the port's stdout, but not its stdin, keeps the
  # port open after the watchdog and the held command are dead, so a write
  # fails with `EPIPE` every time. PATH is global, so the module is not
  # async.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  @moduletag :tmp_dir

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

    :ok
  end

  # Stands in for the hands. At the hold of the command group it calls
  # `on_command` with the watchdog and the group, then replies.
  defp hands(on_command) do
    hands =
      spawn_link(fn ->
        watchdog =
          receive do
            {:"$gen_call", from, {:hold, {:watchdog, watchdog}}} ->
              GenServer.reply(from, :ok)
              watchdog
          end

        receive do
          {:"$gen_call", from, {:hold, {:command, group}}} ->
            on_command.(watchdog, group)
            GenServer.reply(from, :ok)
        end
      end)

    Process.put(:helyx_hands, hands)
  end

  defp kill_and_await(watchdog, group) do
    System.cmd("kill", ["-KILL", "#{watchdog}"])
    signal_group("KILL", group)
    assert gone_within?(watchdog, 2_000)
    assert group_gone_within?(group, 2_000)
  end

  # The watchdog and the group are dead before the go-ahead: its stdin has
  # no reader.
  defp dead_before_go_ahead, do: hands(&kill_and_await/2)

  defp harness_start(dir) do
    state = %{port: nil, buffer: [], size: 0, terminal: nil}
    Helyx.HarnessIO.start(["true"], dir, :open, state)
  end

  test "the bash tool reports that the command did not start", %{tmp_dir: dir} do
    dead_before_go_ahead()
    ran = Path.join(dir, "ran")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "touch #{ran}"}, dir)
    assert text =~ "did not start: the perl watchdog died before the go-ahead"
    refute File.exists?(ran)
  end

  test "a harness run ends with :not_started", %{tmp_dir: dir} do
    dead_before_go_ahead()
    assert %{terminal: {:error, {:not_started, text}}} = harness_start(dir)
    assert text =~ "died before the go-ahead"
  end

  test "a caller that traps exits gets the same result, and no exit message",
       %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    dead_before_go_ahead()
    assert %{terminal: {:error, {:not_started, _}}} = harness_start(dir)
    {:messages, messages} = Process.info(self(), :messages)
    refute Enum.any?(messages, &match?({:EXIT, port, _reason} when is_port(port), &1))
  end
end
