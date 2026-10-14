defmodule Mix.Tasks.HelyxTest do
  # Not async: the sessions directory is application env, and the task
  # starts Core under its default name.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "mix helyx --resume and --session print a resume error as a sentence" do
    @describetag :tmp_dir

    # The task has no terminal here. Every case fails before the TUI starts.
    setup %{tmp_dir: dir} do
      Application.put_env(:coding_agent, :sessions_dir, dir)
      on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)
      # A session with no message is not resumed, so the file has a prompt.
      {:ok, file} = Helyx.Session.File.create(dir, Helyx.Session.Id.new(), dir, "fake/echo")
      file = Helyx.Session.File.append_message(file, Helyx.Message.user("hi"))
      %{path: file.path, leaf: file.leaf}
    end

    # The task stops Mix with status 1 after one line on stderr.
    defp resume_message(args) when is_list(args) do
      stderr =
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Helyx.run(args)) == {:shutdown, 1}
        end)

      assert "helyx: could not start the agent" <> message = stderr
      refute message =~ "{"
      assert [_line] = String.split(message, "\n", trim: true)
      message
    end

    defp resume_message(dir), do: resume_message([dir, "--resume"])

    test "an atom: no saved session", %{tmp_dir: dir, path: path} do
      File.rm!(path)
      assert resume_message(dir) =~ "no saved session for this directory"
    end

    test "a tagged text: the too_large sentence is printed as it is", %{tmp_dir: dir, path: path} do
      # A sparse file one byte over the limit.
      File.open!(path, [:read, :write], &:file.pwrite(&1, 67_108_864, "x"))

      assert resume_message(dir) =~
               ": the session file is over the 67108864-byte limit; start a new session"
    end

    # The entries below hang from the prompt, so they are on the branch that
    # the resume reads.
    test "a tagged text: a damaged file", %{tmp_dir: dir, path: path, leaf: leaf} do
      File.write!(path, ~s({"type":"bogus","id":"x","parent_id":"#{leaf}"}\n), [:append])
      assert resume_message(dir) =~ "the session file is damaged: entry the writer never"
    end

    test "a tagged text: an exception message of many lines",
         %{tmp_dir: dir, path: path, leaf: leaf} do
      line = ~s({"type":"message","id":"m1","parent_id":"#{leaf}","role":"user"}\n)
      File.write!(path, line, [:append])
      assert resume_message(dir) =~ "the session file is damaged: protocol Enumerable"
    end

    test "a saved model ref that is not valid", %{tmp_dir: dir, path: path, leaf: leaf} do
      line = ~s({"type":"model_change","id":"m1","parent_id":"#{leaf}","model":"nope"}\n)
      File.write!(path, line, [:append])
      assert resume_message(dir) =~ "the model ref is not valid; use provider/model"
    end

    # --resume skips such a file; --session names it.
    test "a tagged term: an unknown version", %{path: path} do
      File.write!(path, String.replace(File.read!(path), ~s("version":1), ~s("version":99)))
      assert resume_message(["--session", Path.basename(path, ".jsonl")]) =~ "version 99"
    end

    test "a tagged posix code: the repair fails", %{tmp_dir: dir, path: path} do
      File.write!(path, "torn", [:append])
      File.chmod!(path, 0o400)
      assert resume_message(dir) =~ "could not repair the session file: permission denied"
    end
  end
end
