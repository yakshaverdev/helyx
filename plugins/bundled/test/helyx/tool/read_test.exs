defmodule Helyx.Tool.ReadTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  # Room for scheduler load in the time of a read: far above what load adds
  # to a read of milliseconds, below the seconds that issue #78 took.
  @load_us 2_000_000

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

    below = "an integer below 1"
    fraction = "a number that is not a whole number of 1 or more"

    for {bad, kind} <- [
          {"2", "a string"},
          {2.5, fraction},
          {0, below},
          {-1, below},
          {0.0, fraction},
          {-0.0, fraction},
          {-2.0, fraction},
          {true, "a boolean"},
          {[2], "an array"},
          {%{"a" => 2}, "an object"},
          {String.duplicate("😀", 100_000), "a string"},
          # The largest integer that the session gives to a tool (#79).
          {-(10 ** 100 - 1), below}
        ] do
      result = run.(%{"path" => "a.txt", "offset" => bad})
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "offset must be a positive integer (a 1-based line number), got #{kind}"

      assert byte_size(Helyx.Message.text(result)) <= 111
    end
  end

  test "a bad offset is an error before the file is read", %{run: run} do
    assert Helyx.Message.text(run.(%{"path" => "nope.txt", "offset" => 0})) =~ "offset must be"
  end

  test "an offset after the last line is an error that names the offset and the line count (issue #78)",
       %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")

    for offset <- [3, 3.0, 999_999_999, 1_000_000_000] do
      result = run.(%{"path" => "a.txt", "offset" => offset})
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "offset #{trunc(offset)} is after the last line: a.txt has 2 lines"
    end

    File.write!(Path.join(dir, "é.txt"), "é\nü")

    assert Helyx.Message.text(run.(%{"path" => "é.txt", "offset" => 3})) ==
             "offset 3 is after the last line: é.txt has 2 lines"

    File.write!(Path.join(dir, "one.txt"), "one")

    assert Helyx.Message.text(run.(%{"path" => "one.txt", "offset" => 2})) ==
             "offset 2 is after the last line: one.txt has 1 line"
  end

  test "the last line is not after the last line, and trailing blank lines are lines (issue #78)",
       %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n\n")

    for {offset, text} <- [{2, "two\n"}, {3, ""}] do
      result = run.(%{"path" => "a.txt", "offset" => offset})
      refute result.is_error
      assert Helyx.Message.text(result) == text
    end

    assert run.(%{"path" => "a.txt", "offset" => 4}).is_error
  end

  test "the error and the truncation notice count the same lines (issue #78)", %{
    tmp_dir: dir,
    run: run
  } do
    for ending <- ["", "\n", "\n\n"] do
      File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..2001, "\n", &"#{&1}") <> ending)
      [_, total] = Regex.run(~r/ of (\d+)/, Helyx.Message.text(run.(%{"path" => "long.txt"})))
      total = String.to_integer(total)

      refute run.(%{"path" => "long.txt", "offset" => total}).is_error

      assert Helyx.Message.text(run.(%{"path" => "long.txt", "offset" => total + 1})) =~
               "long.txt has #{total} lines"
    end
  end

  test "an empty file is an empty ok result at line 1 and an error after it (issue #78)", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "empty.txt"), "")

    for args <- [%{}, %{"offset" => 1}, %{"offset" => nil}] do
      result = run.(Map.put(args, "path", "empty.txt"))
      refute result.is_error
      assert Helyx.Message.text(result) == ""
    end

    result = run.(%{"path" => "empty.txt", "offset" => 2})
    assert result.is_error

    assert Helyx.Message.text(result) ==
             "offset 2 is after the last line: empty.txt has 0 lines"
  end

  test "a huge offset is an error of bounded size that does not show the value, not a crash", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo")

    # 100 digits: the largest integer that the session gives to a tool (#79).
    for offset <- [1.0e300, 1_000_000_001, 10 ** 100 - 1] do
      result = run.(%{"path" => "a.txt", "offset" => offset})
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "offset over 1000000000 is after the last line: a.txt has 2 lines"
    end
  end

  test "the time of a read does not grow with the digits of the offset (issue #78)", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), String.duplicate("\n", 1_000_000))

    # The window code gets no big integer. With one subtraction of 100,000
    # digits for each line, this read took seconds. Since #79 the session
    # gives a tool at most 100 digits, so this is the largest offset.
    {micros, result} = :timer.tc(fn -> run.(%{"path" => "a.txt", "offset" => 10 ** 100 - 1}) end)

    assert Helyx.Message.text(result) ==
             "offset over 1000000000 is after the last line: a.txt has 1000000 lines"

    assert micros < @load_us
  end

  test "an offset of more than 100 digits never reaches the tool (issue #79)", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo")

    {micros, result} =
      :timer.tc(fn -> run.(%{"path" => "a.txt", "offset" => Integer.pow(10, 100_000)}) end)

    assert result.is_error

    assert Helyx.Message.text(result) ==
             "tool call not run: an integer in the arguments has more than 100 digits"

    assert micros < @load_us
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

  test "a float offset with no fraction is the integer, and a null offset is line 1", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree")

    for {offset, text} <- [
          {2.0, "two\nthree"},
          {1.0, "one\ntwo\nthree"},
          {nil, "one\ntwo\nthree"}
        ] do
      assert Helyx.Message.text(run.(%{"path" => "a.txt", "offset" => offset})) == text
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
