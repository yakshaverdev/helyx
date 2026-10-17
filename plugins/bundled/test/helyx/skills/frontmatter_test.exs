defmodule Helyx.Skills.FrontmatterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helyx.Skills.Frontmatter

  defp read(yaml), do: Frontmatter.read("---\n" <> yaml <> "---\nBody.\n")
  defp description(yaml), do: read("name: x\ndescription:" <> yaml)

  test "the scalar forms of a value" do
    cases = [
      {" Plain text\n", "Plain text"},
      {" Use when: a colon follows # a comment\n", "Use when: a colon follows"},
      {" Two\n  lines\n\n  and a paragraph\n", "Two lines\nand a paragraph"},
      {"\n  On the next line\n", "On the next line"},
      {" First\n  # a comment line\n  second\n", "First\nsecond"},
      {" # a comment\n  real text\n", "real text"},
      {"\n  # a comment\n  after the comment\n", "after the comment"},
      {" # a comment\n  |\n    literal\n", "literal\n"},
      {" 'It''s # quoted'\n", "It's # quoted"},
      {" 'Folded\n  quote'  # comment\n", "Folded quote"},
      {~S( "Tab\tquote \"x\" \\ \x41 é \U0001F600") <> "\n", "Tab\tquote \"x\" \\ A é 😀"},
      {~S( "Joined\
        line") <> "\n", "Joinedline"},
      {" \"Kept  \n\n  break\"\n", "Kept\nbreak"},
      {" \"Escaped \\\n\n  empty\"\n", "Escaped \nempty"},
      {" |\n  Line one\n    indented\n  Line two\n\n", "Line one\n  indented\nLine two\n"},
      {" |-\n  Stripped\n\n", "Stripped"},
      {" |\n  a\n      \n  \n  b\n", "a\n    \n\nb\n"},
      {" |+\n  Kept\n\n", "Kept\n\n"},
      {" >\n  Folded\n  text\n\n  Next\n    more\n  end\n", "Folded text\nNext\n  more\nend\n"},
      {" >2-\n   Indented by the indicator\n", " Indented by the indicator"},
      {" >-  # comment\n  Folded\n  stripped\n", "Folded stripped"},
      {" |+\n\n", "\n"},
      {" \u00A0text\u00A0\n", "\u00A0text\u00A0"},
      {"\n# a comment before the value\n  text\n", "text"},
      # Wider than YAML: a trailing `:`, an indicator at the start, `#`
      # right after a closing quote.
      {" ends with:\n", "ends with:"},
      {" @at `tick %pct ]x }x ,x\n", "@at `tick %pct ]x }x ,x"},
      {" 'x'#c\n", "x"}
    ]

    for {yaml, text} <- cases do
      assert description(yaml) == {:ok, %{"name" => "x", "description" => text}}, yaml
    end
  end

  test "a value that is not a string" do
    for yaml <- [
          "\n",
          " ~\n",
          " null\n",
          " true\n",
          " 12\n",
          " -1.5e3\n",
          " .inf\n",
          " 0x1F\n",
          " [a, b]\n",
          " {a: b}\n",
          "\n  - a\n",
          "\n  a: b\n",
          "\n  ? a\n",
          " # a comment\n  [a, b]\n",
          " # a comment\n  12\n",
          " # only a comment\n"
        ] do
      assert description(yaml) == {:error, "the frontmatter has no description string"}, yaml
    end
  end

  test "an anchor, an alias, or a tag in a value that Helyx reads" do
    for yaml <- [
          " &a x\n",
          " *a\n",
          " !!str x\n",
          " !tag x\n",
          "\n  *a\n",
          " # a comment\n  *a\n",
          " # a comment\n  &a text\n",
          " # a comment\n  !!binary /w==\n"
        ] do
      assert description(yaml) == {:error, "the description uses an anchor, an alias, or a tag"},
             yaml
    end
  end

  test "a broken quote, escape, or block" do
    for yaml <- [
          " 'open\n",
          " \"open\n",
          ~S( "bad \q") <> "\n",
          ~S( "half \u12") <> "\n",
          ~S( "surrogate \ud800") <> "\n",
          " 'x' trailing\n",
          " |\n    deeper\n  shallower\n",
          " |12\n  x\n",
          " |\n\tTab\n",
          " - a\n",
          " ? a\n"
        ] do
      assert description(yaml) == {:error, "the description is not valid YAML"}, yaml
    end
  end

  test "every other key is skipped with its lines, unread" do
    yaml =
      "# a comment\nlicense: MIT\nmetadata:\n  a: &a [1, 2]\n  b: *a\nallowed-tools: !tag x\n" <>
        "name: x\nx-other: {flow: [map]}\ndescription: d\nlist:\n  - a\n" <>
        "x/y: 1\nmy key: 1\n$k: 1\n\"quoted: key\": v\n'single': v\nx:y: 1\n-k: 1\n?k: 1\n"

    assert read(yaml) == {:ok, %{"name" => "x", "description" => "d"}}
    assert read("license: MIT\n") == {:error, "the frontmatter has no name string"}
  end

  test "the forms that are out: a document that is no map of plain keys, a key twice" do
    for yaml <- [
          "{name: x, description: d}\n",
          "? name\n: x\n",
          "- a\n",
          "  indented: first\n",
          "name: x\n...\n",
          "description: 'a\n# c\n  b'\nname: x\n",
          "description: a\n# c\n  b\nname: x\n"
        ] do
      assert read(yaml) == {:error, "the frontmatter is not a map of keys"}, yaml
    end

    assert read("name: x\nname: y\n") == {:error, "the frontmatter has the key name twice"}
    # A quoted key is read as its text.
    assert read(~S("n\x61me": x) <> "\n'description': d\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}

    assert read("name: x\n'name': y\n") == {:error, "the frontmatter has the key name twice"}

    assert Frontmatter.read("\uFEFF---\nname: x\ndescription: d\n---\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}

    assert Frontmatter.read("name: x\n") == {:error, "no frontmatter between two --- lines"}

    assert Frontmatter.read("---\r\nname: x\r\ndescription: d\r\n---\r\n") ==
             {:ok, %{"name" => "x", "description" => "d"}}
  end

  test "the SKILL.md files of this repository" do
    files = Path.wildcard(Path.expand("../../../../../.claude/skills/*/SKILL.md", __DIR__))
    assert files != []

    for file <- files do
      assert {:ok, %{"name" => name, "description" => description}} =
               Frontmatter.read(File.read!(file))

      assert name == Path.basename(Path.dirname(file))
      assert description != ""
    end
  end

  property "any text gives the keys or an error" do
    chars = Enum.concat([?a..?c, ~c":-'\"|>&*!#[]{}\\ \t\n12+.~"])

    check all(yaml <- StreamData.string(chars, max_length: 200), max_runs: 300) do
      assert {tag, _} = read(yaml <> "\n")
      assert tag in [:ok, :error]
    end
  end
end
