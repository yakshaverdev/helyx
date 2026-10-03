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
  end

  test "the group marker is found after perl's own warnings", %{tmp_dir: dir} do
    assert {:ok, text} = Helyx.Tool.Bash.run(%{"command" => "echo $$; ps -o pgid= -p $$"}, dir)
    # The marker line is gone from the output: what is left of the numbers
    # is the command's own pid and its group, which are equal.
    assert [pid, pgid] = Regex.scan(~r/^\s*(\d+)\s*$/m, text, capture: :all_but_first)
    assert pid == pgid
  end
end
