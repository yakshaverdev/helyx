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

  test "the switches of the list and of the resume by id that do not combine" do
    assert error_line(["--session", "x", "--model", "fake/echo"]) =~
             "--model does not combine with --session; a resumed session keeps its saved model"

    assert error_line(["--session", "x", "/tmp"]) =~
             "a directory argument does not combine with --session"

    assert error_line(["--session", "x", "--resume"]) =~
             "--resume does not combine with --session"

    assert error_line(["--list", "--session", "x"]) =~ "--list does not combine with --session"

    assert error_line(["--list", "--model", "fake/echo"]) =~
             "--list does not combine with --model"

    assert error_line(["--list", "--resume"]) =~ "--list does not combine with --resume"

    assert error_line(["--list", "--all", "/tmp"]) =~
             "a directory argument does not combine with --all"

    assert error_line(["--all"]) =~ "--all needs --list"
    assert error_line(["--session"]) =~ ~s("--session"; the options)
    assert Process.whereis(Helyx.Core) == nil

    # --version skips these checks.
    assert capture_io(fn -> assert CLI.main(["--version", "--list", "--session", "x"]) == 0 end) =~
             "helyx "
  end

  describe "--list and --session on a sessions directory" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      sessions = Path.join(dir, "sessions")
      Application.put_env(:coding_agent, :sessions_dir, sessions)
      on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)
      %{sessions: sessions}
    end

    # A session of `cwd` with the prompt `prompt` (nil for none), touched to `mtime`.
    defp session(sessions, cwd, mtime, prompt, model \\ "fake/echo") do
      id = Helyx.Session.Id.new()
      {:ok, file} = Helyx.Session.File.create(sessions, id, cwd, model)
      if prompt, do: Helyx.Session.File.append_message(file, Helyx.Message.user(prompt))
      File.touch!(file.path, mtime)
      {id, file.path}
    end

    defp list(argv) do
      out = capture_io(fn -> send(self(), {:status, CLI.main(["--list" | argv])}) end)
      assert_received {:status, 0}
      String.split(out, "\n", trim: true)
    end

    @time ~S(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)

    test "--list prints the sessions of the folder, newest first", %{tmp_dir: dir, sessions: s} do
      {old, _} = session(s, dir, 1_000, "fix the\ntests\e[2J")
      {new, _} = session(s, dir, 3_000, "second")
      session(s, dir, 4_000, nil)
      session(s, "/elsewhere", 5_000, "other")

      # The older format: no session header.
      {_, path} = session(s, dir, 6_000, "old format")
      File.write!(path, ~s({"type":"message","role":"user","content":[]}\n))

      assert [first, second] = list([dir])
      assert first =~ ~r/^#{new}  #{@time}  fake\/echo  second$/
      assert second =~ ~r/^#{old}  #{@time}  fake\/echo  fix the tests\?\[2J$/

      File.cd!(dir, fn -> assert length(list([])) == 2 end)
      assert list([s]) == []
      assert Process.whereis(Helyx.Core) == nil
    end

    test "--list --all puts the folder on each line, and the file text has a width",
         %{tmp_dir: dir, sessions: s} do
      folder = "/" <> String.duplicate("é", 79) <> "x"
      model = String.duplicate("m", 40) <> "!"
      session(s, dir, 1_000, String.duplicate("é", 60) <> "!", model)

      # A model at the width stays whole. A width counts code points, so a
      # run of combining marks is cut too.
      marks = "e" <> String.duplicate("\u0301", 1_000)
      session(s, folder, 2_000, marks, String.duplicate("é", 40))

      # An empty session and the older format are left out.
      session(s, dir, 3_000, nil)
      {_, path} = session(s, dir, 4_000, "old format")
      File.write!(path, ~s({"type":"message","role":"user","content":[]}\n))

      assert [first, second] = list(["--all"])

      assert first =~
               ~r/  #{String.duplicate("é", 79)}x  #{String.duplicate("é", 40)}  e#{String.duplicate("\u0301", 59)}$/

      assert second =~
               ~r/  #{Regex.escape(String.slice(dir, -80, 80))}  #{String.duplicate("m", 40)}  #{String.duplicate("é", 60)}$/
    end

    test "--session checks the id and the folder of its header", %{tmp_dir: dir, sessions: s} do
      {id, _} = session(s, Path.join(dir, "gone"), 1_000, "p")
      gone = String.slice(dir <> "/gone", -80, 80)
      assert error_line(["--session", id]) == ~s(not a directory: "#{gone}")

      # About one id in 64 starts with "-". The folder must be absolute, and
      # it is cleaned before it is shown.
      dash = "-" <> String.slice(Helyx.Session.Id.new(), 1, 11)
      {:ok, _} = Helyx.Session.File.create(s, dash, ".", "fake/echo")
      assert error_line(["--session", dash]) == ~s(not a directory: ".")
      control = Helyx.Session.Id.new()
      {:ok, _} = Helyx.Session.File.create(s, control, "/x\0\e[2J", "fake/echo")
      assert error_line(["--session", control]) == ~s(not a directory: "/x??[2J")

      # After "--" the words are arguments, and two files with one id fail
      # the start.
      assert error_line(["--", "--session", dash]) =~ "at most one directory"
      copy = Path.join([s, "other", control <> ".jsonl"])
      File.mkdir_p!(Path.dirname(copy))

      File.cp!(
        Path.join(Helyx.Session.File.Scan.project_dir(s, "/x\0\e[2J"), control <> ".jsonl"),
        copy
      )

      assert error_line(["--session", control]) =~ "more than one session file has this id"

      # A path in the id never reaches the filesystem.
      {_, path} = session(s, dir, 1_000, "p")
      File.cp!(path, Path.join(s, "escaped01.jsonl"))
      assert error_line(["--session", "../escaped01"]) == ~s(not a session id: "../escaped01")

      missing = Helyx.Session.Id.new()
      assert error_line(["--session", missing]) == ~s(no session "#{missing}")
      assert Process.whereis(Helyx.Core) == nil
    end
  end
end
