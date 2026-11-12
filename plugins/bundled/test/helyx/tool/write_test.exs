defmodule Helyx.Tool.WriteTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Write]})

    %{
      run: fn args ->
        ToolRunner.run_tool(
          core,
          %ToolCall{id: "c", name: "write", arguments: args},
          dir
        )
      end
    }
  end

  test "creates a file and its directories", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "sub/dir/a.txt", "content" => "hello"})
    refute result.is_error
    assert Helyx.Message.text(result) == "Wrote sub/dir/a.txt"
    assert File.read!(Path.join(dir, "sub/dir/a.txt")) == "hello"
  end

  test "replaces an existing file", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "a.txt"), "old")
    refute run.(%{"path" => "a.txt", "content" => "new"}).is_error
    assert File.read!(Path.join(dir, "a.txt")) == "new"
  end

  test "the result carries a diff of the overwritten file", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "a.txt"), "old\n")

    result = run.(%{"path" => "a.txt", "content" => "new\n"})
    refute result.is_error
    assert Helyx.Message.text(result) == "Wrote a.txt"

    assert [%{"kind" => "diff"} = block] = result.ui_blocks
    assert block["added"] == 1
    assert block["removed"] == 1
    assert [hunk] = block["hunks"]
    assert hunk["lines"] == ["-old", "+new"]
  end

  test "a new file is all added lines", %{run: run} do
    result = run.(%{"path" => "new.txt", "content" => "a\nb\n"})
    refute result.is_error

    assert [block] = result.ui_blocks
    assert block["added"] == 2
    assert block["removed"] == 0
    assert [hunk] = block["hunks"]
    assert hunk["lines"] == ["+a", "+b"]
  end

  test "an old file that is not UTF-8 gives a block without hunks", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "raw.bin"), <<255, 254>>)

    result = run.(%{"path" => "raw.bin", "content" => "new"})
    refute result.is_error
    assert Helyx.Message.text(result) == "Wrote raw.bin"

    assert [block] = result.ui_blocks
    assert block["hunks"] == []
    assert block["cut"] == true

    assert block["text"] ==
             "raw.bin: written; the old file is not shown (binary file, 2 bytes)"

    assert File.read!(Path.join(dir, "raw.bin")) == "new"
  end

  test "an error result carries no block", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "file"), "")
    result = run.(%{"path" => "file/a.txt", "content" => "x"})
    assert result.is_error
    assert result.ui_blocks == []
  end

  test "a path under a file is an error result", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "file"), "")
    result = run.(%{"path" => "file/a.txt", "content" => "x"})
    assert result.is_error
    assert Helyx.Message.text(result) =~ "cannot write file/a.txt"
  end

  # The open of a FIFO with no reader blocks; the call must return at once.
  test "a FIFO or a folder at the path is an error result", %{tmp_dir: dir, run: run} do
    fifo = Path.join(dir, "fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    File.mkdir!(Path.join(dir, "sub"))

    result = run.(%{"path" => "fifo", "content" => "x"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot write fifo: not a regular file (other)"

    result = run.(%{"path" => "sub", "content" => "x"})
    assert Helyx.Message.text(result) == "cannot write sub: not a regular file (directory)"
  end

  test "missing arguments are an error result", %{run: run} do
    result = run.(%{"path" => "a.txt"})
    assert result.is_error
    assert Helyx.Message.text(result) == "content is required"
  end
end
