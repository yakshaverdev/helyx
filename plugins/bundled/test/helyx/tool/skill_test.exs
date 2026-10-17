defmodule Helyx.Tool.SkillTest do
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [wait_ms: 0]

  alias Helyx.Message
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Skills
  alias Helyx.Test.ToolRunner

  @moduletag :tmp_dir

  # A name that no home folder of a test machine holds.
  @name "probe-skill-471"

  setup %{tmp_dir: dir} do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.Skill]})
    File.mkdir_p!(Path.join(dir, ".git"))
    folder = Path.join(dir, ".agents/skills/#{@name}")
    File.mkdir_p!(folder)

    File.write!(
      Path.join(folder, "SKILL.md"),
      "---\nname: #{@name}\ndescription: Probe.\n---\nDo it.\n"
    )

    [skill] = Enum.filter(Skills.scan(dir, System.user_home!()).skills, &(&1.name == @name))
    %{core: core, skill: skill}
  end

  defp call(args),
    do: %ToolCall{id: "c#{System.unique_integer([:positive])}", name: "skill", arguments: args}

  # Runs `responses` in one turn of a new session after `prompt`, and gives
  # the tool result messages in order.
  defp results(core, dir, prompt, responses) do
    model = "skill_#{System.unique_integer([:positive])}"
    :ok = Fake.script(core, model, responses ++ [["Done."]])
    {:ok, session} = Helyx.Session.start(core, model: "fake/#{model}", cwd: dir)
    {:ok, _, _} = Helyx.Session.subscribe(session)
    :ok = Helyx.Session.prompt(session, prompt)
    for _ <- responses, do: result()
  end

  defp result do
    assert_receive {:helyx_event,
                    %Helyx.Event{type: :tool_execution_end, data: %{message: message}}},
                   wait_ms()

    message
  end

  test "a first load gives the load text, a second load in the session gives the note", %{
    core: core,
    tmp_dir: dir,
    skill: skill
  } do
    [first, second] =
      results(core, dir, "go", [[call(%{"name" => @name})], [call(%{"name" => @name})]])

    refute first.is_error
    assert Message.text(first) == Skills.text(skill)
    refute second.is_error
    assert Message.text(second) == Skills.note(skill)
    assert Message.text(second) =~ Path.join(skill.folder, "SKILL.md")
  end

  test "a user command counts as a load", %{core: core, tmp_dir: dir, skill: skill} do
    prompt = Skills.expand("/#{@name} 730", dir, System.user_home!())
    [result] = results(core, dir, prompt, [[call(%{"name" => @name})]])
    assert Message.text(result) == Skills.note(skill)
  end

  test "an unknown name and a missing name are errors", %{core: core, tmp_dir: dir} do
    long = String.duplicate("x", 1_000)

    unknown = ToolRunner.run_tool(core, call(%{"name" => long}), dir)
    assert unknown.is_error

    assert Message.text(unknown) ==
             "unknown skill: #{String.duplicate("x", 64)}; the skills are listed in the system prompt"

    # 64 bytes echo whole; 65 bytes, and 68 bytes of 4-byte characters, are
    # cut to 64.
    for {name, echo} <- [
          {String.duplicate("x", 64), String.duplicate("x", 64)},
          {String.duplicate("x", 65), String.duplicate("x", 64)},
          {String.duplicate("😀", 17), String.duplicate("😀", 16)}
        ] do
      result = ToolRunner.run_tool(core, call(%{"name" => name}), dir)
      assert Message.text(result) =~ "unknown skill: #{echo};"
    end

    for args <- [%{}, %{"name" => 1}] do
      result = ToolRunner.run_tool(core, call(args), dir)
      assert result.is_error
      assert Message.text(result) == "skill needs a name"
    end
  end

  # docs/features/skills.md, decision 9: a child of the agent tool has the
  # skill tool, and its transcript is its own.
  test "a child session loads a skill with the full text after its parent loaded it", %{
    tmp_dir: dir,
    skill: skill
  } do
    core = :"core_#{System.unique_integer([:positive])}"
    sessions = Path.join(dir, "sessions")

    start_supervised!(
      {Helyx.Core,
       name: core, plugins: [Fake, Helyx.Tool.Agent, Helyx.Tool.Skill], sessions_dir: sessions},
      id: core
    )

    agent = %ToolCall{
      id: "a1",
      name: "agent",
      arguments: %{"description" => "a task", "prompt" => "load it"}
    }

    # The parent and the child share the script of the model, in the order
    # of the calls: the parent loads, starts the child, the child loads.
    model = "skill_#{System.unique_integer([:positive])}"

    :ok =
      Fake.script(core, model, [
        [call(%{"name" => @name})],
        [agent],
        [call(%{"name" => @name})],
        ["child answer"],
        ["Done."]
      ])

    {:ok, session} = Helyx.Session.start(core, model: "fake/#{model}", cwd: dir)
    {:ok, _, _} = Helyx.Session.subscribe(session)
    :ok = Helyx.Session.prompt(session, "go")

    assert Message.text(result()) == Skills.text(skill)
    assert Message.text(result()) == "child answer"

    {:ok, path, _header} =
      Helyx.Session.File.Scan.find(sessions, Helyx.Sessions.child_id(session.id, "a1"))

    child = File.read!(path)
    assert child =~ "Do it."
    refute child =~ "is already loaded"
  end
end
