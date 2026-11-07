defmodule Helyx.Hook.CommandSessionTest do
  # `Helyx.Hook.Command` read from its env and run by a session
  # (docs/features/command-hook.md). Not async: the env key
  # `:command_hook` of `helyx_plugins` is global.
  use ExUnit.Case, async: false

  alias Helyx.Message.ToolCall
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  setup do
    on_exit(fn -> Application.delete_env(:helyx_plugins, :command_hook) end)
  end

  defp put_env(env), do: Application.put_env(:helyx_plugins, :command_hook, env)

  defp start_core(plugins) do
    Helyx.Core.start_link(
      name: :"command_hook_#{System.unique_integer([:positive])}",
      plugins: plugins
    )
  end

  defp core do
    core = :"command_hook_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Helyx.Core,
       name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Bash, Helyx.Hook.Command]}
    )

    core
  end

  defp bash(core, dir, command) do
    call = %ToolCall{id: "c1", name: "bash", arguments: %{"command" => command}}
    ToolRunner.run_tool(core, call, dir)
  end

  describe "limit/1" do
    test "the limit_ms of the point, else 60,000" do
      put_env(before_tool: [command: "x", limit_ms: 1_500])
      assert Helyx.Hook.Command.limit(:before_tool) == 1_500
      assert Helyx.Hook.Command.limit(:after_tool) == 60_000

      for env <- [nil, :bad, [before_tool: :bad], [before_tool: [command: "x"]]] do
        put_env(env)
        assert Helyx.Hook.Command.limit(:before_tool) == 60_000
      end
    end

    test "Core checks it: a bad limit_ms stops the start" do
      put_env(after_tool: [command: "x", limit_ms: 600_001])

      assert start_core([Helyx.Provider.Fake, Helyx.Hook.Command]) ==
               {:error, {:invalid_hook_limit, Helyx.Hook.Command}}

      put_env(after_tool: [command: "x", limit_ms: 600_000])
      assert {:ok, pid} = start_core([Helyx.Provider.Fake, Helyx.Hook.Command])
      Supervisor.stop(pid)
    end
  end

  describe "in a session" do
    test "exit 2 denies the call with standard error, and the call does not run",
         %{tmp_dir: dir} do
      put_env(before_tool: [command: "echo not here >&2; exit 2"])
      result = bash(core(), dir, "touch ran")
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "the hook Helyx.Hook.Command denied the call: not here\n"

      refute File.exists?(Path.join(dir, "ran"))
    end

    test "a failure denies the call, and an after_tool exit 2 adds to the result",
         %{tmp_dir: dir} do
      put_env(before_tool: [command: "exit 1"])
      core = core()

      assert Helyx.Message.text(bash(core, dir, "echo hi")) ==
               "the hook Helyx.Hook.Command failed: the command exited with status 1; " <>
                 "the call was not run"

      put_env(after_tool: [command: "echo checked >&2; exit 2"])

      assert Helyx.Message.text(bash(core, dir, "echo hi")) ==
               "hi\n\n\nThe hook Helyx.Hook.Command added: checked\n"
    end

    # The command's TERM cleanup takes `@cleanup_s`; the grace of the
    # release is `Helyx.Watchdog.grace_ms/0`, 500 ms, so 300 ms of it is the
    # margin for load. A KILL with no grace ends the command before it.
    @cleanup_s 0.2

    test "at its limit the command gets the TERM grace, then its group is released",
         %{tmp_dir: dir} do
      put_env(
        before_tool: [
          command:
            "trap 'sleep #{@cleanup_s}; echo done > cleaned; exit 0' TERM; " <>
              "echo $$ > pid; sleep 30 & wait",
          limit_ms: 800
        ]
      )

      result = bash(core(), dir, "echo hi")
      assert Helyx.Message.text(result) =~ "it ran past its limit of 800 ms"
      assert File.read!(Path.join(dir, "cleaned")) == "done\n"
      pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
      assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end

    test "a change of the env after the start changes the command, not the limit",
         %{tmp_dir: dir} do
      put_env(before_tool: [command: "exit 0", limit_ms: 5_000])
      core = core()
      # 300 ms of work against a limit of 100 in the env and 5,000 in Core.
      put_env(before_tool: [command: "sleep 0.3; exit 2", limit_ms: 100])

      assert Helyx.Message.text(bash(core, dir, "echo hi")) ==
               "the hook Helyx.Hook.Command denied the call: the command exited with status 2"
    end

    test "at its limit the command is killed and its group released", %{tmp_dir: dir} do
      put_env(before_tool: [command: "echo $$ > pid; sleep 30", limit_ms: 800])
      core = core()
      result = bash(core, dir, "echo hi")

      assert Helyx.Message.text(result) ==
               "the hook Helyx.Hook.Command failed: it ran past its limit of 800 ms; " <>
                 "the call was not run"

      pid = dir |> Path.join("pid") |> File.read!() |> String.trim()
      assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0
    end
  end
end
