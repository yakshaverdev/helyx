defmodule Helyx.Tool.ReadTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Read]})

    %{
      run: fn args ->
        ToolRunner.run_tool(core, %ToolCall{id: "c", name: "read", arguments: args}, dir)
      end
    }
  end

  test "returns the content of a file relative to the working directory", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    result = run.(%{"path" => "a.txt"})
    refute result.is_error
    assert Helyx.Message.text(result) == "one\ntwo\n"
  end

  test "truncates a long file to its head and names the next offset", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..3000, "\n", &to_string/1))
    text = Helyx.Message.text(run.(%{"path" => "long.txt"}))
    assert String.starts_with?(text, "1\n2\n")

    assert String.ends_with?(
             text,
             "2000\n[truncated: showing lines 1-2000 of 3000; read again with offset 2001]"
           )
  end

  test "a first line over the byte cap is reported as cut (issue #50)", %{tmp_dir: dir, run: run} do
    line = String.duplicate("x", 51_500 - 11) <> "TAIL_MARKER"
    File.write!(Path.join(dir, "wide.txt"), line <> "\nline2")

    text = Helyx.Message.text(run.(%{"path" => "wide.txt"}))
    refute text =~ "TAIL_MARKER"

    assert String.ends_with?(
             text,
             "\n[truncated: showing lines 1-1 of 2, line 1 cut at 51200 bytes; read again with offset 2]"
           )
  end

  test "a cut last line names no offset (issue #61)", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "wide.txt"), "a\n" <> String.duplicate("x", 60_000) <> "\n")

    assert String.ends_with?(
             Helyx.Message.text(run.(%{"path" => "wide.txt", "offset" => 2})),
             "\n[truncated: showing lines 2-2 of 2, line 2 cut at 51200 bytes]"
           )
  end

  test "offset reads from a later line", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree")
    assert Helyx.Message.text(run.(%{"path" => "a.txt", "offset" => 2})) == "two\nthree"
  end

  test "a truncated offset read reports absolute lines and continues with no gap", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..5000, "\n", &to_string/1))

    first = Helyx.Message.text(run.(%{"path" => "long.txt", "offset" => 2001}))
    assert String.starts_with?(first, "2001\n")

    assert String.ends_with?(
             first,
             "4000\n[truncated: showing lines 2001-4000 of 5000; read again with offset 4001]"
           )

    second = Helyx.Message.text(run.(%{"path" => "long.txt", "offset" => 4001}))
    assert String.starts_with?(second, "4001\n")
    assert String.ends_with?(second, "\n5000")
  end

  test "an offset that is not a positive integer is an error result (issue #75)", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree")

    # The largest integer that the session gives to a tool (#79) is last.
    for bad <- ["2", 2.0, 2.5, 0, -1, true, [2], %{"a" => 2}, -(10 ** 100 - 1)] do
      result = run.(%{"path" => "a.txt", "offset" => bad})
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "offset must be a positive integer (a 1-based line number)"
    end
  end

  test "a bad offset is an error before the file is read", %{run: run} do
    assert Helyx.Message.text(run.(%{"path" => "nope.txt", "offset" => 0})) =~ "offset must be"
  end

  test "an offset of more than 100 digits never reaches the tool (issue #79)", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo")

    result = run.(%{"path" => "a.txt", "offset" => Integer.pow(10, 100_000)})
    assert result.is_error

    assert Helyx.Message.text(result) ==
             "tool call not run: an integer in the arguments has more than 100 digits"
  end

  test "the tool has no limit argument and ignores a limit key (issue #75)", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo")

    for limit <- [1, "x", 0, -1, 1.5, 1.0] do
      assert Helyx.Message.text(run.(%{"path" => "a.txt", "limit" => limit})) == "one\ntwo"
    end
  end

  test "a null offset is line 1, and an offset after the last line is empty", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree")

    for {offset, text} <- [{nil, "one\ntwo\nthree"}, {4, ""}, {10 ** 99, ""}] do
      result = run.(%{"path" => "a.txt", "offset" => offset})
      refute result.is_error
      assert Helyx.Message.text(result) == text
    end
  end

  test "a missing file is an error result", %{run: run} do
    result = run.(%{"path" => "nope.txt"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read nope.txt: no such file or directory"
  end

  test "a device file is an error result, not a hang", %{run: run} do
    result = run.(%{"path" => "/dev/zero"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read /dev/zero: not a regular file (device)"
  end

  test "a file over the size limit is an error result", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "big.bin"), :binary.copy(<<0>>, 10_485_761))
    result = run.(%{"path" => "big.bin"})
    assert result.is_error

    assert Helyx.Message.text(result) ==
             "cannot read big.bin: over the 10485760-byte limit"
  end

  test "a file that is not valid UTF-8 is an error result", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "raw.bin"), <<255, 254>>)
    result = run.(%{"path" => "raw.bin"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read raw.bin: binary file, 2 bytes"
  end

  test "missing arguments are an error result", %{run: run} do
    assert run.(%{}).is_error
    assert Helyx.Message.text(run.(%{"path" => 1})) == "read needs a path"
  end
end
