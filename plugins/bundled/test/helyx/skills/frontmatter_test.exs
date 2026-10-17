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

  test "every other key is skipped with its lines, but a YAML construct at a word start is out" do
    yaml =
      "# a comment\nlicense: MIT\nmetadata:\n  a: 1\n  b: it's\n# inside\n  c: x\n\n" <>
        "allowed-tools: Bash(git:*) Read\nname: x\nx-other: a\"b, c[d], e{f}, g|h>i\n" <>
        "description: d\nlist:\n  - a\n  - don't\n_k: 50% a@b x`c` x!y x&y x?y\n"

    assert read(yaml) == {:ok, %{"name" => "x", "description" => "d"}}

    # The one exception to "never wider than YAML": YAML that no parser
    # reads, in the lines of another key.
    assert read("name: x\ndescription: d\nmetadata:\n  a: b: c\nother: a: b: c\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}

    # A comment at column 0 is no line of another key.
    assert read("name: x\ndescription: d\nother: a\n# the \"x\" key\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}

    for {line, char} <- [
          {"other: 'x'", "'"},
          {~s(other: "x"), ~s(")},
          {"other: [a, b]", "["},
          {"other: x ]", "]"},
          {"other: {k: v}", "{"},
          {"other: x }", "}"},
          {"other: !tag x", "!"},
          {"other: &a x", "&"},
          {"other: *a", "*"},
          {"other: |", "|"},
          {"other: >-", ">"},
          {"other: ? x", "?"},
          {"other: @x", "@"},
          {"other: `x`", "`"},
          {"other: %x", "%"},
          {"other: a\t'b", "'"},
          {"other:\n  - 'x'", "'"},
          {~s(other:\n  - "x"), ~s(")},
          {~s(other:\n  version: "1.0"), ~s(")},
          {~s(other: a # the "x" key), ~s(")},
          {"other:\n  k: [a]", "["},
          {"other:\n  # a 'c'", "'"},
          {"other:\n  |x", "|"}
        ] do
      n = if String.contains?(line, "\n"), do: 3, else: 2

      assert read(line <> "\n") ==
               {:error, "line #{n}: the value of other has #{char} at the start of a word"},
             line
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

  test "the reproductions of earlier review rounds are rejected" do
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
          "name: x\ndescription: |\n  a\n\t\n",
          # Findings 39 to 41 of the third run: the quote scan of another key
          # took a quote that YAML opens for text, or the reverse.
          "other: !<tag:yaml.org,2002:str>\"\nname: x\ndescription: d #\"\n",
          "other: [a:\"b, \"c]\nname: evil\ndescription: d\nz: |\n  x\"]\n",
          "other: [a:'b, 'c]\nname: evil\ndescription: d\nz: |\n  x']\n",
          "other: {k: a:\"b, j: \"c}\nname: evil\ndescription: d\nz: |\n  x\"}\n",
          "other:\n  k: |\n    'x\n  j: 'y\nname: evil\ndescription: d\nz: |\n  w'\n"
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
  # gives. The one exception: YamlElixir rejects the value of another key.
  # Then the same frontmatter with `o<n>: x` for each other key must give
  # them, so the rejection comes from another key.
  property "an accepted frontmatter reads as YAML reads it" do
    check all({yaml, plain} <- frontmatter(), max_runs: 6_000) do
      case read(yaml) do
        {:ok, values} ->
          case YamlElixir.read_from_string(yaml) do
            {:error, _} ->
              assert {:ok, values} == plain |> YamlElixir.read_from_string() |> take()

            yaml_values ->
              assert {:ok, values} == take(yaml_values)
          end

        {:error, "line " <> _} ->
          :ok

        {:error, "the frontmatter has no " <> _} ->
          :ok
      end
    end
  end

  @chars Enum.concat([?a..?c, ~c" \t:-'\"|>&*!#[]{}\\,@%`?.~+12é\u0301"])
  @word_chars Enum.concat([?a..?e, ~c"  \t'\"#:-.,é!&*?|>[]{}@`%"])
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
  # Values of another key in plain words over more than one line.
  @skipped [
    " MIT",
    " Don't stop",
    " a # it's",
    "
  a: 1
  b: x y",
    "
  - one
  - two's",
    "
  # a comment

  c: d"
  ]
  @starts ~c"\"'[]{}!&*|>?@`%"

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

  # A word of another key: a construct character inside a word, which is
  # text, or at its start, which rejects the skill.
  defp other_word do
    StreamData.frequency([
      {20, words()},
      {1, StreamData.map({StreamData.member_of(@starts), text()}, fn {c, t} -> <<c>> <> t end)}
    ])
  end

  defp other_words do
    StreamData.map(
      {StreamData.list_of(other_word(), min_length: 1, max_length: 3),
       StreamData.member_of([" ", "  ", "\t"])},
      fn {words, blank} -> Enum.join(words, blank) end
    )
  end

  defp other_value do
    StreamData.frequency([
      {6, StreamData.map(other_words(), &(" " <> &1))},
      {2, StreamData.map(other_words(), &("\n  k: " <> &1))},
      {1, StreamData.map(other_words(), &("\n  - " <> &1))},
      {2, StreamData.member_of(@skipped)}
    ])
  end

  defp other do
    StreamData.frequency([
      {6,
       StreamData.map(
         {StreamData.member_of(~w(license metadata x-y)), other_value()},
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

      plain =
        lines
        |> Enum.with_index()
        |> Enum.map(fn {line, i} ->
          if Regex.match?(~r/\A[a-z-]+:/, line) and line not in keys, do: "o#{i}: x", else: line
        end)

      {Enum.join(lines, "\n") <> "\n", Enum.join(plain, "\n") <> "\n"}
    end
  end
end
