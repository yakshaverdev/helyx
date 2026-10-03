defmodule Helyx.Tool.BashTest do
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Bash]})

    %{
      core: core,
      run: fn args ->
        ToolRunner.run_tool(core, %ToolCall{id: "c", name: "bash", arguments: args}, dir)
      end
    }
  end

  # Starts a session whose one turn runs `command`, and returns the session
  # once the command is running.
  defp start_command(core, dir, command) do
    call = %ToolCall{id: "c", name: "bash", arguments: %{"command" => command}}
    :ok = Helyx.Provider.Fake.script(core, "abort", [[call]])
    {:ok, session} = Helyx.Session.start(core, model: "fake/abort", cwd: dir)
    {:ok, _, _} = Helyx.Session.subscribe(session)
    :ok = Helyx.Session.prompt(session, "go")

    assert_receive {:helyx_event,
                    %Helyx.Event{type: :message_end, data: %{message: %{role: :assistant}}}}

    session
  end

  test "runs in the working directory and merges stderr", %{tmp_dir: dir, run: run} do
    result = run.(%{"command" => "pwd; echo err >&2"})
    refute result.is_error
    assert Helyx.Message.text(result) == "#{dir}\nerr\n"
  end

  test "a non-zero exit code is in the text, not an error result", %{run: run} do
    result = run.(%{"command" => "echo partial; exit 3"})
    refute result.is_error
    assert Helyx.Message.text(result) == "partial\n\nExit code: 3"
  end

  test "no output says so", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "true"})) == "(no output)"
  end

  test "output with invalid bytes is delivered as valid text", %{run: run} do
    result = run.(%{"command" => ~S|printf 'a\xffb'|})
    refute result.is_error
    assert Helyx.Message.text(result) == "a�b"
  end

  test "long output is cut from the head end and says so", %{run: run} do
    text = Helyx.Message.text(run.(%{"command" => "seq 1 3000"}))
    assert String.starts_with?(text, "[truncated: showing lines 1001-3000 of 3000]\n1001\n")
  end

  test "the kept tail is cut at twice the cap, to the cap" do
    keep = 4 * Helyx.Text.max_bytes()

    # One byte under twice the cap and at it, nothing is cut; one byte over is.
    under = String.duplicate("x", 2 * keep - 1)
    assert Helyx.Tool.Bash.keep_tail(under) == {under, false}
    at = String.duplicate("x", 2 * keep)
    assert Helyx.Tool.Bash.keep_tail(at) == {at, false}
    assert {<<_::binary-size(keep)>>, true} = Helyx.Tool.Bash.keep_tail(at <> "x")
  end

  test "output beyond the buffer is dropped while the command runs", %{run: run} do
    text = Helyx.Message.text(run.(%{"command" => "seq 1 200000"}))

    assert String.starts_with?(
             text,
             "[output cut: only the last 204800 bytes were kept]\n[truncated:"
           )

    [_, total] = Regex.run(~r/of (\d+)\]/, text)
    assert String.to_integer(total) < 200_000
    assert String.ends_with?(text, "\n200000")
  end

  test "the command runs in its own process group", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "ps -o pgid= -p $$ | tr -d ' '; echo $$"})) =~
             ~r/^(\d+)\n\1\n$/
  end

  test "the command does not wait on stdin", %{run: run} do
    assert Helyx.Message.text(run.(%{"command" => "cat"})) == "(no output)"
  end

  test "missing arguments are an error result", %{run: run} do
    assert run.(%{}).is_error
  end

  test "a command with a NUL byte is an error result", %{tmp_dir: dir, run: run} do
    result = run.(%{"command" => "echo hi" <> <<0>> <> "; touch #{Path.join(dir, "ran")}"})
    assert result.is_error
    assert Helyx.Message.text(result) =~ "NUL"
    refute File.exists?(Path.join(dir, "ran"))
  end

  test "a working directory the watchdog cannot enter is an error, not exit code 2 (issue #52)",
       %{tmp_dir: dir} do
    gone = Path.join(dir, "gone")
    File.mkdir_p!(gone)
    File.rmdir!(gone)

    assert {:error, text} =
             Helyx.Tool.Bash.run(%{"command" => "touch #{Path.join(dir, "ran")}"}, gone)

    assert text =~ "did not start"
    assert text =~ gone
    assert text =~ "No such file"
    refute File.exists?(Path.join(dir, "ran"))
  end

  test "an empty working directory is the same error (issue #52)" do
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, "")
    assert text =~ "did not start"
  end

  test "a real exit status 2 is an ok result (issue #52)", %{tmp_dir: dir} do
    assert {:ok, "(no output)\nExit code: 2"} =
             Helyx.Tool.Bash.run(%{"command" => "exit 2"}, dir)
  end

  test "a command whose first output looks like a marker still ran (issue #52)",
       %{tmp_dir: dir} do
    assert {:ok, "0\nnope\n"} = Helyx.Tool.Bash.run(%{"command" => "echo 0; echo nope"}, dir)
  end

  test "a real exit 127, 137, or 255 is an ok result (issue #70)", %{tmp_dir: dir} do
    for {command, status} <- [{"exit 127", 127}, {"kill -KILL $$", 137}, {"exit 255", 255}] do
      assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => command}, dir)
      assert text == "(no output)\nExit code: #{status}"
    end
  end

  test "a reason over the result limit is cut (issue #52)" do
    cwd = "/" <> String.duplicate("x", 60_000)
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, cwd)
    assert "the command did not start: " <> reason = text
    assert byte_size(reason) == Helyx.Watchdog.reason_max_bytes()
  end

  test "a detached background child does not survive the call", %{run: run} do
    pid =
      run.(%{"command" => "sleep 60 >/dev/null 2>&1 & echo $!"})
      |> Helyx.Message.text()
      |> String.trim()

    assert gone_within?(pid)
  end

  test "abort ends the command and its children", %{core: core, tmp_dir: dir} do
    session = start_command(core, dir, "echo $$ > pid; sleep 60 & echo $! > child; wait")
    pid = wait_for_pid(Path.join(dir, "pid"))
    child = wait_for_pid(Path.join(dir, "child"))

    :ok = Helyx.Session.abort(session)
    refute os_alive?(pid)
    refute os_alive?(child)
    assert_receive {:helyx_event, %Helyx.Event{type: :turn_end, data: %{outcome: :aborted}}}
  end

  # The window: the shell exits (the port closes) before the tool Task runs
  # its cleanup, and the abort lands in between. Suspending the Task holds it
  # in that window deterministically. Only the group registered with the
  # hands can catch the child; there is no port left to scan and the Task is
  # brutally killed.
  @tag :slow
  test "abort kills the child of a shell that already exited", %{core: core, tmp_dir: dir} do
    session =
      start_command(
        core,
        dir,
        "echo $$ > pid; sleep 60 >/dev/null 2>&1 & echo $! > child; sleep 1"
      )

    pid = wait_for_pid(Path.join(dir, "pid"))
    child = wait_for_pid(Path.join(dir, "child"))
    provider = :sys.get_state(Helyx.Session.pid(session)).conn.pid

    # The provider process is a Task of the hands too.
    [task_pid] =
      for task <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)),
          task != provider,
          {:dictionary, dict} = Process.info(task, :dictionary),
          Keyword.has_key?(dict, :helyx_hands) do
        task
      end

    true = :erlang.suspend_process(task_pid)
    assert gone_within?(pid), "the shell did not exit"

    :ok = Helyx.Session.abort(session)
    refute os_alive?(child)
  end

  test "a command that ignores TERM is killed after the grace period", %{core: core, tmp_dir: dir} do
    session = start_command(core, dir, "trap '' TERM; echo $$ > pid; sleep 60")
    pid = wait_for_pid(Path.join(dir, "pid"))

    :ok = Helyx.Session.abort(session)
    refute os_alive?(pid)
  end

  # The link chain (ADR 0004): a killed hands takes the tool Task with it,
  # the Task's death closes the port, and the watchdog kills the command.
  @tag :capture_log
  test "killing the hands kills the Task and the command", %{core: core, tmp_dir: dir} do
    session = start_command(core, dir, "echo $$ > pid; exec sleep 30")
    pid = wait_for_pid(Path.join(dir, "pid"))
    %{hands: hands, conn: %{pid: provider}} = :sys.get_state(Helyx.Session.pid(session))

    # The provider process is a Task of the hands too.
    [task] =
      for task <- Task.Supervisor.children(Helyx.Core.task_supervisor(core)),
          task != provider,
          {:dictionary, dict} = Process.info(task, :dictionary),
          Keyword.has_key?(dict, :helyx_hands) do
        task
      end

    ref = Process.monitor(task)
    Process.exit(hands, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert gone_within?(pid)
  end

  test "stopping Core normally ends a running command", %{tmp_dir: dir} do
    core = :"core_stop_#{System.unique_integer([:positive])}"
    {:ok, sup} = Helyx.Core.start_link(name: core, plugins: [Fake, Helyx.Tool.Bash])

    _session = start_command(core, dir, "echo $$ > pid; exec sleep 30")
    pid = wait_for_pid(Path.join(dir, "pid"))

    :ok = Supervisor.stop(sup)
    assert gone_within?(pid)
  end

  test "check reports a system without perl" do
    assert :ok = Helyx.Tool.Bash.check()
    assert {:error, message} = Helyx.Tool.Bash.check(fn _ -> nil end)
    assert message =~ "perl"
  end
end
