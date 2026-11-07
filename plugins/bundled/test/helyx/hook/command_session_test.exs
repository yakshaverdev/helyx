defmodule Helyx.Hook.CommandSessionTest do
  # `Helyx.Hook.Command` read from its env and run by a session
  # (docs/features/command-hook.md). Not async: the env key
  # `:command_hook` of `helyx_plugins` is global.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

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

    test "Core checks it: a bad limit_ms, nil included, stops the start" do
      for ms <- [600_001, nil] do
        put_env(after_tool: [command: "x", limit_ms: ms])

        assert start_core([Helyx.Provider.Fake, Helyx.Hook.Command]) ==
                 {:error, {:invalid_hook_limit, Helyx.Hook.Command}}
      end

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

    # The command's TERM cleanup must end within the grace of the release,
    # `Helyx.Watchdog.grace_ms/0`; this much of the grace is the margin for
    # load. A KILL with no grace ends the command before its cleanup.
    @load_ms 300
    @cleanup_ms Helyx.Watchdog.grace_ms() - @load_ms

    # Traps TERM with the cleanup, writes its process group, and waits on a
    # child in the group.
    @trapped "trap 'sleep #{@cleanup_ms / 1000}; echo done > cleaned; exit 0' TERM; " <>
               "perl -e 'print getpgrp' > pgid; sleep 30 & wait"

    test "at its limit the command gets the TERM grace, then its group is released",
         %{tmp_dir: dir} do
      put_env(before_tool: [command: @trapped, limit_ms: 800])
      result = bash(core(), dir, "echo hi")
      assert Helyx.Message.text(result) =~ "it ran past its limit of 800 ms"
      assert File.read!(Path.join(dir, "cleaned")) == "done\n"
      refute os_alive?("-" <> group(dir))
    end

    test "an abort gives the command its TERM grace and releases its group", %{tmp_dir: dir} do
      put_env(before_tool: [command: @trapped])
      call = %ToolCall{id: "c1", name: "bash", arguments: %{"command" => "touch ran"}}
      session = ToolRunner.start_tool(core(), call, dir)
      group = wait_for_pid(Path.join(dir, "pgid"))
      assert os_alive?("-" <> group)
      Helyx.Session.abort(session)
      # The turn ends after the cancel of the hands, which released the group.
      assert_receive {:helyx_event, %Helyx.Event{type: :turn_end}}, Helyx.Test.Events.wait_ms()
      assert File.read!(Path.join(dir, "cleaned")) == "done\n"
      refute os_alive?("-" <> group)
      refute File.exists?(Path.join(dir, "ran"))
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
      put_env(
        before_tool: [
          command: "perl -e 'print getpgrp' > pgid; sleep 30 & sleep 30",
          limit_ms: 800
        ]
      )

      result = bash(core(), dir, "echo hi")

      assert Helyx.Message.text(result) ==
               "the hook Helyx.Hook.Command failed: it ran past its limit of 800 ms; " <>
                 "the call was not run"

      refute os_alive?("-" <> group(dir))
    end
  end

  defp group(dir), do: dir |> Path.join("pgid") |> File.read!()
end
