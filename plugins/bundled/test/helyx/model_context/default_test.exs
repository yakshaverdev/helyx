defmodule Helyx.ModelContext.DefaultTest do
  use ExUnit.Case, async: true

  alias Helyx.ModelContext.Default

  @moduletag :tmp_dir

  # The total cap of `Helyx.ModelContext.Default`, in bytes.
  @max_total_bytes 2 * Helyx.Text.max_bytes()

  # The chain starts at the filesystem root, so folders above the test
  # directory can add their own files. Each test asserts only on files under
  # its own directory.

  @model %Helyx.ModelRef{provider: "fake", model: "m1"}

  defp system(home, cwd, opts \\ []) do
    opts = Keyword.merge([cwd: cwd, home: home, model: @model, session_id: "s1"], opts)
    %Helyx.Context{system: system} = Default.build(%Helyx.Context{}, opts)
    system
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp count(system, text), do: length(String.split(system, text)) - 1

  test "concatenates one file per folder from the top down to the working directory",
       %{tmp_dir: dir} do
    cwd = Path.join(dir, "code/proj")
    File.mkdir_p!(cwd)
    write!(Path.join(dir, "AGENTS.md"), "top rules")
    write!(Path.join(dir, "code/CLAUDE.md"), "code rules")
    write!(Path.join(cwd, "AGENTS.override.md"), "proj rules")

    system = system(Path.join(dir, "home"), cwd)

    assert system =~ "## #{Path.join(dir, "AGENTS.md")}\n\ntop rules"
    assert system =~ "## #{Path.join(dir, "code/CLAUDE.md")}\n\ncode rules"
    assert system =~ "## #{Path.join(cwd, "AGENTS.override.md")}\n\nproj rules"
    assert system =~ ~r/top rules.*code rules.*proj rules/s
  end

  test "a folder gives the first of AGENTS.override.md, AGENTS.md, CLAUDE.md", %{tmp_dir: dir} do
    cwd = Path.join(dir, "a/b")
    write!(Path.join(dir, "a/AGENTS.md"), "a agents")
    write!(Path.join(dir, "a/CLAUDE.md"), "a claude")
    write!(Path.join(cwd, "AGENTS.override.md"), "b override")
    write!(Path.join(cwd, "AGENTS.md"), "b agents")
    write!(Path.join(cwd, "CLAUDE.md"), "b claude")

    system = system(Path.join(dir, "home"), cwd)

    assert system =~ "a agents"
    assert system =~ "b override"
    refute system =~ "a claude"
    refute system =~ "b agents"
    refute system =~ "b claude"
  end

  test "a directory with a context file name is not a file", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "AGENTS.override.md"))
    write!(Path.join(dir, "AGENTS.md"), "agents rules")

    assert system(Path.join(dir, "home"), dir) =~ "agents rules"
  end

  test "the global file comes before the folder files", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(dir, "proj")
    write!(Path.join(home, ".helyx/AGENTS.md"), "global rules")
    write!(Path.join(cwd, "AGENTS.md"), "proj rules")

    system = system(home, cwd)

    assert system =~ "## #{Path.join(home, ".helyx/AGENTS.md")}\n\nglobal rules"
    assert system =~ ~r/global rules.*proj rules/s
  end

  test "a folder without a context file is skipped without error", %{tmp_dir: dir} do
    cwd = Path.join(dir, "code/proj")
    File.mkdir_p!(cwd)
    write!(Path.join(cwd, "AGENTS.md"), "proj rules")

    system = system(Path.join(dir, "home"), cwd)

    assert system =~ "You are a coding agent."
    assert system =~ "proj rules"
    assert count(system, "## #{dir}") == 1
  end

  test "a working directory in the global folder loads the global file once", %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    write!(Path.join(home, ".helyx/AGENTS.md"), "global rules")

    assert count(system(home, Path.join(home, ".helyx")), "global rules") == 1
  end

  test "a symlink to a file already loaded loads it once", %{tmp_dir: dir} do
    cwd = Path.join(dir, "proj")
    write!(Path.join(dir, "AGENTS.md"), "top rules")
    File.mkdir_p!(cwd)
    File.ln_s!(Path.join(dir, "AGENTS.md"), Path.join(cwd, "AGENTS.md"))

    system = system(Path.join(dir, "home"), cwd)

    assert count(system, "top rules") == 1
    assert system =~ "## #{Path.join(dir, "AGENTS.md")}\n\ntop rules"
  end

  test "an unreadable context file is skipped without error", %{tmp_dir: dir} do
    cwd = Path.join(dir, "code")
    write!(Path.join(dir, "AGENTS.md"), <<0xFF, 0xFE, "not utf8">>)
    write!(Path.join(cwd, "CLAUDE.md"), "code rules")

    system = system(Path.join(dir, "home"), cwd)

    assert system =~ "code rules"
    refute system =~ "## #{Path.join(dir, "AGENTS.md")}"
  end

  test "an unreadable first file does not fall back to the next name", %{tmp_dir: dir} do
    write!(Path.join(dir, "AGENTS.override.md"), <<0xFF, 0xFE, "not utf8">>)
    write!(Path.join(dir, "AGENTS.md"), "agents rules")

    refute system(Path.join(dir, "home"), dir) =~ "agents rules"
  end

  test "a long context file is truncated on whole lines", %{tmp_dir: dir} do
    write!(Path.join(dir, "AGENTS.md"), Enum.map_join(1..3000, "\n", &"line #{&1}"))

    system = system(Path.join(dir, "home"), dir)

    assert system =~ "line 1\n"
    assert system =~ ~r/\[truncated: showing lines 1-\d+ of 3000; read again with offset \d+\]/
    refute system =~ "line 3000"
  end

  test "over the total cap, the files farthest from the working directory are left out",
       %{tmp_dir: dir} do
    home = Path.join(dir, "home")
    cwd = Path.join(dir, "a/b/c")
    # Each file is just under the per-file byte cap, so two fit in the total
    # cap and a third does not.
    big = fn tag -> tag <> "\n" <> String.duplicate("x", Helyx.Text.max_bytes() - 1_000) end
    write!(Path.join(home, ".helyx/AGENTS.md"), "global rules")
    write!(Path.join(dir, "a/AGENTS.md"), big.("a rules"))
    write!(Path.join(dir, "a/b/AGENTS.md"), big.("b rules"))
    write!(Path.join(cwd, "AGENTS.md"), big.("c rules"))

    system = system(home, cwd)

    assert system =~ ~r/b rules.*c rules/s
    refute system =~ "a rules"
    refute system =~ "global rules"

    [base, _] = String.split(system, "\n\n## /", parts: 2)
    assert byte_size(system) - byte_size(base) <= @max_total_bytes
  end

  # Two files whose sections, each with its separator, add up to the total
  # cap plus `extra` bytes, each under the per-file cap so no truncation
  # changes its size. The near file is multibyte, so the cap counts bytes,
  # not characters.
  defp two_files_at_cap(dir, extra) do
    far = Path.join(dir, "AGENTS.md")
    near = Path.join(dir, "near/AGENTS.md")
    cost = fn path -> byte_size("## #{path}\n\n") + 2 end
    near_content = String.duplicate("é", 25_500)
    far_bytes = @max_total_bytes + extra - cost.(near) - byte_size(near_content) - cost.(far)
    assert far_bytes <= Helyx.Text.max_bytes()
    write!(far, "far " <> String.duplicate("x", far_bytes - 4))
    write!(near, near_content)
    system(Path.join(dir, "home"), Path.dirname(near))
  end

  test "files that fill the total cap exactly are all kept", %{tmp_dir: dir} do
    system = two_files_at_cap(dir, 0)

    assert system =~ "far x"
    assert system =~ "é"
    [base, _] = String.split(system, "\n\n## /", parts: 2)
    assert byte_size(system) - byte_size(base) == @max_total_bytes
  end

  test "one byte over the total cap leaves the farther file out", %{tmp_dir: dir} do
    system = two_files_at_cap(dir, 1)

    refute system =~ "far x"
    assert system =~ "é"
  end

  describe "the docs and session sections" do
    # The bound of one value line, in bytes.
    @max_value_bytes 4_096

    defp docs_root!(dir) do
      root = Path.join(dir, "helyx")
      write!(Path.join(root, "README.md"), "readme")
      root
    end

    test "come after the base prompt and before the context files", %{tmp_dir: dir} do
      root = docs_root!(dir)
      write!(Path.join(dir, "AGENTS.md"), "proj rules")

      system =
        system(Path.join(dir, "home"), dir,
          docs_root: root,
          session_dir: Path.join(dir, "sessions/proj")
        )

      assert system =~ "README: #{root}/README.md\n"
      assert system =~ "Feature docs: #{root}/docs/features/\n"
      assert system =~ "Decisions: #{root}/docs/adr/\n"

      assert system =~
               ~r/You are a coding agent.*## Helyx docs.*## This session.*## #{dir}.*proj rules/s

      # Exactly the four values, and nothing else.
      [_, section] = Regex.run(~r/\n\n(## This session\n.*?)\n\n## \//s, system)

      assert section ==
               "## This session\n\nWorking directory: #{dir}\nModel: fake/m1\nSession id: s1\n" <>
                 "Session directory: #{dir}/sessions/proj"
    end

    test "a session that is not saved says so", %{tmp_dir: dir} do
      assert system(Path.join(dir, "home"), dir) =~ "Session directory: not saved\n"
    end

    test "without a README at the root, only the docs section is left out", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, "helyx/README.md"))

      system = system(Path.join(dir, "home"), dir, docs_root: Path.join(dir, "helyx"))

      refute system =~ "## Helyx docs"
      assert system =~ "## This session"
      assert system =~ "Working directory: #{dir}\n"
    end

    test "every file of the docs map exists at the default root", %{tmp_dir: dir} do
      system = system(Path.join(dir, "home"), dir)
      [_, section] = Regex.run(~r/## Helyx docs\n(.*)\n\n## This session/s, system)
      [_, root] = Regex.run(~r/Helyx root: (.+)\n/, section)
      paths = Regex.scan(~r/(?:README|docs\/[\w\/.-]+)\.md/, section) |> List.flatten()

      assert paths != []
      for path <- paths, do: assert(File.regular?(Path.join(root, path)), path)
    end

    # The value of the line with `label`, which must be the only one.
    defp value(system, label) do
      [value] = for line <- String.split(system, "\n"), line =~ ~r/^#{label}: /, do: line
      String.replace_prefix(value, label <> ": ", "")
    end

    defp session_id_value(dir, id),
      do: value(system(Path.join(dir, "home"), dir, session_id: id), "Session id")

    test "a value of #{@max_value_bytes} bytes is kept whole, one over is cut", %{tmp_dir: dir} do
      for n <- [@max_value_bytes - 1, @max_value_bytes] do
        id = String.duplicate("a", n)
        assert session_id_value(dir, id) == id
      end

      over = String.duplicate("a", @max_value_bytes) <> "b"
      assert session_id_value(dir, over) == String.duplicate("a", @max_value_bytes)
    end

    test "a multibyte value is cut on a whole character", %{tmp_dir: dir} do
      # 4,098 bytes: the cut keeps 2,048 whole characters.
      assert session_id_value(dir, String.duplicate("é", 2_049)) == String.duplicate("é", 2_048)
      # 4,097 bytes: the cut splits the last kept character and drops it.
      assert session_id_value(dir, "a" <> String.duplicate("é", 2_048)) ==
               "a" <> String.duplicate("é", 2_047)
    end

    test "invalid UTF-8 in a value is dropped before the line breaks are replaced",
         %{tmp_dir: dir} do
      system = system(Path.join(dir, "home"), dir, session_dir: <<"/x", 0xFF, "\ny">>)

      assert value(system, "Session directory") == "/x y"
    end

    test "every line break in a value becomes one space", %{tmp_dir: dir} do
      cwd = Path.join(dir, "a\r\nb\nc\rd\ve\ff\u0085g\u2028h\u2029i")

      system = system(Path.join(dir, "home"), cwd, docs_root: docs_root!(dir))

      assert value(system, "Working directory") == Path.join(dir, "a b c d e f g h i")
      assert system =~ "\n## This session\n\nWorking directory: "
    end
  end

  describe "the skills section" do
    setup %{tmp_dir: dir} do
      cwd = Path.join(dir, "repo")
      File.mkdir_p!(Path.join(cwd, ".git"))

      write!(
        Path.join(cwd, ".agents/skills/probe/SKILL.md"),
        "---\nname: probe\ndescription: Probe it.\n---\nbody\n"
      )

      %{cwd: cwd, home: Path.join(dir, "home")}
    end

    defp build(cwd, home, tools) do
      opts = [cwd: cwd, home: home, model: @model, session_id: "s1"]
      Default.build(%Helyx.Context{tools: tools}, opts).system
    end

    test "comes after the session section when the skill tool is there", %{cwd: cwd, home: home} do
      tool = %{name: "skill", description: "", parameters: %{}}
      system = build(cwd, home, [tool])

      assert system =~
               ~r/## This session\n.*\n\n## Skills\n\n.*skill tool.*\n\n- probe: Probe it.(\n\n|\z)/s

      assert count(system, "## Skills") == 1
    end

    test "is left out without the skill tool or with no skill", %{cwd: cwd, home: home} do
      refute build(cwd, home, [%{name: "read", description: "", parameters: %{}}]) =~ "## Skills"
      File.rm_rf!(Path.join(cwd, ".agents"))
      refute build(cwd, home, [%{name: "skill", description: "", parameters: %{}}]) =~ "## Skills"
    end
  end

  describe "the skills loaded before a summary" do
    # docs/features/skills.md, "After a summary compaction".
    alias Helyx.Message

    @max_bytes 32_768

    defp user(id, text), do: %{Message.user(text) | id: id}

    defp skill_result(id, text, is_error \\ false) do
      call = %Message.ToolCall{id: "c-" <> id, name: "skill", arguments: %{}}
      result = if is_error, do: {:error, text}, else: {:ok, text}
      %{Message.tool_result(call, result) | id: id}
    end

    defp load(name, body \\ "body"),
      do: ~s(<skill name="#{name}">\nFolder: /f\n\n#{body}\n</skill>)

    defp messages(messages, summary, dir) do
      opts = [cwd: dir, home: dir, model: @model, session_id: "s1", summary: summary]
      Default.build(%Helyx.Context{messages: messages}, opts).messages
    end

    defp summary(id), do: %Helyx.Summary{text: "old", first_kept_id: id, tokens_before: 1}

    test "the skills of the summarized part go in one message before the first kept message, newest first",
         %{tmp_dir: dir} do
      before = [
        user("u1", load("ship") <> "\n\n730"),
        skill_result("r1", load("tdd")),
        user("u2", "go on")
      ]

      kept = [user("u3", "next")]

      {built, [carried | ^kept]} = Enum.split(messages(before ++ kept, summary("u3"), dir), 3)
      assert built == before
      assert carried.role == :user and carried.id == nil
      text = Message.text(carried)

      assert text =~
               ~r/\A.*\n\n<skill name="tdd">.*<\/skill>\n\n<skill name="ship">.*<\/skill>\z/s

      refute text =~ "730"
    end

    test "with no summary, or no load before the cut, the messages do not change",
         %{tmp_dir: dir} do
      list = [user("u1", load("ship")), user("u2", "next")]
      assert messages(list, nil, dir) == list
      assert messages(list, summary("u1"), dir) == list
      # A first kept id that is not in the messages cuts nothing.
      assert messages(list, summary("gone"), dir) == list
    end

    test "a skill loaded again after the cut, an error result, and another tool are not carried",
         %{tmp_dir: dir} do
      other = %{
        Message.tool_result(
          %Message.ToolCall{id: "c", name: "read", arguments: %{}},
          {:ok, load("b")}
        )
        | id: "r2"
      }

      before = [user("u1", load("a")), skill_result("r1", load("c"), true), other]
      list = before ++ [user("u2", "next"), skill_result("r3", load("a"))]
      assert messages(list, summary("u2"), dir) == list
    end

    test "at most five bodies, then one line per skill; a body over the bound gets a line",
         %{tmp_dir: dir} do
      big = load("big", String.duplicate("x", @max_bytes))
      small = for n <- 1..6, do: user("u#{n}", load("s#{n}"))
      list = [user("u0", big) | small] ++ [user("k", "next")]
      text = list |> messages(summary("k"), dir) |> Enum.at(-2) |> Message.text()

      for n <- 2..6, do: assert(text =~ ~s(<skill name="s#{n}">))
      refute text =~ ~s(<skill name="s1">) or text =~ ~s(<skill name="big">)
      assert text =~ ~r/\bs1\b.*load it again/
      assert text =~ ~r/\bbig\b.*load it again/
    end

    test "the message is at most #{@max_bytes} bytes with many skills", %{tmp_dir: dir} do
      bodies = for n <- 1..5, do: user("b#{n}", load("b#{n}", String.duplicate("y", 6_000)))
      names = for n <- 1..1_000, do: user("n#{n}", load("name-#{n}"))
      list = names ++ bodies ++ [user("k", "next")]
      text = list |> messages(summary("k"), dir) |> Enum.at(-2) |> Message.text()

      assert byte_size(text) <= @max_bytes
      assert count(text, "<skill name=") == 5

      # The lines go newest first, and from the first that does not fit,
      # every older skill is left out.
      named =
        for [_, n] <- Regex.scan(~r/The skill name-(\d+) was loaded too/, text),
            do: String.to_integer(n)

      assert [1_000 | _] = named
      assert named == Enum.to_list(1_000..List.last(named)//-1)
      assert List.last(named) > 1
    end

    test "a text that fills the bound to the byte is carried; one byte more gets a line",
         %{tmp_dir: dir} do
      carried = fn body ->
        [user("u1", body), user("k", "next")]
        |> messages(summary("k"), dir)
        |> Enum.at(-2)
        |> Message.text()
      end

      small = load("x")
      intro = byte_size(carried.(small)) - byte_size(small) - 2
      fill = String.duplicate("z", @max_bytes - intro - 2 - byte_size(small) + byte_size("body"))
      exact = load("x", fill)

      assert byte_size(carried.(exact)) == @max_bytes
      assert carried.(exact) =~ exact
      over = carried.(load("x", fill <> "z"))
      refute over =~ ~s(<skill name="x">)
      assert over =~ "The skill x was loaded too"
    end

    test "a skill loaded twice before the cut carries its newest text", %{tmp_dir: dir} do
      list = [
        user("u1", load("ship", "first-text")),
        user("u2", load("ship", "second-text")),
        user("k", "next")
      ]

      text = list |> messages(summary("k"), dir) |> Enum.at(-2) |> Message.text()

      assert text =~ "second-text"
      refute text =~ "first-text"
      assert count(text, ~s(<skill name="ship">)) == 1
    end

    test "the summary plugin keeps the message after its summary", %{tmp_dir: dir} do
      list = [user("u1", load("ship")), user("u2", "next")]
      context = %Helyx.Context{messages: messages(list, summary("u2"), dir)}
      compacted = Helyx.Compaction.Summary.compact(context, summary: summary("u2"), trigger: nil)

      assert [framed, carried, "next"] = Enum.map(compacted.messages, &Message.text/1)
      assert framed =~ "<summary>"
      assert carried =~ ~s(<skill name="ship">)
    end
  end
end
