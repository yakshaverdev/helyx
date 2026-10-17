defmodule Helyx.SkillsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helyx.Message
  alias Helyx.Skills

  @moduletag :tmp_dir

  # A repository with a git root, a working directory below it, and a home
  # folder outside it.
  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    cwd = Path.join(repo, "sub")
    home = Path.join(dir, "home")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.mkdir_p!(cwd)
    File.mkdir_p!(home)
    %{repo: repo, cwd: cwd, home: home}
  end

  defp skill(root, name, frontmatter \\ nil, body \\ "Body.\n") do
    dir = Path.join([root, ".agents/skills", name])
    File.mkdir_p!(dir)
    frontmatter = frontmatter || "name: #{name}\ndescription: Does #{name}.\n"
    File.write!(Path.join(dir, "SKILL.md"), "---\n#{frontmatter}---\n#{body}")
    dir
  end

  defp names(scan), do: Enum.map(scan.skills, & &1.name)

  test "the folders from cwd up to the git root come nearest first, then the user folder", %{
    tmp_dir: dir,
    repo: repo,
    cwd: cwd,
    home: home
  } do
    skill(cwd, "near")
    skill(repo, "far")
    skill(home, "mine")
    # Above the git root: not read.
    skill(dir, "above")

    scan = Skills.scan(cwd, home)
    assert names(scan) == ["near", "far", "mine"]
    assert scan.notices == []

    assert scan.catalog ==
             "## Skills\n\nEach skill below is a folder of instructions for one kind of task. " <>
               "When a task matches a skill, load it with the skill tool before you start, " <>
               "and follow it.\n\n- near: Does near.\n- far: Does far.\n- mine: Does mine."
  end

  test "a worktree, whose .git is a file, is a git root", %{repo: repo, home: home} do
    tree = Path.join(repo, "tree")
    File.mkdir_p!(tree)
    File.write!(Path.join(tree, ".git"), "gitdir: elsewhere\n")
    skill(repo, "outer")
    skill(tree, "inner")
    assert names(Skills.scan(tree, home)) == ["inner"]
  end

  test "with no git root the walk goes up to / and the home folder loads once, as the user folder",
       %{tmp_dir: dir} do
    home = Path.join(dir, "plain")
    cwd = Path.join(home, "work")
    File.mkdir_p!(cwd)
    skill(home, "mine")
    skill(cwd, "near")
    assert names(Skills.scan(cwd, home)) == ["near", "mine"]
  end

  test "a project folder above the home folder wins over the user folder", %{tmp_dir: dir} do
    home = Path.join(dir, "plain")
    cwd = Path.join(home, "work")
    File.mkdir_p!(cwd)
    above = skill(dir, "ship")
    mine = skill(home, "ship")

    scan = Skills.scan(cwd, home)
    assert [%{folder: ^above}] = scan.skills
    assert scan.notices == ["skill #{mine} is hidden by #{above}"]
  end

  test "the nearer skill hides a farther one and the user one, one notice each", %{
    repo: repo,
    cwd: cwd,
    home: home
  } do
    near = skill(cwd, "ship")
    far = skill(repo, "ship")
    mine = skill(home, "ship")

    scan = Skills.scan(cwd, home)
    assert [%{folder: ^near}] = scan.skills

    assert scan.notices == [
             "skill #{far} is hidden by #{near}",
             "skill #{mine} is hidden by #{near}"
           ]
  end

  test "a notice line has at most 1,024 bytes, cut on a character boundary", %{
    repo: repo,
    home: home
  } do
    deep = Path.join([repo | List.duplicate(String.duplicate("é", 60), 6)])
    near = skill(deep, "ship")
    far = skill(repo, "ship")
    [notice] = Skills.scan(deep, home).notices

    assert byte_size("skill #{far} is hidden by #{near}") > 1_024
    assert byte_size(notice) <= 1_024 and String.valid?(notice)
    assert String.starts_with?("skill #{far} is hidden by #{near}", notice)
  end

  test "a broken skill is dropped with a notice and does not hide a farther one", %{
    cwd: cwd,
    home: home
  } do
    broken = skill(cwd, "ship", "name: ship\n")
    mine = skill(home, "ship")
    skill(cwd, "other")

    scan = Skills.scan(cwd, home)

    assert Enum.map(scan.skills, &{&1.name, &1.folder}) == [
             {"other", Path.join(cwd, ".agents/skills/other")},
             {"ship", mine}
           ]

    assert scan.notices == [
             "skill #{broken} is not loaded: the frontmatter has no description string"
           ]
  end

  test "each rule of the frontmatter drops the skill with its reason", %{cwd: cwd, home: home} do
    cases = [
      {"a", "description: x\n", "the frontmatter has no name string"},
      {"b", "name: 12\ndescription: x\n", "line 2: the name is no string"},
      {"c", "name: other\ndescription: x\n", "the name other is not the folder name"},
      {"d-", "name: d-\ndescription: x\n", "the name must be"},
      {"-e", "name: -e\ndescription: x\n", "line 2: the name starts with a YAML indicator"},
      {"f--g", "name: f--g\ndescription: x\n", "the name must be"},
      {"Hh", "name: Hh\ndescription: x\n", "the name must be"},
      {"i", "name: i\ndescription: \"\"\n", "the frontmatter has no description string"},
      {"j", "name: j\ndescription: \"x\n",
       "line 3: the description has a quote that does not close on its line"},
      {"k", "- a list\n", "line 2: not a key line, a comment, or a blank line"}
    ]

    for {name, frontmatter, _} <- cases, do: skill(cwd, name, frontmatter)
    nofm = Path.join(cwd, ".agents/skills/l")
    File.mkdir_p!(nofm)
    File.write!(Path.join(nofm, "SKILL.md"), "name: l\n")

    scan = Skills.scan(cwd, home)
    assert scan.skills == []
    # The notices follow the sorted folder names.
    expected =
      for {name, _, why} <-
            Enum.sort(cases ++ [{"l", nil, "no frontmatter between two --- lines"}]),
          do: {Path.join(cwd, ".agents/skills/#{name}"), why}

    assert length(scan.notices) == length(expected)

    for {notice, {dir, why}} <- Enum.zip(scan.notices, expected) do
      assert String.starts_with?(notice, "skill #{dir} is not loaded: #{why}"), notice
    end
  end

  test "other keys are ignored and a folded description is read as YAML", %{cwd: cwd, home: home} do
    skill(
      cwd,
      "ok",
      "name: ok\ndescription: >\n  Folded: with a colon\n  on two lines\nlicense: MIT\n" <>
        "metadata:\n  version: \"1\"\nallowed-tools:\n  - Read\nwhen_to_use: x\n"
    )

    assert [%{description: "Folded: with a colon on two lines\n"}] = Skills.scan(cwd, home).skills

    assert String.ends_with?(
             Skills.scan(cwd, home).catalog,
             "\n- ok: Folded: with a colon on two lines "
           )
  end

  test "an anchor, an alias, or a tag drops the skill; in another key it is not read", %{
    cwd: cwd,
    home: home
  } do
    # Each level repeats the one before ten times: 10^8 strings to a full
    # YAML parser, skipped lines to the reader.
    bomb =
      Enum.map_join(1..8, "", fn level ->
        "l#{level}: &l#{level}\n" <> String.duplicate("  - *l#{level - 1}\n", 10)
      end)

    deep = String.duplicate("[", 30_000) <> String.duplicate("]", 30_000)
    skill(cwd, "bomb", "name: bomb\ndescription: x\nl0: &l0 [x]\n" <> bomb <> "x: #{deep}\n")
    skill(cwd, "raw", "name: raw\ndescription: !!binary /w==\n")
    skill(cwd, "anchor", "name: &a anchor\ndescription: x\n")
    skill(cwd, "alias", "a: &a x\nname: alias\ndescription: *a\n")

    scan = Skills.scan(cwd, home)
    assert names(scan) == ["bomb"]
    dir = &Path.join(cwd, ".agents/skills/#{&1}")

    assert scan.notices == [
             "skill #{dir.("alias")} is not loaded: line 4: the description uses an anchor, an alias, or a tag",
             "skill #{dir.("anchor")} is not loaded: line 2: the name uses an anchor, an alias, or a tag",
             "skill #{dir.("raw")} is not loaded: line 3: the description uses an anchor, an alias, or a tag"
           ]
  end

  property "a scan of any frontmatter gives skills or notices", %{cwd: cwd, home: home} do
    chars = Enum.concat([?a..?c, ~c":-'\"|>&*!#[]{}\\ \t\n12+"])

    check all(yaml <- StreamData.string(chars, max_length: 120), max_runs: 100) do
      skill(cwd, "gen", "name: gen\ndescription: " <> yaml <> "\n")
      %{skills: skills, notices: notices} = Skills.scan(cwd, home)
      assert length(skills) + length(notices) == 1
    end
  end

  test "a name of 64 characters loads and one of 65 does not", %{cwd: cwd, home: home} do
    long = String.duplicate("a", 64)
    longer = String.duplicate("b", 65)
    skill(cwd, long)
    skill(cwd, longer)
    scan = Skills.scan(cwd, home)
    assert names(scan) == [long]
    assert [notice] = scan.notices
    assert notice =~ "the name must be 1 to 64"
  end

  test "a description of 1,024 characters loads and one of 1,025 does not, in code points", %{
    cwd: cwd,
    home: home
  } do
    skill(cwd, "a", "name: a\ndescription: #{String.duplicate("é", 1024)}\n")
    skill(cwd, "b", "name: b\ndescription: #{String.duplicate("é", 1025)}\n")
    scan = Skills.scan(cwd, home)
    assert names(scan) == ["a"]
    assert [notice] = scan.notices
    assert notice =~ "the description is over 1024 characters"
  end

  test "a SKILL.md of 65,536 bytes loads and one of 65,537 does not", %{cwd: cwd, home: home} do
    head = "---\nname: a\ndescription: x\n---\n"
    a = skill(cwd, "a")

    File.write!(
      Path.join(a, "SKILL.md"),
      head <> "x" <> String.duplicate("é", div(65_536 - byte_size(head), 2))
    )

    assert File.stat!(Path.join(a, "SKILL.md")).size == 65_536
    b = skill(cwd, "b", "name: b\ndescription: x\n")

    File.write!(
      Path.join(b, "SKILL.md"),
      String.replace(head, "a", "b") <> String.duplicate("x", 65_537 - byte_size(head))
    )

    scan = Skills.scan(cwd, home)
    assert names(scan) == ["a"]
    assert scan.notices == ["skill #{b} is not loaded: SKILL.md is over 65536 bytes"]
  end

  test "a SKILL.md that is a folder, not UTF-8, or a dangling symlink is dropped", %{
    cwd: cwd,
    home: home
  } do
    root = Path.join(cwd, ".agents/skills")
    File.mkdir_p!(Path.join([root, "a", "SKILL.md"]))
    File.mkdir_p!(Path.join(root, "b"))

    File.write!(
      Path.join([root, "b", "SKILL.md"]),
      <<"---\nname: b\ndescription: ", 0xFF, "\n---\n">>
    )

    File.mkdir_p!(Path.join(root, "c"))
    File.ln_s!(Path.join(root, "missing"), Path.join([root, "c", "SKILL.md"]))
    # A plain file and a folder with no SKILL.md are no skills.
    File.write!(Path.join(root, "README"), "x")
    File.mkdir_p!(Path.join(root, "d"))

    scan = Skills.scan(cwd, home)
    assert scan.skills == []
    assert [a, b] = scan.notices
    assert a == "skill #{root}/a is not loaded: SKILL.md is not a regular file"
    assert b =~ "skill #{root}/b is not loaded: "
  end

  test "a symlinked skill folder is followed, and a folder reached twice loads once", %{
    tmp_dir: dir,
    repo: repo,
    cwd: cwd,
    home: home
  } do
    target = skill(Path.join(dir, "store"), "linked")
    File.mkdir_p!(Path.join(cwd, ".agents/skills"))
    File.ln_s!(target, Path.join(cwd, ".agents/skills/linked"))
    # The repo's skills folder is the same folder as the user's.
    skill(home, "mine")
    File.mkdir_p!(Path.join(repo, ".agents"))
    File.ln_s!(Path.join(home, ".agents/skills"), Path.join(repo, ".agents/skills"))

    scan = Skills.scan(cwd, home)
    assert names(scan) == ["linked", "mine"]
    assert scan.notices == []
  end

  test "200 skill folders are read, and the rest give one notice, user folders first out", %{
    cwd: cwd,
    home: home
  } do
    for i <- 1..199, do: skill(cwd, "p#{String.pad_leading("#{i}", 3, "0")}", "name: x\n")
    skill(cwd, "z-last")
    skill(home, "mine")
    skill(home, "more")

    scan = Skills.scan(cwd, home)
    assert names(scan) == ["z-last"]
    assert length(scan.notices) == 200
    assert List.last(scan.notices) == "2 more skill folders were not read: at most 200"

    # 201 folders, then 200.
    File.rm_rf!(Path.join(home, ".agents/skills/more"))

    assert List.last(Skills.scan(cwd, home).notices) ==
             "1 more skill folders were not read: at most 200"

    File.rm_rf!(Path.join(home, ".agents/skills/mine"))
    assert length(Skills.scan(cwd, home).notices) == 199
  end

  test "the catalog holds at most 16,384 bytes; the rest is left out with one notice", %{
    tmp_dir: dir,
    cwd: cwd,
    home: home
  } do
    # The bytes of the section before its first line, from a repo of one skill.
    other = Path.join(dir, "other")
    File.mkdir_p!(Path.join(other, ".git"))
    skill(other, "x")
    budget = 16_384 - (byte_size(Skills.scan(other, home).catalog) - byte_size("\n- x: Does x."))

    # Each line is "\n- sNN: " (8 bytes) and its description of at most
    # 1,024 characters, so four-byte characters fill the cap in four lines:
    # three of 1,010 characters, and a fourth that fills the cap exactly. A
    # fifth skill is left out.
    desc = fn bytes ->
      String.duplicate("😀", div(bytes, 4)) <> String.duplicate("a", rem(bytes, 4))
    end

    last = budget - 4 * 8 - 3 * 4_040
    for i <- 1..3, do: skill(cwd, "s0#{i}", "name: s0#{i}\ndescription: #{desc.(4_040)}\n")
    skill(cwd, "s04", "name: s04\ndescription: #{desc.(last)}\n")
    skill(cwd, "s05", "name: s05\ndescription: c\n")

    scan = Skills.scan(cwd, home)
    assert names(scan) == ["s01", "s02", "s03", "s04"]
    assert byte_size(scan.catalog) == 16_384
    assert scan.notices == ["1 skills were left out: the skill list has at most 16384 bytes"]

    # One byte more, and the fourth skill is out too.
    skill(cwd, "s04", "name: s04\ndescription: #{desc.(last + 1)}\n")
    assert names(Skills.scan(cwd, home)) == ["s01", "s02", "s03"]
  end

  test "the load text holds the header, the folder, and the file; a long file is cut", %{
    cwd: cwd,
    home: home
  } do
    dir = skill(cwd, "ship", nil, Enum.map_join(1..2500, "\n", &"line #{&1}"))
    [skill] = Skills.scan(cwd, home).skills
    text = Skills.text(skill)

    assert String.starts_with?(
             text,
             "<skill name=\"ship\">\nFolder: #{dir} (relative paths in this skill resolve against it)\n\n---\nname: ship\n"
           )

    assert text =~ "[truncated: showing lines 1-2000 of 2504; read again with offset 2001]"
    assert String.ends_with?(text, "\n</skill>")
    assert byte_size(text) < Message.max_result_bytes()

    # The folder line holds at most 4,096 bytes, cut on a character.
    for {folder, shown} <- [{2_048, 2_048}, {2_049, 2_048}] do
      text = Skills.text(%{skill | folder: String.duplicate("é", folder)})
      assert text =~ "\nFolder: #{String.duplicate("é", shown)} (relative paths"
    end
  end

  test "the load text of a 64 KiB file of 4-byte characters fits a tool result", %{
    cwd: cwd,
    home: home
  } do
    head = "---\nname: a\ndescription: x\n---\n"
    a = skill(cwd, "a")

    File.write!(
      Path.join(a, "SKILL.md"),
      head <> String.duplicate("😀", div(65_536 - byte_size(head), 4))
    )

    [skill] = Skills.scan(cwd, home).skills
    assert byte_size(Skills.text(skill)) <= Message.max_result_bytes()
  end

  test "loaded? reads user messages and good results of the skill tool only", %{
    cwd: cwd,
    home: home
  } do
    skill(cwd, "ship")
    [skill] = Skills.scan(cwd, home).skills
    text = Skills.text(skill)
    call = %Message.ToolCall{id: "c", name: "skill", arguments: %{}}

    assert Skills.loaded?([Message.user(text)], "ship")
    assert Skills.loaded?([Message.tool_result(call, {:ok, text})], "ship")
    refute Skills.loaded?([Message.tool_result(call, {:error, text})], "ship")
    refute Skills.loaded?([Message.tool_result(%{call | name: "read"}, {:ok, text})], "ship")
    refute Skills.loaded?([Message.user(text)], "shi")
    refute Skills.loaded?([Message.user("x" <> text)], "ship")
    refute Skills.loaded?([], "ship")
  end

  test "expand gives the load text and the arguments of a known skill, else nil", %{
    cwd: cwd,
    home: home
  } do
    skill(cwd, "implement")
    [skill] = Skills.scan(cwd, home).skills

    assert Skills.expand("/implement 730", cwd, home) == Skills.text(skill) <> "\n\n730"

    assert Skills.expand("  /implement\n\n730 and more\n", cwd, home) ==
             Skills.text(skill) <> "\n\n730 and more"

    assert Skills.expand("/implement", cwd, home) == Skills.text(skill)
    assert Skills.expand("/implement   ", cwd, home) == Skills.text(skill)
    assert Skills.expand("/implements 1", cwd, home) == nil
    assert Skills.expand("/other", cwd, home) == nil
    assert Skills.expand("implement", cwd, home) == nil
    assert Skills.expand("say /implement", cwd, home) == nil
  end
end
