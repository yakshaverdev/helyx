defmodule Mix.Tasks.HelyxTest do
  # Not async: the sessions directory is application env, and the task
  # starts a server in this VM, under its default name.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "a resume error is one line: a sentence for a wire code, a term for any other" do
    @describetag :tmp_dir

    # The task has no terminal here. Every case fails before the TUI starts.
    setup %{tmp_dir: dir} do
      Application.put_env(:coding_agent, :sessions_dir, dir)
      on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)

      on_exit(fn ->
        if server = Process.whereis(CodingAgent.Serve),
          do: Task.Supervisor.terminate_child(CodingAgent.Servers, server)
      end)

      # A session with no message is not resumed, so the file has a prompt.
      {:ok, file} = Helyx.Session.File.create(dir, Helyx.Session.Id.new(), dir, "fake/echo")
      file = Helyx.Test.SessionFile.append_message(file, Helyx.Message.user("hi"))
      %{path: file.path, leaf: file.leaf}
    end

    # The task stops Mix with status 1 after one line on stderr. An open that
    # takes over 500 ms writes the line of the wait first
    # (docs/features/tui-attach.md, decision 17).
    defp message(args) do
      stderr =
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Helyx.run(args)) == {:shutdown, 1}
        end)

      lines = String.split(stderr, "\n", trim: true)
      start = "helyx: could not start the agent: "

      assert ["helyx: could not start the agent: " <> rest] =
               Enum.filter(lines, &String.starts_with?(&1, start))

      rest
    end

    defp resume_message(dir), do: message([dir, "--resume"])

    # The TUI asks the server, whose `start_failed` holds the term of an
    # error that the wire has no code for (docs/features/tui-attach.md,
    # Accepted holes): still one line on stderr.
    defp term(args) do
      rest = message(args)
      assert "{" <> _ = rest
      refute rest =~ "\n"
      rest
    end

    test "an atom: no saved session", %{tmp_dir: dir, path: path} do
      File.rm!(path)

      assert resume_message(dir) ==
               "no saved session for this directory; start one without --resume"
    end

    test "a tagged text: the too_large sentence is printed as it is", %{tmp_dir: dir, path: path} do
      # A sparse last line one byte over the limit of one line.
      at = File.stat!(path).size + 67_108_864
      File.open!(path, [:read, :write], &:file.pwrite(&1, at, "x"))

      assert term([dir, "--resume"]) =~ "{:too_large, "
    end

    # The entries below hang from the prompt, so they are on the branch that
    # the resume reads.
    test "a tagged text: a damaged file", %{tmp_dir: dir, path: path, leaf: leaf} do
      File.write!(path, ~s({"type":"bogus","id":"x","parent_id":"#{leaf}"}\n), [:append])

      assert term([dir, "--resume"]) =~ "{:invalid_file, "
    end

    test "a tagged text: an exception message of many lines",
         %{tmp_dir: dir, path: path, leaf: leaf} do
      line =
        ~s({"type":"message","id":"message00001","parent_id":"#{leaf}","role":"user","origin":{"kind":"user","id":null}}\n)

      File.write!(path, line, [:append])

      assert term([dir, "--resume"]) =~ "{:invalid_file, "
    end

    test "a saved model ref that is not valid", %{tmp_dir: dir, path: path, leaf: leaf} do
      line = ~s({"type":"model_change","id":"m1","parent_id":"#{leaf}","model":"nope"}\n)
      File.write!(path, line, [:append])
      assert resume_message(dir) == "the model ref is not valid; use provider/model"
    end

    # --resume skips such a file; --session names it.
    test "a tagged term: an unknown version", %{path: path} do
      File.write!(path, String.replace(File.read!(path), ~s("version":1), ~s("version":99)))
      id = Path.basename(path, ".jsonl")
      assert term(["--session", id]) =~ "{:unknown_version, 99}"
    end

    test "a tagged posix code: the repair fails", %{tmp_dir: dir, path: path} do
      File.write!(path, "torn", [:append])
      File.chmod!(path, 0o400)

      assert term([dir, "--resume"]) =~ "{:repair_failed, :eacces}"
    end
  end
end
