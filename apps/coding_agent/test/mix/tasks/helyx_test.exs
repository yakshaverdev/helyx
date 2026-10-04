defmodule Mix.Tasks.HelyxTest do
  # Not async: the sessions directory is application env, and the task
  # starts Core under its default name.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  describe "mix helyx --resume prints a resume error as a sentence" do
    @describetag :tmp_dir

    # The task has no terminal here. Every case fails before the TUI starts.
    setup %{tmp_dir: dir} do
      Application.put_env(:coding_agent, :sessions_dir, dir)
      on_exit(fn -> Application.delete_env(:coding_agent, :sessions_dir) end)
      {:ok, file} = Helyx.Session.File.create(dir, "s1", dir, "fake/echo")
      %{path: file.path, header_id: file.leaf}
    end

    # The task stops Mix with status 1 after one line on stderr.
    defp resume_message(dir) do
      stderr =
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Helyx.run([dir, "--resume"])) == {:shutdown, 1}
        end)

      assert "helyx: could not start the agent" <> message = stderr
      refute message =~ "{"
      assert [_line] = String.split(message, "\n", trim: true)
      message
    end

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

    # The entries below hang from the header, so they are on the branch that
    # the resume reads.
    test "a tagged text: a damaged file", %{tmp_dir: dir, path: path, header_id: header_id} do
      File.write!(path, ~s({"type":"bogus","id":"x","parent_id":"#{header_id}"}\n), [:append])
      assert resume_message(dir) =~ "the session file is damaged: entry the writer never"
    end

    test "a tagged text: an exception message of many lines",
         %{tmp_dir: dir, path: path, header_id: header_id} do
      line = ~s({"type":"message","id":"m1","parent_id":"#{header_id}","role":"user"}\n)
      File.write!(path, line, [:append])
      assert resume_message(dir) =~ "the session file is damaged: protocol Enumerable"
    end

    test "a saved model ref that is not valid", %{tmp_dir: dir, path: path, header_id: header_id} do
      line = ~s({"type":"model_change","id":"m1","parent_id":"#{header_id}","model":"nope"}\n)
      File.write!(path, line, [:append])
      assert resume_message(dir) =~ "the model ref is not valid; use provider/model"
    end

    test "a tagged term: an unknown version", %{tmp_dir: dir, path: path} do
      File.write!(path, ~s({"type":"session","version":99,"cwd":#{JSON.encode!(dir)}}\n))
      assert resume_message(dir) =~ "version 99"
    end

    test "a tagged posix code: the repair fails", %{tmp_dir: dir, path: path} do
      File.write!(path, "torn", [:append])
      File.chmod!(path, 0o400)
      assert resume_message(dir) =~ "could not repair the session file: permission denied"
    end
  end
end
