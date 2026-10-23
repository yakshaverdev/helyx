defmodule Helyx.TUI.SkillsTest do
  # The skills in the TUI: the scan notices at mount, the `/name` command,
  # the rule of a command over a skill, and the call line of a load.
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Paste}
  alias Helyx.{Event, Message, Skills}
  alias Helyx.Provider.Fake
  alias Helyx.TUI
  alias Helyx.TUI.{CallLine, Command, ViewModel}

  @moduletag :tmp_dir

  # A name that no home folder of a test machine holds.
  @name "probe-skill-471"

  setup %{tmp_dir: dir} do
    core = :"tui_skills_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]})
    File.mkdir_p!(Path.join(dir, ".git"))

    for {name, frontmatter} <- [
          {@name, "name: #{@name}\ndescription: Probe.\n"},
          {"probe-bad-471", "name: probe-bad-471\n"}
        ] do
      folder = Path.join(dir, ".agents/skills/#{name}")
      File.mkdir_p!(folder)
      File.write!(Path.join(folder, "SKILL.md"), "---\n#{frontmatter}---\nDo it.\n")
    end

    :ok = Fake.script(core, "skills", [["ok"]])
    {:ok, session} = Helyx.Session.start(core, model: "fake/skills", cwd: dir)

    {:ok, state} =
      TUI.mount(
        session: Helyx.Test.TUIWire.link(session),
        cwd: dir,
        terminal_size_fn: fn -> {:error, :no_tty} end
      )

    %{state: state}
  end

  test "mount shows the notice of a broken skill", %{state: state, tmp_dir: dir} do
    bad = Path.join(dir, ".agents/skills/probe-bad-471")

    notice = "skill #{bad} is not loaded: the frontmatter has no description string"
    assert {:notice, notice} in ViewModel.cells(state.vm)
  end

  test "/name args sends the load text and the arguments", %{state: state, tmp_dir: dir} do
    {:noreply, state} = TUI.handle_event(%Paste{content: "/#{@name} 730"}, state)

    {:noreply, _state} =
      TUI.handle_event(%Key{code: "enter", kind: "press", modifiers: []}, state)

    [skill] = Enum.filter(Skills.scan(dir, System.user_home!()).skills, &(&1.name == @name))
    expected = Skills.text(skill) <> "\n\n730"

    assert_receive {:helyx_event,
                    %Event{type: :message_end, data: %{message: %Message{role: :user} = user}}},
                   5_000

    assert Message.text(user) == expected
  end

  test "a command wins over a skill of its name; a longer word is the skill" do
    expand = fn
      "/model" -> "skill model"
      "/models x" -> "skill models"
      "/" <> _ -> nil
    end

    assert Command.parse("/model", expand) == {:model, ""}
    assert Command.parse("/model a/b", expand) == {:model, "a/b"}
    assert Command.parse("/models x", expand) == {:message, "skill models"}
    assert Command.parse("/newer", expand) == {:usage, :new}
    assert Command.parse("/other", expand) == {:message, "/other"}
    assert Command.parse("hello", fn _ -> nil end) == {:message, "hello"}
  end

  test "a call of the skill tool shows as skill: name" do
    call = %Message.ToolCall{id: "c", name: "skill", arguments: %{"name" => "ship\nx"}}
    assert CallLine.line(call) == "⚙ skill: ship␤x"

    other = %Message.ToolCall{id: "c", name: "skill", arguments: %{"name" => 1}}
    assert CallLine.line(other) == "⚙ skill name=1"
    # The cut of every call line (`@render_max_bytes`).
    long = CallLine.line(%{call | arguments: %{"name" => String.duplicate("é\n", 5_000)}})
    assert byte_size(long) <= 8_192
  end
end
