defmodule Helyx.Skills.FrontmatterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helyx.Skills.Frontmatter

  defp read(yaml), do: Frontmatter.read("---\n" <> yaml <> "---\nBody.\n")
  defp description(yaml), do: read("name: x\ndescription:" <> yaml)

  # Accepted forms give the same text as YAML.
  defp same_as_yaml(yaml) do
    assert {:ok, values} = read(yaml), yaml
    assert {:ok, ^values} = yaml |> YamlElixir.read_from_string() |> take(), yaml
    values
  end

  defp take({:ok, %{"name" => name, "description" => description}}),
    do: {:ok, %{"name" => name, "description" => description}}

  defp take(other), do: other

  test "the forms of name and description that the reader accepts" do
    cases = [
      {" Plain text\n", "Plain text"},
      {" Use when:it fits # a comment\n", "Use when:it fits"},
      {" Tab\tinside\t\n", "Tab\tinside"},
      {"  text \n", " text "},
      {" x\n  # an indented comment\n\n", "x"},
      {" 'It''s # quoted'  # comment\n", "It's # quoted"},
      {~S( "Tab\tquote \"x\" \\ \x41 é \U0001F600 \/ \_") <> "\n",
       "Tab\tquote \"x\" \\ A é 😀 /  "},
      {" |\n  Line one\n    indented\n  Line two\n\n", "Line one\n  indented\nLine two\n"},
      {" |-\n  Stripped\n\n", "Stripped"},
      {" |+\n  Kept\n\n", "Kept\n\n"},
      {" | # comment\n  a\n\n  b\n", "a\n\nb\n"},
      {" >\n  Folded\n  text\n\n  Next\n    more\n  end\n", "Folded text\nNext\n  more\nend\n"},
      {" >\n\n  After an empty line\n", "\nAfter an empty line\n"},
      {" >-\n  Folded\n  stripped\n# a comment ends it\n", "Folded stripped"},
      # The blank after the colon goes, but not a mark that combines with it.
      {" \u0301x\n", "\u0301x"},
      {" x\u00A0\n", "x\u00A0"},
      {" \u00A0x\n", "\u00A0x"},
      {" \t x\n", "x"}
    ]

    for {yaml, text} <- cases do
      assert same_as_yaml("name: x\ndescription:" <> yaml) == %{
               "name" => "x",
               "description" => text
             }
    end
  end

  test "a value outside the subset rejects the skill with its line" do
    cases = [
      {" ~\n", "line 3: the description is no string"},
      {" 12\n", "line 3: the description is no string"},
      {" 0o17\n", "line 3: the description is no string"},
      {" +\n", "line 3: the description is no string"},
      {" 0x\n", "line 3: the description is no string"},
      {" 1.2.3\n", "line 3: the description is no string"},
      {" [a, b]\n", "line 3: the description is no string"},
      {"\n", "line 3: the description is no string"},
      {" # only a comment\n", "line 3: the description is no string"},
      {"\n  On the next line\n", "line 3: the description goes on to the next line"},
      {" Two\n  lines\n", "line 3: the description goes on to the next line"},
      {" x\n  \t\n", "line 4: a tab after the indentation"},
      {" 'x'\n \t# c\n", "line 4: a tab after the indentation"},
      {" 'Two\n  lines'\n",
       "line 3: the description has a quote that does not close on its line"},
      {" 'x'#c\n", "line 3: the description has text after its closing quote"},
      {" 'x' y\n", "line 3: the description has text after its closing quote"},
      {~S( "bad \q") <> "\n", "line 3: the description has an escape that YAML does not have"},
      {~S( "surrogate \ud800") <> "\n",
       "line 3: the description has an escape that YAML does not have"},
      {" a: b\n", "line 3: the description has a colon before a blank"},
      {" ends with:\n", "line 3: the description has a colon before a blank"},
      {" - a\n", "line 3: the description starts with a YAML indicator"},
      {" ? a\n", "line 3: the description starts with a YAML indicator"},
      {" @at\n", "line 3: the description starts with a YAML indicator"},
      {" :a\n", "line 3: the description starts with a YAML indicator"},
      {" `a\n", "line 3: the description starts with a YAML indicator"},
      {" %a\n", "line 3: the description starts with a YAML indicator"},
      {" ,a\n", "line 3: the description starts with a YAML indicator"},
      {" ]a\n", "line 3: the description starts with a YAML indicator"},
      {" }a\n", "line 3: the description starts with a YAML indicator"},
      {" &a x\n", "line 3: the description uses an anchor, an alias, or a tag"},
      {" *a\n", "line 3: the description uses an anchor, an alias, or a tag"},
      {" !!str x\n", "line 3: the description uses an anchor, an alias, or a tag"},
      {" |2\n   x\n", "line 3: the description has a block header that Helyx does not read"},
      {" >+\n  a\n", "line 3: the description is a folded block with keep chomping"},
      {" |\n  a\n  b\tc\n", "line 5: the description has a tab in its block"},
      {" |\n  a\n \tb\n", "line 5: a tab after the indentation"},
      {" |\n    deeper\n  shallower\n",
       "line 5: the description has a line indented less than its first line"},
      {" |\n      \n  a\n",
       "line 4: the description has a line of spaces longer than its indentation"},
      {" |\n  a\n# c\n  b\n", "line 6: an indented line with no key above it"}
    ]

    for {yaml, why} <- cases do
      assert description(yaml) == {:error, why}, yaml
    end
  end

  test "every other key is skipped with its lines, but its quotes and brackets must close" do
    yaml =
      "# a comment\nlicense: MIT\nmetadata:\n  a: &a [1, 2]\n  b: *a\n# inside\n  c: 'it''s'\n" <>
        "allowed-tools: !tag x\nname: x\nx-other: {flow: [map]}\ndescription: d\nlist:\n  - a\n" <>
        "notes: |\n  it's \"open\n_k: \"q\"\n"

    assert read(yaml) == {:ok, %{"name" => "x", "description" => "d"}}

    # The one exception to "never wider than YAML": YAML that no parser
    # reads, in the lines of another key.
    assert read("name: x\ndescription: d\nmetadata:\n  a: b: c\n  b: *none\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}

    assert read("name: x\ndescription: d\nother: a: b: c\nmore: *none\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}

    for {yaml, why} <- [
          {"other: 'x\n", "line 2: the value of other does not close on its line"},
          {"other: [a,\n  b]\n", "line 2: the value of other does not close on its line"},
          {"other:\n  k: 'x\nname: a\n",
           "line 2: a quote or a bracket in the value of other does not close"},
          {"other: 'it''s'\n  \t\n", "line 3: a tab after the indentation"},
          {"other:\n  k: x]\n",
           "line 2: a quote or a bracket in the value of other does not close"},
          {"other:\n  k: \"x\n# c\n  y\"\n",
           "line 2: a quote or a bracket in the value of other does not close"}
        ] do
      assert read(yaml) == {:error, why}, yaml
    end
  end

  test "a line outside the subset rejects the skill with its line" do
    for {yaml, why} <- [
          {"{name: x, description: d}\n", "line 2: not a key line, a comment, or a blank line"},
          {"? name\n: x\n", "line 2: not a key line, a comment, or a blank line"},
          {"- a\n", "line 2: not a key line, a comment, or a blank line"},
          {"\"name\": x\n", "line 2: not a key line, a comment, or a blank line"},
          {"name:x\n", "line 2: not a key line, a comment, or a blank line"},
          {"name:\tx\n", "line 2: not a key line, a comment, or a blank line"},
          {":k: 1\n", "line 2: not a key line, a comment, or a blank line"},
          {"-k: 1\n", "line 2: not a key line, a comment, or a blank line"},
          {"name: x\n\tb\n", "line 3: not a key line, a comment, or a blank line"},
          {"name: x\n...\n", "line 3: not a key line, a comment, or a blank line"},
          {"  indented: first\n", "line 2: an indented line with no key above it"},
          {"name: x\nname: y\n", "line 3: the key name is there twice"},
          {"description: d\ndescription: e\n", "line 3: the key description is there twice"},
          {"name: a\x01b\n", "line 2: a control character"},
          {"license: MIT\nname: a\rb\n", "line 3: a control character"},
          {"name: a\u2028b\n", "line 2: a control character"},
          {"name: a\u0085b\n", "line 2: a control character"},
          {"name: a\u2029b\n", "line 2: a control character"},
          {"name: a\uFEFFb\n", "line 2: a control character"}
        ] do
      assert read(yaml) == {:error, why}, yaml
    end

    assert read("license: MIT\n") == {:error, "the frontmatter has no name string"}
    assert read("name: x\n") == {:error, "the frontmatter has no description string"}
    assert Frontmatter.read("name: x\n") == {:error, "no frontmatter between two --- lines"}

    assert Frontmatter.read("﻿---\r\nname: x\r\ndescription: d\r\n---\r\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}

    # The frontmatter ends at its first closing line.
    assert Frontmatter.read("---\nname: x\ndescription: d\n---\nname: y\n---\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}
  end

  test "the reproductions of review round 3 are rejected" do
    for yaml <- [
          # A quoted value of another key hid a name key.
          "other: 'x\nname: a\ndescription: d #'\n",
          "other: \"x\nname: a\ndescription: d #\"\n",
          # A block of only blank lines.
          "name: x\ndescription: |\n  \n",
          "name: x\ndescription: |+\n\n",
          # ` #` in a key.
          "foo #bar: 1\nname: x\ndescription: d\n",
          # A tab after an item indicator.
          "name: x\ndescription: -\titem\n",
          "name: x\ndescription: ?\titem\n",
          # A control character, a plain value over two lines, a tab-only line in a block.
          "name: x\ndescription: a\x01b\n",
          "name: x\ndescription: text\n  more # c\n  end\n",
          "name: x\ndescription: |\n  a\n\t\n"
        ] do
      assert {:error, "line " <> _} = read(yaml), yaml
    end
  end

  test "the SKILL.md files of this repository" do
    files = Path.wildcard(Path.expand("../../../../../.claude/skills/*/SKILL.md", __DIR__))
    assert files != []

    for file <- files do
      [_, yaml] = Regex.run(~r/\A---\n(.*?\n)---\n/s, File.read!(file))
      assert %{"name" => name} = same_as_yaml(yaml)
      assert name == Path.basename(Path.dirname(file))
    end
  end

  # The proof that the reader is never wider than YAML: every frontmatter
  # that it accepts gives the name and the description that YamlElixir
  # gives. The other keys hold YAML that YamlElixir reads, or a quote or a
  # bracket that does not close, which the reader rejects.
  property "an accepted frontmatter reads as YAML reads it" do
    check all(yaml <- frontmatter(), max_runs: 3_000) do
      case read(yaml) do
        {:ok, values} -> assert {:ok, values} == yaml |> YamlElixir.read_from_string() |> take()
        {:error, "line " <> _} -> :ok
        {:error, "the frontmatter has no " <> _} -> :ok
      end
    end
  end

  @chars Enum.concat([?a..?c, ~c" \t:-'\"|>&*!#[]{}\\,@%`?.~+12é\u0301"])
  @word_chars Enum.concat([?a..?e, ~c"  \t'\"#:-.,é!&*?|>[]"])
  @tokens ~w(yes no on null Null ~ 12 0x1F 0o17 1_000 2024-01-01 1:20 .inf True +1 .5 1e3 1. + 0x 0o +0x1 1.2.3 e3 .e3)
  @escapes [
    ~S(\n),
    ~S(\t),
    ~S(\\),
    ~S(\"),
    ~S(\/),
    ~S(\x41),
    ~S(é),
    ~S(\N),
    ~S(\_),
    ~S(\q),
    ~S(\x4)
  ]
  @headers ["|", "|-", "|+", ">", ">-", "> # c", "|", ">", "|-", ">-", ">+", "|2", "|x"]
  @skipped [
    " MIT",
    " 'it''s'",
    ~S( "q\"x"),
    " [a, \"b]\", c]",
    " {k: v}",
    "\n  a: 1\n  b: [x, y]",
    "\n  - one\n  - 'two'",
    " |\n  it's \"open",
    " >-\n  text\n\n  more",
    "\n  nested: 'multi\n    line'",
    " Don't stop",
    " a # it's"
  ]
  @open [
    " 'x",
    " \"x",
    " [a,",
    "\n  'x",
    "\n  k: \"x",
    "\n  - [a,"
  ]

  defp text, do: StreamData.string(@chars, max_length: 10)

  defp words do
    StreamData.map(
      {StreamData.member_of(?a..?e), StreamData.string(@word_chars, max_length: 12)},
      fn {c, t} ->
        <<c>> <> t
      end
    )
  end

  defp value do
    StreamData.frequency([
      {5, StreamData.map(words(), &(" " <> &1))},
      {2, StreamData.map(text(), &(" " <> &1))},
      {1, StreamData.map(StreamData.member_of(@tokens), &(" " <> &1))},
      {2, StreamData.map(text(), &(" '" <> &1 <> "'"))},
      {1, StreamData.map(text(), &(" '" <> &1))},
      {2,
       StreamData.map({words(), StreamData.member_of(@escapes)}, fn {a, e} ->
         ~s( ") <> a <> e <> ~s(")
       end)},
      {4,
       StreamData.map(
         {StreamData.member_of(@headers), StreamData.list_of(block_line(), max_length: 5)},
         fn {h, lines} ->
           " " <> h <> Enum.map_join(lines, &("\n" <> &1))
         end
       )},
      {1, StreamData.map(text(), &(" x\n  " <> &1))},
      {1, StreamData.constant("")}
    ])
  end

  defp block_line do
    StreamData.frequency([
      {5, StreamData.map(words(), &("  " <> &1))},
      {2,
       StreamData.map({StreamData.integer(1..4), text()}, fn {i, t} ->
         String.duplicate(" ", i) <> t
       end)},
      {2, StreamData.member_of(["", "  ", "    ", "  \t", " \t# c"])},
      {1, StreamData.constant("# c")}
    ])
  end

  defp other do
    StreamData.frequency([
      {6,
       StreamData.map(
         {StreamData.member_of(~w(license metadata x-y)),
          StreamData.frequency([
            {6, StreamData.member_of(@skipped)},
            {1, StreamData.member_of(@open)}
          ])},
         fn {k, v} ->
           k <> ":" <> v
         end
       )},
      {3, StreamData.member_of(["# c", "", "# c", "", "  # indented", "  \t", "  \t# c"])},
      # A line that no key starts: the lines of another key are not read,
      # so a key line with any value is not a case of this property.
      {1,
       StreamData.map({StreamData.member_of(~c"-?:{[\"'@&\t"), text()}, fn {c, t} ->
         <<c>> <> t
       end)}
    ])
  end

  defp frontmatter do
    gen all(
          before <- StreamData.list_of(other(), max_length: 2),
          name <- value(),
          between <- StreamData.list_of(other(), max_length: 2),
          description <- value(),
          last <- StreamData.list_of(other(), max_length: 2),
          swap <- StreamData.boolean()
        ) do
      keys = ["name:" <> name, "description:" <> description]
      [first, second] = if swap, do: Enum.reverse(keys), else: keys
      lines = before ++ [first] ++ between ++ [second] ++ last
      Enum.join(lines, "\n") <> "\n"
    end
  end
end
