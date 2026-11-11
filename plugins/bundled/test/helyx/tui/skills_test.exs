defmodule Helyx.TUI.SkillsTest do
  # The skills in the TUI: the scan notices at mount, the rule of a command
  # name with no separator after it, and the call line of a load. The server
  # expands a `/name args` message (docs/features/skills.md).
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Paste}
  alias Helyx.{Event, Message}
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

  test "mount shows the notices of the caller after those of the scan", %{tmp_dir: dir} do
    core = :"tui_notices_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]}, id: core)
    {:ok, session} = Helyx.Session.start(core, model: "fake/skills", cwd: dir)

    {:ok, state} =
      TUI.mount(
        session: Helyx.Test.TUIWire.link(session),
        cwd: dir,
        notices: ["no log file for this run"],
        terminal_size_fn: fn -> {:error, :no_tty} end
      )

    notices = for {:notice, text} <- ViewModel.cells(state.vm), do: text
    assert List.last(notices) == "no log file for this run"
    assert Enum.count(notices, &(&1 == "no log file for this run")) == 1
  end

  test "/name args is sent as typed, and the server expands it", %{state: state} do
    {:noreply, state} = TUI.handle_event(%Paste{content: "/#{@name} 730"}, state)

    {:noreply, state} =
      TUI.handle_event(%Key{code: "enter", kind: "press", modifiers: []}, state)

    assert ExRatatui.textarea_get_value(state.composer.input) == ""

    assert_receive {:helyx_event, _sub,
                    %Event{type: :message_end, data: %{message: %Message{role: :user} = user}}},
                   5_000

    assert Message.text(user) == "/#{@name} 730"
  end

  test "a command name with no separator after it is a message as typed" do
    assert Command.parse("/model") == {:model, ""}
    assert Command.parse("/model a/b") == {:model, "a/b"}
    assert Command.parse("/new") == {:new, ""}
    assert Command.parse("/new x") == {:usage, :new}
    assert Command.parse("/models") == {:message, "/models"}
    assert Command.parse("/models x") == {:message, "/models x"}
    assert Command.parse("/newsletter") == {:message, "/newsletter"}
    assert Command.parse("hello") == {:message, "hello"}
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
