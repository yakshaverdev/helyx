defmodule Helyx.Tool.BashTest do
  use ExUnit.Case, async: true

  import Helyx.Test.OSHelpers

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # A direct `run/2` holds its groups with these hands.
    Helyx.Test.Hands.fake()
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Bash]})

    %{
      core: core,
      run: fn args ->
        ToolRunner.run_tool(core, %ToolCall{id: "c", name: "bash", arguments: args}, dir)
      end
    }
  end

  defp start_command(core, dir, command) do
    call = %ToolCall{id: "c", name: "bash", arguments: %{"command" => command}}
    ToolRunner.start_tool(core, call, dir)
  end

  # The release Task that the caller starts at the limit: its one linked
  # pid, polled for at most `ms`.
  defp release_task(caller, ms \\ Helyx.Test.Events.wait_ms()) do
    {:links, links} = Process.info(caller, :links)

    case {for(pid <- links, is_pid(pid), do: pid), ms} do
      {[task], _ms} ->
        task

      {[], ms} when ms > 0 ->
        Process.sleep(1)
        release_task(caller, ms - 1)

      _ ->
        flunk("the caller started no release Task")
    end
  end

  test "runs in the working directory and merges stderr", %{tmp_dir: dir, run: run} do
    result = run.(%{"command" => "pwd; echo err >&2"})
    refute result.is_error
    assert Helyx.Message.text(result) == "#{dir}\nerr\n"
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
    result = run.(%{})
    assert result.is_error
    assert Helyx.Message.text(result) == "bash needs a command"
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

  test "a command whose first output looks like a marker still ran (issue #52)",
       %{tmp_dir: dir} do
    assert {:ok, "0\nnope\n"} = Helyx.Tool.Bash.run(%{"command" => "echo 0; echo nope"}, dir)
  end

  # A failed start can also give 2, 127, 137, or 255: a command that exits
  # with one is not taken for a failed start (issues #52, #70).
  test "a non-zero exit code is in the text of an ok result", %{tmp_dir: dir} do
    for status <- [2, 3, 127, 137, 255] do
      command = if status == 137, do: "kill -KILL $$", else: "exit #{status}"
      assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => command}, dir)
      assert text == "(no output)\nExit code: #{status}"
    end

    assert {:ok, "partial\n\nExit code: 3"} =
             Helyx.Tool.Bash.run(%{"command" => "echo partial; exit 3"}, dir)
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
    true = :erlang.suspend_process(ToolRunner.running_tool(session).task)
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
  test "killing the hands kills the Task and the command", %{core: core, tmp_dir: dir} do
    session = start_command(core, dir, "echo $$ > pid; exec sleep 30")
    pid = wait_for_pid(Path.join(dir, "pid"))
    %{hands: hands, task: task} = ToolRunner.running_tool(session)
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

  describe "time limit (#482)" do
    test "a timeout outside 1..600 or not an integer is an error result; nothing runs",
         %{tmp_dir: dir} do
      ran = Path.join(dir, "ran")

      for timeout <- [0, -1, 601, 5.0, "5", true] do
        assert {:error, text} =
                 Helyx.Tool.Bash.run(%{"command" => "touch #{ran}", "timeout" => timeout}, dir)

        assert text =~ "timeout", inspect(timeout)
      end

      refute File.exists?(ran)
    end

    test "a timeout of 1, of 600, or null runs the command", %{tmp_dir: dir} do
      for timeout <- [600, nil] do
        assert {:ok, "hi\n"} =
                 Helyx.Tool.Bash.run(%{"command" => "echo hi", "timeout" => timeout}, dir)
      end

      # Under load the command can take more than 1 s, so the test checks
      # only that 1 passes the bound.
      refute {:error, "timeout must be an integer from 1 to 600 (seconds)"} ==
               Helyx.Tool.Bash.run(%{"command" => "echo hi", "timeout" => 1}, dir)
    end

    # The schema allows the background maximum; `run/2` checks the bound of
    # the mode.
    test "the spec and the description state the default and the maximum" do
      assert %{"type" => "integer", "minimum" => 1, "maximum" => 86_400} =
               Helyx.Tool.Bash.parameters()["properties"]["timeout"]

      for number <- ["120", "600", "3600", "86400"],
          do: assert(Helyx.Tool.Bash.description() =~ number)
    end

    # The limit of the tests below. It holds the start of perl and bash and
    # the first output under load (over 200 ms once, #562), so the output
    # comes before the limit. It is whole seconds, as every limit of a tool
    # call is.
    @load_start_ms 3_000
    @timed_out "Timed out after 3 s: the command group was released."

    # TERM first, as an abort: the trap's output is kept after the limit.
    @tag :slow
    test "at the limit the command group is released and the output so far is an error result",
         %{tmp_dir: dir} do
      command = "trap 'echo stopped' TERM; echo $$ > pid; echo partial; sleep 60 & wait"

      assert {:error, text} = Helyx.Tool.Bash.run_command(command, dir, @load_start_ms)
      assert text == "partial\nstopped\n\n" <> @timed_out
      refute os_alive?(wait_for_pid(Path.join(dir, "pid")))
    end

    @tag :slow
    test "at the limit a command that ignores TERM is killed after the grace", %{tmp_dir: dir} do
      command = "trap '' TERM; echo $$ > pid; echo partial; sleep 60"

      assert {:error, text} = Helyx.Tool.Bash.run_command(command, dir, @load_start_ms)
      assert text == "partial\n\n" <> @timed_out
      refute os_alive?(wait_for_pid(Path.join(dir, "pid")))
    end

    # The caller is suspended past the limit while the output and the exit
    # status queue up: a queued message must not win over the deadline. The
    # command writes its output at the file `go`, after the deadline.
    @tag :slow
    test "the limit wins over output queued after it", %{tmp_dir: dir} do
      test = self()
      command = "echo $$ > pid; until [ -e go ]; do sleep 0.01; done; echo done"

      caller =
        spawn(fn ->
          Helyx.Test.Hands.fake()
          send(test, Helyx.Tool.Bash.run_command(command, dir, @load_start_ms))
        end)

      pid = wait_for_pid(Path.join(dir, "pid"))
      true = :erlang.suspend_process(caller)
      # The deadline came before the pid file, so it is past after the limit.
      Process.sleep(@load_start_ms + 1)
      File.write!(Path.join(dir, "go"), "")
      assert gone_within?(pid)
      true = :erlang.resume_process(caller)

      assert_receive {:error, "done\n\n" <> @timed_out}
    end

    # A release that stalls (here suspended, as a kill(1) run that never
    # returns) must not hold the call past the one deadline after the
    # limit: the port closes, and the watchdog ends the group on its own.
    @tag :slow
    test "a stalled release does not hold the call past the deadline", %{tmp_dir: dir} do
      test = self()
      command = "trap '' TERM; echo $$ > pid; echo partial; sleep 60"

      caller =
        spawn(fn ->
          Helyx.Test.Hands.fake()
          send(test, Helyx.Tool.Bash.run_command(command, dir, @load_start_ms))
        end)

      pid = wait_for_pid(Path.join(dir, "pid"))

      true = :erlang.suspend_process(release_task(caller))

      assert_receive {:error, "partial\n\n" <> @timed_out}

      assert gone_within?(pid)
    end

    @tag :slow
    test "the timeout argument stops the command through the hands", %{run: run} do
      result = run.(%{"command" => "echo partial; sleep 60", "timeout" => 1})
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "partial\n\nTimed out after 1 s: the command group was released."
    end
  end

  describe "workdir (#576)" do
    test "a relative workdir runs in that folder of the session folder", %{tmp_dir: dir, run: run} do
      File.mkdir_p!(Path.join(dir, "sub"))
      result = run.(%{"command" => "pwd", "workdir" => "sub"})
      refute result.is_error
      assert Helyx.Message.text(result) == Path.join(dir, "sub") <> "\n"
    end

    test "a workdir is expanded as the file tools expand a path", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "a"))
      File.mkdir_p!(Path.join(dir, "b"))

      for {workdir, folder} <- [
            {"a/../b", Path.join(dir, "b")},
            {"a/..", dir},
            {Path.join(dir, "a/../b"), Path.join(dir, "b")},
            {"~", Path.expand("~")},
            {"", dir}
          ] do
        assert {:ok, out} = Helyx.Tool.Bash.run(%{"command" => "pwd", "workdir" => workdir}, dir)
        assert out == folder <> "\n", workdir
      end
    end

    test "an absolute workdir names that folder", %{tmp_dir: dir} do
      other = Path.join(dir, "other")
      File.mkdir_p!(other)

      assert {:ok, out} =
               Helyx.Tool.Bash.run(%{"command" => "pwd", "workdir" => other}, "/")

      assert out == other <> "\n"
    end

    test "a null workdir is the session folder", %{tmp_dir: dir} do
      assert {:ok, out} = Helyx.Tool.Bash.run(%{"command" => "pwd", "workdir" => nil}, dir)
      assert out == dir <> "\n"
    end

    test "a workdir that is not an existing directory fails the start; nothing runs",
         %{tmp_dir: dir} do
      ran = Path.join(dir, "ran")
      File.write!(Path.join(dir, "file"), "")

      for workdir <- ["missing", "file", Path.join(dir, "missing")] do
        assert {:error, text} =
                 Helyx.Tool.Bash.run(%{"command" => "touch #{ran}", "workdir" => workdir}, dir)

        assert "the command did not start: " <> reason = text
        assert reason =~ Path.expand(workdir, dir)
      end

      refute File.exists?(ran)
    end

    test "a workdir of another type or with a NUL is an error result; nothing runs",
         %{tmp_dir: dir} do
      ran = Path.join(dir, "ran")

      for workdir <- [1, true, ["sub"], %{}, "sub" <> <<0>>] do
        assert {:error, text} =
                 Helyx.Tool.Bash.run(%{"command" => "touch #{ran}", "workdir" => workdir}, dir)

        assert text == "workdir must be a string with no NUL byte", inspect(workdir)
      end

      refute File.exists?(ran)
    end

    test "the spec has workdir as an optional string" do
      params = Helyx.Tool.Bash.parameters()
      assert %{"type" => "string"} = params["properties"]["workdir"]
      assert params["required"] == ["command"]
    end
  end

  describe "background (#577)" do
    alias Helyx.Tool.Bash
    alias Helyx.Tool.Bash.Out

    # A session whose first turn starts `args` in the background. Returns
    # the start answer, its process group, and its output path.
    defp background(core, dir, args) do
      call = %ToolCall{id: "c", name: "bash", arguments: Map.put(args, "background", true)}
      model = "bg_#{System.unique_integer([:positive])}"
      :ok = Fake.script(core, model, [[call], ["Started."], ["Ended."]])
      {:ok, session} = Helyx.Session.start(core, model: "fake/#{model}", cwd: dir)
      {:ok, _, _} = Helyx.Session.subscribe(session)
      :ok = Helyx.Session.prompt(session, "go")

      assert_receive {:helyx_event,
                      %Helyx.Event{type: :tool_execution_end, data: %{message: answer}}},
                     Helyx.Test.Events.wait_ms()

      refute answer.is_error
      text = Helyx.Message.text(answer)

      [_all, group, path] =
        Regex.run(~r/status="started">\nProcess group: (\d+)\nOutput file: (\S+)\n/, text)

      %{text: text, group: group, path: path, session: session}
    end

    # The text of the next background end, a user message.
    defp end_message do
      receive do
        {:helyx_event,
         %Helyx.Event{type: :message_end, data: %{message: %{role: :user} = message}}} ->
          case Helyx.Message.text(message) do
            "<background" <> _rest = text -> text
            _other -> end_message()
          end
      after
        Helyx.Test.Events.wait_ms() -> flunk("no background end")
      end
    end

    test "a background argument other than true, false, or null is an error result; nothing runs",
         %{tmp_dir: dir} do
      ran = Path.join(dir, "ran")

      for value <- ["true", 1, %{}] do
        assert {:error, "background must be true or false"} =
                 Bash.run(%{"command" => "touch '#{ran}'", "background" => value}, dir)
      end

      assert {:ok, "(no output)"} =
               Bash.run(%{"command" => "touch '#{ran}'", "background" => false}, dir)

      assert File.exists?(ran)
    end

    # Outside the hands `Helyx.Tool.background/0` exits, so a timeout that
    # passes its bound exits, and one over it gets the error of the bound.
    test "a background timeout is from 1 to 86400; outside the hands nothing runs",
         %{tmp_dir: dir} do
      Process.delete(:helyx_hands)
      ran = Path.join(dir, "ran")
      args = %{"command" => "touch '#{ran}'", "background" => true}

      for timeout <- [0, 86_401, 5.0, "5"] do
        assert {:error, "a background timeout must be an integer from 1 to 86400 (seconds)"} =
                 Bash.run(Map.put(args, "timeout", timeout), dir)
      end

      for timeout <- [1, 600, 601, 86_399, 86_400, nil] do
        assert {:noproc, _} = catch_exit(Bash.run(Map.put(args, "timeout", timeout), dir))
      end

      refute File.exists?(ran)
    end

    test "the file gets at most 64 MiB; the end counts every byte and says so", %{tmp_dir: dir} do
      max = 64 * 1_048_576
      path = Path.join(dir, "out")
      {:ok, file} = File.open(path, [:write, :raw, :binary])

      out = Bash.add(%Out{file: file, written: max - 3}, "ab")
      assert out.written == max - 1
      out = Bash.add(out, "cd")
      assert out.written == max + 1
      out = Bash.add(out, "ef")
      assert out.written == max + 3
      :ok = File.close(file)

      assert File.read!(path) == "abc"
      assert out.tail == "abcdef"

      assert Bash.render(out) =~
               "[the command wrote #{max + 3} bytes; the output file holds the first #{max}]\n"

      refute Bash.render(%{out | written: max}) =~ "the output file holds"
    end

    test "a write error ends the writes and the end says so", %{tmp_dir: dir} do
      path = Path.join(dir, "out")
      File.write!(path, "")
      {:ok, file} = File.open(path, [:read, :raw, :binary])
      out = Bash.add(%Out{file: file}, "ab")
      assert out.file == nil
      assert out.tail == "ab"
      assert Bash.render(out) =~ "[the output file could not be written: "
      :ok = File.close(file)
    end

    test "a run answers at once, writes the file, and ends with the command, the exit code, and the tail",
         %{core: core, tmp_dir: dir} do
      command = "echo out; echo err >&2; exit 3\necho never"
      %{text: text, group: group, path: path} = background(core, dir, %{"command" => command})
      assert text =~ "Stop it with `kill -TERM -- -#{group}`."
      assert Path.dirname(path) =~ "helyx-"

      [_all, id] = Regex.run(~r/\A<background id="(\S+)"/, text)

      assert end_message() ==
               ~s(<background id="#{id}" status="done">\nCommand: echo out; echo err >&2; exit 3\n) <>
                 "out\nerr\n\nExit code: 3\n</background>"

      assert File.read!(path) == "out\nerr\n"
    end

    test "kill on its group ends a run, and its end arrives", %{core: core, tmp_dir: dir} do
      %{group: group} = background(core, dir, %{"command" => "sleep 60"})
      {_, 0} = System.cmd("kill", ["-TERM", "--", "-" <> group])
      assert end_message() =~ "status=\"done\">\nCommand: sleep 60\n(no output)\nExit code: 143\n"
    end

    @tag :slow
    test "at its timeout a run is released and its end is an error", %{core: core, tmp_dir: dir} do
      %{} = background(core, dir, %{"command" => "sleep 60", "timeout" => 1})

      assert end_message() =~
               "status=\"error\">\nCommand: sleep 60\n(no output)\n" <>
                 "Timed out after 1 s: the command group was released.\n</background>"
    end

    test "the first line of the command in the end is cut to 200 bytes", %{
      core: core,
      tmp_dir: dir
    } do
      # One under, at, and one over the bound; a 2-byte character that the
      # bound splits is dropped.
      for {command, kept} <- [
            {"true " <> String.duplicate("x", 194), 199},
            {"true " <> String.duplicate("x", 195), 200},
            {"true " <> String.duplicate("x", 196), 200},
            {"true " <> String.duplicate("x", 194) <> "é", 199}
          ] do
        %{} = background(core, dir, %{"command" => command <> "\necho second"})
        [_all, line] = Regex.run(~r/\nCommand: (.*)\n/, end_message())
        assert byte_size(line) == kept
        assert String.starts_with?(command, line)
      end
    end

    test "the stop of the session ends a live run", %{core: core, tmp_dir: dir} do
      %{session: session} = background(core, dir, %{"command" => "echo $$ > pid; sleep 300"})
      pid = wait_for_pid(Path.join(dir, "pid"))

      :ok = GenServer.stop(Helyx.Session.pid(session))
      assert gone_within?(pid)
    end
  end

  test "check reports a system without perl" do
    assert :ok = Helyx.Tool.Bash.check()
    assert {:error, message} = Helyx.Tool.Bash.check(fn _ -> nil end)
    assert message =~ "perl"
  end
end
