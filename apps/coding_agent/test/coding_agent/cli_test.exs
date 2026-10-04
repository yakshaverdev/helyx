defmodule CodingAgent.CLITest do
  # Not async: main/1 changes the OS environment of the VM, and an error
  # goes to the shared stderr.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CodingAgent.CLI

  # Runs main/1 and returns its status and the one line it printed on stderr.
  defp error_line(argv) do
    stderr = capture_io(:stderr, fn -> send(self(), {:status, CLI.main(argv)}) end)
    assert_received {:status, 1}
    assert [line] = String.split(stderr, "\n", trim: true)
    assert stderr == line <> "\n"
    assert "helyx: " <> text = line
    text
  end

  test "bad arguments print one line on stderr and return 1 before starting anything" do
    assert error_line(["--bogus"]) =~ "--bogus"
    assert error_line(["a", "b"]) =~ "at most one directory"
    assert error_line(["/nonexistent/helyx-test-dir"]) =~ "not a directory"

    bad = "/nonexistent/a\e[31mb\nc"

    # Each message shows the bad argument as inspect/1 prints it.
    for {argv, text, shown} <- [
          {[bad], "not a directory", inspect(bad)},
          {["/x", bad], "at most one directory", inspect(["/x", bad])},
          {["--x\e[31m\n"], "unknown option", inspect("--x\e[31m\n")},
          {["--resume=\e[31m\n"], "bad value", ~S("--resume"="\e[31m\n")},
          {["-a\xFF\e[31m\n"], "not UTF-8", ~S("-a\xFF\e[31m\n")},
          {["/x\xFF"], "not UTF-8", ~S("/x\xFF")},
          {["-="], "bad option", ~S(["-="])},
          {["-=value"], "bad option", ~S(["-=value"])},
          {["-=\e[31m\n"], "bad option", ~S(["-=\e[31m\n"])}
        ] do
      message = error_line(argv)
      assert message =~ text
      assert message =~ shown
      assert String.valid?(message)
      refute message =~ ~r/[\x00-\x1F\x7F]/
    end

    assert error_line(["--model"]) =~ ~s("--model"; the options)
    assert error_line(["--resume", "--model", "fake/echo"]) =~ "does not combine"
    assert error_line(["--version", "--bogus"]) =~ "--bogus"
    assert Process.whereis(Helyx.Core) == nil
  end

  test "--version prints the source version outside a release" do
    assert capture_io(fn -> assert CLI.main(["--version"]) == 0 end) == "helyx 0.1.0 (source)\n"
  end

  test "--version prints the release version, and the release variables do not reach children" do
    System.put_env("RELEASE_VSN", "0.1.0+abc1234")
    System.put_env("RELEASE_SYS_CONFIG", "/old/sys")
    on_exit(fn -> Enum.each(~w(RELEASE_VSN RELEASE_SYS_CONFIG), &System.delete_env/1) end)

    assert capture_io(fn -> assert CLI.main(["--version", "ignored"]) == 0 end) ==
             "helyx 0.1.0+abc1234\n"

    assert {"", 0} = System.cmd("sh", ["-c", ~S(printf %s "$RELEASE_VSN$RELEASE_SYS_CONFIG")])
  end
end
