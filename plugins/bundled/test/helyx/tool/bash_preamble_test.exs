defmodule Helyx.Tool.Bash.PreambleTest do
  # With a locale the system does not have, perl writes a startup warning to
  # stderr before the watchdog's marker line. Not async: the locale is in the
  # OS environment of the whole VM.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  @moduletag :tmp_dir

  setup do
    put_env("LC_ALL", "xx_NOPE.UTF-8")
  end

  defp put_env(name, value) do
    old = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if old, do: System.put_env(name, old), else: System.delete_env(name)
    end)
  end

  # Stands in for the hands: it sends the held handles to `test`.
  defp holds_to(test), do: spawn_link(fn -> forward_holds(test) end)

  defp forward_holds(test) do
    receive do
      {:"$gen_call", from, {:hold, {kind, group}}} ->
        send(test, {:held, group, kind})
        GenServer.reply(from, :ok)
        forward_holds(test)
    end
  end

  test "the not-started marker is found after perl's own warnings (issue #52)", %{tmp_dir: dir} do
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, Path.join(dir, "gone"))
    assert text =~ "did not start"
  end

  test "warnings over the preamble limit: the command does not run", %{tmp_dir: dir} do
    # perl prints the value of every locale variable in its warning.
    put_env("LC_MESSAGES", String.duplicate("x", 5000))
    ran = Path.join(dir, "ran")

    for cwd <- [dir, Path.join(dir, "gone")] do
      assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "touch #{ran}"}, cwd)
      assert text =~ "did not start"
    end

    refute File.exists?(ran)
  end

  test "warnings over the tool result limits: the error still names the perl watchdog",
       %{tmp_dir: dir} do
    for value <- [String.duplicate("\n", 5000), String.duplicate("x", 60_000)] do
      put_env("LC_MESSAGES", value)
      # perl's warning holds environment values: the assertion message
      # shows none of them.
      {:error, text} = Helyx.Tool.Bash.run(%{"command" => "true"}, dir)
      named? = String.starts_with?(text, "the command did not start: the perl watchdog")
      assert named?, "the error does not start with the perl watchdog"
    end
  end

  test "the close with no marker leaves no process", %{tmp_dir: dir} do
    put_env("LC_MESSAGES", String.duplicate("x", 5000))
    test = self()

    Process.put(:helyx_hands, holds_to(test))
    assert {:error, _} = Helyx.Tool.Bash.run(%{"command" => "sleep 30"}, dir)
    assert_received {:held, watchdog, :watchdog}
    # The watchdog reaps the child it holds before it exits.
    assert gone_within?("-#{watchdog}")
  end

  test "a line from the environment cannot pass for a marker", %{tmp_dir: dir} do
    put_env("LC_ALL", "xx\n4242\n0\nyy")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, Path.join(dir, "gone"))
    assert text =~ "cannot enter"
    assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
    assert text =~ "ran\n"
  end

  test "a perl that stops before the watchdog runs is an error, not its exit code",
       %{tmp_dir: dir} do
    put_first_in_path(dir, "perl", "#!/bin/sh\necho NopeNope\nexit 3\n")
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, dir)
    assert text =~ "did not start"
    assert text =~ "NopeNope"
  end

  defp put_first_in_path(dir, name, content) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, name), content)
    File.chmod!(Path.join(bin, name), 0o755)
    put_env("PATH", bin <> ":" <> System.get_env("PATH"))
    Path.join(bin, name)
  end

  # An executable file whose interpreter does not exist: it is found, and
  # the exec fails.
  defp put_bad_bash(dir), do: put_first_in_path(dir, "bash", "#!/nonexistent/interpreter\n")

  test "a bash that cannot be executed is an error, not exit code 127 (issue #70)",
       %{tmp_dir: dir} do
    # The path holds characters of two and of three bytes: the reason is
    # bytes already, and it must arrive as it is.
    bash = put_bad_bash(Path.join(dir, "é☃"))
    assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
    assert text =~ "did not start"
    assert text =~ "cannot run #{bash}: No such file"
    refute text =~ " 0\n"
  end

  describe "perl variables of the environment (issue #71)" do
    # The watchdog starts without every variable whose name starts with
    # `PERL`, and gives them back to the command.

    test "PERL5OPT=-w does not reach the watchdog: no perl warning about a failed exec",
         %{tmp_dir: dir} do
      bash = put_bad_bash(dir)
      put_env("PERL5OPT", "-w")
      assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
      refute text =~ "Can't exec"
      assert text =~ "cannot run #{bash}: No such file"
    end

    test "PERL_UNICODE=A and a wide character in the bash path: the true reason",
         %{tmp_dir: dir} do
      bash = put_bad_bash(Path.join(dir, "é☃"))
      put_env("PERL_UNICODE", "A")
      assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "echo ran"}, dir)
      assert text =~ "cannot run #{bash}: No such file"
    end

    test "PERL_UNICODE of A, o, D, i, and I: a command runs, and a missing directory gives its reason",
         %{tmp_dir: dir} do
      gone = Path.join(dir, "gone é☃")

      for value <- ~w(A o D i I) do
        put_env("PERL_UNICODE", value)

        assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo v=$PERL_UNICODE."}, dir)
        assert text =~ "v=#{value}.\n"

        assert {:error, text} = Helyx.Tool.Bash.run(%{"command" => "pwd"}, gone)
        assert text =~ "cannot enter the working directory #{gone}: No such file"
      end
    end

    test "PERL_UNICODE=I and i: a closed port still kills the group", %{tmp_dir: dir} do
      for value <- ~w(I i) do
        put_env("PERL_UNICODE", value)

        {exe, options} =
          Helyx.Watchdog.launcher(["bash", "-c", "echo ready; sleep 30"], dir, "nonce", -1)

        port = Port.open({:spawn_executable, exe}, options)
        assert {group, _pre} = Helyx.Watchdog.read_marker(port, "nonce", "", "")
        assert is_integer(group)
        true = Port.command(port, "go\n")
        assert_receive {^port, {:data, "nonce 1\n" <> _}}

        Port.close(port)
        assert group_gone_within?(group)
      end
    end

    test "PERL5OPT=-d: no debugger in the watchdog, the command runs, and no process stays",
         %{tmp_dir: dir} do
      put_env("PERL5OPT", "-d")
      test = self()

      task =
        Task.async(fn ->
          Process.put(:helyx_hands, holds_to(test))
          Helyx.Tool.Bash.run(%{"command" => "echo v=$PERL5OPT."}, dir)
        end)

      assert {:ok, {:ok, text}} = Task.yield(task, Helyx.Test.Events.wait_ms())
      assert text =~ "v=-d.\n"
      assert_received {:held, watchdog, :watchdog}
      assert_received {:held, group, :command}
      assert group_gone_within?(watchdog)
      assert group_gone_within?(group)
    end

    test "PERL_BADLANG=0 still stops the locale warning of the watchdog", %{tmp_dir: dir} do
      # The locale of `setup` makes the warning.
      put_env("PERL_BADLANG", "0")
      assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo v=$PERL_BADLANG."}, dir)
      refute text =~ "perl: warning"
      assert text =~ "v=0.\n"
    end

    test "only the reserved prefix HELYX_KEEP_PERL is taken: HELYX_KEEP_HOME is not touched",
         %{tmp_dir: dir} do
      put_env("HELYX_KEEP_HOME", "/nowhere")
      put_env("HELYX_KEEP_PERL_HELYX_C", "abc")
      command = ~S(echo "[$HELYX_KEEP_HOME] [$PERL_HELYX_C]"; test "$HOME" != /nowhere)
      assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => command}, dir)
      # The documented cost of the reserved prefix: the name and the first
      # character of the value are taken off.
      assert text =~ "[/nowhere] [bc]\n"
      refute text =~ "Exit code"
    end

    test "a PERL5LIB with a broken POSIX module does not reach the watchdog", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "POSIX.pm"), "die 'broken POSIX';\n")
      put_env("PERL5LIB", dir)
      assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo v=$PERL5LIB."}, dir)
      assert text =~ "v=#{dir}.\n"
      refute text =~ "broken POSIX"
    end

    test "the command gets each value as it is: `=`, a line break, empty",
         %{tmp_dir: dir} do
      put_env("PERL_HELYX_A", "a=b\nc d")
      put_env("PERL_HELYX_B", "")
      # Never the whole environment: a failed assertion prints the text.
      command =
        ~S(echo "[$PERL_HELYX_A]"; echo "[${PERL_HELYX_B-unset}]"; env | grep -c HELYX_KEEP_)

      assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => command}, dir)
      assert text =~ "[a=b\nc d]\n[]\n0\n"
    end
  end

  test "the group marker is found after perl's own warnings", %{tmp_dir: dir} do
    assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo $$; ps -o pgid= -p $$"}, dir)
    # The marker line is gone from the output: what is left of the numbers
    # is the command's own pid and its group, which are equal.
    assert [pid, pgid] = Regex.scan(~r/^\s*(\d+)\s*$/m, text, capture: :all_but_first)
    assert pid == pgid
  end
end
