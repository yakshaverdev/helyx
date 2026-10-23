defmodule Mix.Tasks.Helyx.InstallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Helyx.Test.Events, only: [wait_until: 1]

  alias Mix.Tasks.Helyx.Install

  @moduletag :tmp_dir

  # The second SIGTERM of the launcher comes after one second; the rest is
  # the margin for load.
  @load_ms 10_000
  # The supervisor of the launcher wakes each 0.25 s; a SIGTERM for an
  # ignored SIGHUP would come within this margin for load.
  @load_ignored_ms 1_000

  # A quote and a space in the prefix check the quoting of the launcher.
  setup %{tmp_dir: dir} do
    prefix = Path.join(dir, "it's home")
    File.mkdir_p!(Path.join(prefix, "releases"))
    %{prefix: prefix, bin_dir: Path.join(dir, "bin")}
  end

  # A fake build: the version file of a release, and a `bin/helyx` that
  # prints its folder, the launcher that it names, and its arguments, one
  # per line.
  defp build(prefix, version) do
    build = Path.join(prefix, "releases/.build-test")
    File.mkdir_p!(Path.join(build, "bin"))
    File.mkdir_p!(Path.join(build, "releases"))
    File.write!(Path.join(build, "releases/start_erl.data"), "16.4 #{version}\n")

    File.write!(
      Path.join(build, "bin/helyx"),
      ~s(#!/bin/sh\nprintf '%s\\n' "$PWD" "$HELYX_LAUNCHER" "$@"\n)
    )

    File.chmod!(Path.join(build, "bin/helyx"), 0o755)
    build
  end

  defp install(%{prefix: prefix, bin_dir: bin_dir}, version) do
    capture_io(fn -> Install.install(build(prefix, version), prefix, bin_dir) end)
  end

  # The launcher with `args`; the release script reads the folder `dir` in
  # `OUT`. Returns its port and OS pid. `executable` is the launcher, or a
  # program that execs it.
  defp launch(executable, dir, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :exit_status,
        args: args,
        env: [{~c"OUT", String.to_charlist(dir)}]
      ])

    {:os_pid, launcher} = Port.info(port, :os_pid)
    {port, launcher}
  end

  defp builds(prefix), do: prefix |> Path.join("releases") |> File.ls!() |> Enum.sort()
  defp current(prefix), do: File.read_link!(Path.join(prefix, "current"))

  test "installs the build under its commit and the launcher passes arguments and folder",
       %{prefix: prefix, bin_dir: bin_dir, tmp_dir: dir} = context do
    assert install(context, "0.1.0+abc1234") =~ "installed 0.1.0+abc1234"
    assert builds(prefix) == ["abc1234"]
    assert current(prefix) == "releases/abc1234"

    work = Path.join(dir, "work dir")
    File.mkdir_p!(work)
    args = ["a b", "--resume", "$HOME", "it's"]
    {out, 0} = System.cmd(Path.join(bin_dir, "helyx"), args, cd: work)

    # The launcher names itself, for the start of a server
    # (docs/features/tui-attach.md, decision 10).
    assert String.split(out, "\n", trim: true) ==
             [Path.expand(work), Path.join(bin_dir, "helyx")] ++
               ["eval", "System.halt(CodingAgent.CLI.main(System.argv()))"] ++ args
  end

  # USR1 stands for the signals that the launcher traps beyond INT, TERM,
  # and HUP.
  for signal <- ["INT", "TERM", "HUP", "USR1"] do
    test "the launcher runs serve in a process group of its own and sends SIGTERM for SIG#{signal}",
         %{prefix: prefix, bin_dir: bin_dir, tmp_dir: dir} = context do
      install(context, "0.1.0+abc1234")

      # A release script that writes its arguments, whether its stdin is at
      # its end, its pid, and its process group, then waits, and exits 7 at
      # SIGTERM.
      File.write!(Path.join(prefix, "current/bin/helyx"), ~S"""
      #!/bin/sh
      trap 'echo term >"$OUT/signal"; exit 7' TERM
      printf '%s\n' "$@" >"$OUT/args"
      if read -r line; then echo data; else echo end; fi >"$OUT/stdin"
      echo "$$ $(ps -o pgid= -p $$ | tr -d ' ')" >"$OUT/group.tmp" && mv "$OUT/group.tmp" "$OUT/group"
      while :; do sleep 0.1; done
      """)

      {port, launcher} = launch(Path.join(bin_dir, "helyx"), dir, ["serve", "--port", "1"])
      wait_until(fn -> File.exists?(Path.join(dir, "group")) end)

      # The release script leads a process group of its own.
      [pid, group] = String.split(File.read!(Path.join(dir, "group")))
      assert pid == group
      refute group == Integer.to_string(launcher)
      {_, 0} = System.cmd("kill", ["-#{unquote(signal)}", Integer.to_string(launcher)])

      assert_receive {^port, {:exit_status, 7}}
      assert File.read!(Path.join(dir, "signal")) == "term\n"

      assert File.read!(Path.join(dir, "args")) ==
               "eval\nSystem.halt(CodingAgent.CLI.main(System.argv()))\nserve\n--port\n1\n"

      # The VM reads `/dev/null`, not the stdin of the launcher.
      assert File.read!(Path.join(dir, "stdin")) == "end\n"
    end
  end

  # Under `nohup` SIGHUP is ignored at the start of the launcher: it stays
  # ignored, and another signal still stops the release script.
  test "the launcher keeps a signal that was ignored at its start",
       %{prefix: prefix, bin_dir: bin_dir, tmp_dir: dir} = context do
    install(context, "0.1.0+abc1234")

    File.write!(Path.join(prefix, "current/bin/helyx"), ~S"""
    #!/bin/sh
    trap 'echo term >>"$OUT/signal"; exit 7' TERM
    touch "$OUT/started"
    while :; do sleep 0.1; done
    """)

    {port, launcher} =
      launch(System.find_executable("sh"), dir, [
        "-c",
        ~S|trap "" HUP; exec "$0" serve|,
        Path.join(bin_dir, "helyx")
      ])

    wait_until(fn -> File.exists?(Path.join(dir, "started")) end)
    {_, 0} = System.cmd("kill", ["-HUP", Integer.to_string(launcher)])
    refute_receive {^port, {:exit_status, _}}, @load_ignored_ms
    refute File.exists?(Path.join(dir, "signal"))

    {_, 0} = System.cmd("kill", ["-INT", Integer.to_string(launcher)])
    assert_receive {^port, {:exit_status, 7}}
    assert File.read!(Path.join(dir, "signal")) == "term\n"
  end

  # The VM drops a SIGTERM that comes before its handler: the launcher sends
  # one each second until the VM ends.
  @tag :slow
  test "the launcher sends SIGTERM again until the release script ends",
       %{prefix: prefix, bin_dir: bin_dir, tmp_dir: dir} = context do
    install(context, "0.1.0+abc1234")

    # A release script that drops its first SIGTERM and exits 7 at the
    # second.
    File.write!(Path.join(prefix, "current/bin/helyx"), ~S"""
    #!/bin/sh
    n=0
    trap 'n=$((n + 1)); echo "$n" >>"$OUT/terms"; [ "$n" -lt 2 ] || exit 7' TERM
    touch "$OUT/started"
    while :; do sleep 0.1; done
    """)

    {port, launcher} = launch(Path.join(bin_dir, "helyx"), dir, ["serve"])
    wait_until(fn -> File.exists?(Path.join(dir, "started")) end)
    {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(launcher)])

    assert_receive {^port, {:exit_status, 7}}, @load_ms
    assert File.read!(Path.join(dir, "terms")) == "1\n2\n"
  end

  test "a second install of one commit gets a new folder; the third deletes the oldest",
       %{prefix: prefix} = context do
    install(context, "0.1.0+abc1234")
    marker = Path.join(prefix, "releases/abc1234/bin/helyx")
    before = File.read!(marker)

    install(context, "0.1.0+abc1234")
    assert builds(prefix) == ["abc1234", "abc1234-2"]
    assert current(prefix) == "releases/abc1234-2"
    assert File.read!(marker) == before

    install(context, "0.1.0+def5678-dirty")
    assert builds(prefix) == ["abc1234-2", "def5678-dirty"]
    assert current(prefix) == "releases/def5678-dirty"

    # The free name skips the kept build; the stale entries go.
    File.mkdir_p!(Path.join(prefix, "releases/.build-123"))
    File.ln_s!("releases/x", Path.join(prefix, "releases/.current-123"))
    install(context, "0.1.0+abc1234")
    assert builds(prefix) == ["abc1234", "def5678-dirty"]
  end

  test "a launcher that cannot be written leaves current and the kept builds",
       %{prefix: prefix, bin_dir: bin_dir} = context do
    install(context, "0.1.0+abc1234")
    install(context, "0.1.0+bcd2345")
    File.rm!(Path.join(bin_dir, "helyx"))
    File.mkdir_p!(Path.join(bin_dir, "helyx/x"))

    assert_raise File.RenameError, fn -> install(context, "0.1.0+cde3456") end
    assert current(prefix) == "releases/bcd2345"
    assert builds(prefix) == ["abc1234", "bcd2345", "cde3456"]

    File.rm_rf!(Path.join(bin_dir, "helyx"))
    install(context, "0.1.0+def4567")
    assert builds(prefix) == ["bcd2345", "def4567"]
    assert File.ls!(bin_dir) == ["helyx"]
  end

  test "a deletion that fails after the swap warns, and the install succeeds",
       %{prefix: prefix} = context do
    install(context, "0.1.0+abc1234")
    install(context, "0.1.0+bcd2345")
    # A folder that cannot change keeps its `bin` folder from deletion.
    locked = Path.join(prefix, "releases/abc1234")
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o755) end)

    stderr =
      capture_io(:stderr, fn -> assert install(context, "0.1.0+cde3456") =~ "installed" end)

    assert stderr =~ "could not delete"
    assert current(prefix) == "releases/cde3456"
    assert "bcd2345" in builds(prefix)

    # The next install deletes what this one could not.
    File.chmod!(locked, 0o755)
    install(context, "0.1.0+def4567")
    assert builds(prefix) == ["cde3456", "def4567"]
  end

  # The safe folders come first, so a parse that let an argument list through
  # would install into the test folder, not the home folder.
  test "bad arguments print the usage", %{tmp_dir: dir} do
    safe = ["--prefix", dir, "--bin-dir", dir]

    for argv <- [["--bogus"], ["extra"], ["-="], ["--prefix"], ["-\xFF"]] do
      assert_raise Mix.Error, ~r/^usage: mix helyx.install/, fn -> Install.run(safe ++ argv) end
    end
  end

  test "a current that is not a symlink stops the install before any change",
       %{prefix: prefix} = context do
    File.mkdir_p!(Path.join(prefix, "current"))

    assert_raise CaseClauseError, ~r/:einval/, fn -> install(context, "0.1.0+abc1234") end

    assert builds(prefix) == [".build-test"]
  end
end
