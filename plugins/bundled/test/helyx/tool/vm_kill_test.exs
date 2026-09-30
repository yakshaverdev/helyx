defmodule Helyx.Tool.Bash.VMKillTest do
  # The whole-VM kill: `kill -9` of the BEAM leaves no process inside the VM
  # to clean up, so only the watchdog can end the command. A second BEAM is
  # booted with this project's code path and runs a command through a real
  # session; the second boot takes seconds, so this file is not async.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  @moduletag timeout: 120_000

  @tag :tmp_dir
  test "kill -9 of the BEAM ends the running command", %{tmp_dir: dir} do
    pidfile = Path.join(dir, "pid")

    script = """
    {:ok, _} =
      Helyx.Core.start_link(name: VMKillCore, plugins: [Helyx.Provider.Fake, Helyx.Tool.Bash])

    call = %Helyx.Message.ToolCall{
      id: "c",
      name: "bash",
      arguments: %{"command" => "echo $$ > #{pidfile}; exec sleep 60"}
    }

    :ok = Helyx.Provider.Fake.script(VMKillCore, "m", [[call], ["done"]])
    {:ok, session} = Helyx.Session.start(VMKillCore, model: "fake/m", cwd: #{inspect(dir)})
    :ok = Helyx.Session.prompt(session, "go")
    Process.sleep(120_000)
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, paths ++ ["-e", script]}
      ])

    # `elixir` execs into the BEAM, so the port's OS pid is the BEAM's.
    {:os_pid, beam} = Port.info(port, :os_pid)
    pid = wait_for_pid(pidfile, 30_000)
    {_, 0} = System.cmd("kill", ["-9", to_string(beam)])
    assert gone_within?(pid, 5_000)
  end
end
