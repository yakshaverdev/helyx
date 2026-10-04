defmodule Mix.Tasks.Helyx.InstallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Helyx.Install

  @moduletag :tmp_dir

  # A quote and a space in the prefix check the quoting of the launcher.
  setup %{tmp_dir: dir} do
    prefix = Path.join(dir, "it's home")
    File.mkdir_p!(Path.join(prefix, "releases"))
    %{prefix: prefix, bin_dir: Path.join(dir, "bin")}
  end

  # A fake build: the version file of a release, and a `bin/helyx` that
  # prints its folder and its arguments, one per line.
  defp build(prefix, version) do
    build = Path.join(prefix, "releases/.build-test")
    File.mkdir_p!(Path.join(build, "bin"))
    File.mkdir_p!(Path.join(build, "releases"))
    File.write!(Path.join(build, "releases/start_erl.data"), "16.4 #{version}\n")
    File.write!(Path.join(build, "bin/helyx"), ~s(#!/bin/sh\nprintf '%s\\n' "$PWD" "$@"\n))
    File.chmod!(Path.join(build, "bin/helyx"), 0o755)
    build
  end

  defp install(%{prefix: prefix, bin_dir: bin_dir}, version) do
    capture_io(fn -> Install.install(build(prefix, version), prefix, bin_dir) end)
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

    assert String.split(out, "\n", trim: true) ==
             [Path.expand(work), "eval", "System.halt(CodingAgent.CLI.main(System.argv()))"] ++
               args
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

    assert_raise Mix.Error, ~r/cannot read the link .*current: invalid argument/, fn ->
      install(context, "0.1.0+abc1234")
    end

    assert builds(prefix) == [".build-test"]
  end
end
