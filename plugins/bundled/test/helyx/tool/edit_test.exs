defmodule Helyx.Tool.EditTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Provider.Fake, Helyx.Tool.Edit]})
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\nthree\n")

    %{
      run: fn args ->
        ToolRunner.run_tool(core, %ToolCall{id: "c", name: "edit", arguments: args}, dir)
      end
    }
  end

  test "replaces one exact occurrence", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "a.txt", "old_text" => "two\n", "new_text" => "2\n2b\n"})
    refute result.is_error
    assert Helyx.Message.text(result) == "Edited a.txt"
    assert File.read!(Path.join(dir, "a.txt")) == "one\n2\n2b\nthree\n"
  end

  test "a file that is not valid UTF-8 is an error and the file is untouched", %{
    tmp_dir: dir,
    run: run
  } do
    File.write!(Path.join(dir, "raw.bin"), <<255, 254>>)
    result = run.(%{"path" => "raw.bin", "old_text" => "a", "new_text" => "b"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read raw.bin: binary file, 2 bytes"
    assert File.read!(Path.join(dir, "raw.bin")) == <<255, 254>>
  end

  test "absent text is an error and the file is untouched", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "a.txt", "old_text" => "four", "new_text" => "x"})
    assert result.is_error
    assert Helyx.Message.text(result) == "old_text not found in a.txt"
    assert File.read!(Path.join(dir, "a.txt")) == "one\ntwo\nthree\n"
  end

  test "ambiguous text is an error and the file is untouched", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => "a.txt", "old_text" => "t", "new_text" => "x"})
    assert result.is_error

    assert Helyx.Message.text(result) ==
             "old_text matches more than once in a.txt; make it unique"

    assert File.read!(Path.join(dir, "a.txt")) == "one\ntwo\nthree\n"
  end

  test "overlapping matches are an error and the file is untouched", %{tmp_dir: dir, run: run} do
    File.write!(Path.join(dir, "b.txt"), "aaa")
    result = run.(%{"path" => "b.txt", "old_text" => "aa", "new_text" => "X"})
    assert result.is_error

    assert Helyx.Message.text(result) ==
             "old_text matches more than once in b.txt; make it unique"

    assert File.read!(Path.join(dir, "b.txt")) == "aaa"
  end

  test "empty old_text is an error", %{run: run} do
    assert Helyx.Message.text(run.(%{"path" => "a.txt", "old_text" => "", "new_text" => "x"})) ==
             "old_text is empty"
  end

  test "a directory is an error result", %{tmp_dir: dir, run: run} do
    result = run.(%{"path" => dir, "old_text" => "a", "new_text" => "b"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read #{dir}: not a regular file (directory)"
  end

  test "a missing file is an error result", %{run: run} do
    result = run.(%{"path" => "nope", "old_text" => "a", "new_text" => "b"})
    assert result.is_error
    assert Helyx.Message.text(result) == "cannot read nope: no such file or directory"
  end

  describe "normalized match" do
    setup %{tmp_dir: dir, run: run} do
      edit = fn content, old, new ->
        File.write!(Path.join(dir, "n.txt"), content)
        result = run.(%{"path" => "n.txt", "old_text" => old, "new_text" => new})
        {result, File.read!(Path.join(dir, "n.txt"))}
      end

      %{edit: edit}
    end

    test "curly quotes match straight quotes, both ways", %{edit: edit} do
      {result, after_edit} =
        edit.("a \u2018x\u2019 \u201Cy\u201D\nkeep \u2019\n", "'x' \"y\"", "z")

      refute result.is_error
      assert after_edit == "a z\nkeep \u2019\n"

      {result, after_edit} = edit.("say 'hi'\n", "say \u2018hi\u2019", "bye")
      refute result.is_error
      assert after_edit == "bye\n"
    end

    test "dash types match a hyphen", %{edit: edit} do
      for dash <- ["\u2010", "\u2011", "\u2012", "\u2013", "\u2014", "\u2015", "\u2212", "\uFE58"] do
        {result, after_edit} = edit.("x #{dash} y\n", "x - y", "ok")
        refute result.is_error, inspect(dash)
        assert after_edit == "ok\n"
      end
    end

    test "NFKC forms match", %{edit: edit} do
      # decomposed e + U+0301 against composed U+00E9, and U+00A0 against a space
      {result, after_edit} = edit.("cafe\u0301\u00A0bar\n", "caf\u00E9 bar", "x")
      refute result.is_error
      assert after_edit == "x\n"
    end

    test "trailing spaces inside the match drop, lines outside keep their bytes", %{edit: edit} do
      content = "keep  \nfoo \t\nbar\u00A0\nkeep\t\n"
      {result, after_edit} = edit.(content, "foo\nbar  ", "new")
      refute result.is_error
      assert after_edit == "keep  \nnew\u00A0\nkeep\t\n"
    end

    test "trailing spaces after the matched text stay", %{edit: edit} do
      {result, after_edit} = edit.("x \u2018a\u2019   \nnext\n", "x 'a'", "y")
      refute result.is_error
      assert after_edit == "y   \nnext\n"
    end

    test "a match that starts at a line end keeps the trailing spaces before it", %{edit: edit} do
      {result, after_edit} = edit.("a\u2014  \nb\n", "-\nb", "-\nc")
      refute result.is_error
      assert after_edit == "a-\nc\n"

      {result, after_edit} = edit.("x  \n\u2018b\u2019\n", "\n'b'", "\nc")
      refute result.is_error
      assert after_edit == "x  \nc\n"
    end

    test "two normalized matches are an error and the file is untouched", %{edit: edit} do
      content = "a \u2013 b\na \u2014 b\n"
      {result, after_edit} = edit.(content, "a - b", "x")
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "old_text matches more than once in n.txt; make it unique"

      assert after_edit == content
    end

    test "overlapping normalized matches are an error", %{edit: edit} do
      {result, _} = edit.("\u2013\u2014\u2212", "--", "x")
      assert result.is_error

      assert Helyx.Message.text(result) ==
               "old_text matches more than once in n.txt; make it unique"
    end

    test "a unique exact match wins over normalized matches", %{edit: edit} do
      {result, after_edit} = edit.("a - b\na \u2013 b\n", "a - b", "x")
      refute result.is_error
      assert after_edit == "x\na \u2013 b\n"
    end

    test "old_text of only spaces with no exact match is not found", %{edit: edit} do
      {result, after_edit} = edit.("ab\n", "  ", "x")
      assert result.is_error
      assert Helyx.Message.text(result) == "old_text not found in n.txt"
      assert after_edit == "ab\n"
    end

    test "a match that cuts a grapheme's normalized form is not found", %{edit: edit} do
      # U+FB01 is the ligature fi; its NFKC form is "fi"
      {result, after_edit} = edit.("\uFB01x\n", "ix", "y")
      assert result.is_error
      assert Helyx.Message.text(result) == "old_text not found in n.txt"
      assert after_edit == "\uFB01x\n"

      {result, after_edit} = edit.("\uFB01x\n", "fix", "y")
      refute result.is_error
      assert after_edit == "y\n"
    end

    test "a CRLF file keeps its line ends; LF in new_text becomes CRLF", %{edit: edit} do
      content = "one\r\ntwo \r\nthree\r\nmixed\nend\r\n"
      {result, after_edit} = edit.(content, "two\nthree\n", "2\n3\n")
      refute result.is_error
      assert after_edit == "one\r\n2\r\n3\r\nmixed\nend\r\n"
    end

    test "the exact path also writes CRLF into a CRLF file", %{edit: edit} do
      {result, after_edit} = edit.("one\r\ntwo\r\n", "two", "2\n2b\r\n2c")
      refute result.is_error
      assert after_edit == "one\r\n2\r\n2b\r\n2c\r\n"
    end

    test "an LF file takes new_text as it is", %{edit: edit} do
      {result, after_edit} = edit.("one\ntwo\r\n", "one", "1\n1b")
      refute result.is_error
      assert after_edit == "1\n1b\ntwo\r\n"
    end

    test "a BOM stays when the match is at the start of the file", %{edit: edit} do
      {result, after_edit} = edit.("\uFEFFa \u2014 b\nc\n", "a - b", "x")
      refute result.is_error
      assert after_edit == "\uFEFFx\nc\n"

      {result, after_edit} = edit.("\uFEFFab\n", "ab", "x")
      refute result.is_error
      assert after_edit == "\uFEFFx\n"
    end

    test "a match across the 64 KiB chunk of the normalized text", %{edit: edit} do
      # The normalized text moves to a list in chunks past 65,536 bytes.
      for pad <- 65_530..65_540 do
        filler = String.duplicate("x", pad - 1) <> "\n"
        content = filler <> "a \u2014\u00E9 b  \nc\u2019\n"
        {result, after_edit} = edit.(content, "a -\u00E9 b\nc'", "z")
        refute result.is_error, inspect(pad)
        assert after_edit == filler <> "z\n"
      end
    end

    test "old_text or new_text that is not valid UTF-8 is an error", %{tmp_dir: dir} do
      # Helyx.Session.Stream.check/1 rejects such a tool call before it runs;
      # run/2 is public, so it checks too.
      File.write!(Path.join(dir, "n.txt"), "\u00E9\n")
      error = {:error, "old_text and new_text must be valid UTF-8"}
      run = &Helyx.Tool.Edit.run(%{"path" => "n.txt", "old_text" => &1, "new_text" => &2}, dir)
      assert run.(<<0xA9>>, "x") == error
      assert run.("\u00E9", <<0xFF>>) == error
      assert File.read!(Path.join(dir, "n.txt")) == "\u00E9\n"
    end

    test "a BOM at the start of old_text and new_text matches the file's BOM", %{edit: edit} do
      {result, after_edit} = edit.("\uFEFFab\ncd\n", "\uFEFFab", "\uFEFFx")
      refute result.is_error
      assert after_edit == "\uFEFFx\ncd\n"
    end

    test "an exact match that starts after a CR keeps one CR before the new LF", %{edit: edit} do
      {result, after_edit} = edit.("a\r\nfoo\r\n", "\nfoo", "\nbar")
      refute result.is_error
      assert after_edit == "a\r\nbar\r\n"
    end

    test "a cluster that the trailing space trim cuts still matches", %{edit: edit} do
      # U+0600 is a Prepend character: it and the space after it are one cluster.
      {result, after_edit} = edit.("\u2018x\u0600 \nnext\n", "'x\u0600", "y")
      refute result.is_error
      assert after_edit == "y\nnext\n"
    end

    test "no exact and no normalized match is not found", %{edit: edit} do
      {result, _} = edit.("a \u2014 b\n", "a + b", "x")
      assert Helyx.Message.text(result) == "old_text not found in n.txt"
    end
  end
end
