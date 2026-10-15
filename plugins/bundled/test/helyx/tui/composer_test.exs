defmodule Helyx.TUI.ComposerTest do
  # Prompt history (#469): Up and Down through `Helyx.TUI.handle_event/2`.
  # The keys need only the view model and the composer of the TUI state.
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Paste}
  alias Helyx.{Event, Message, Session}
  alias Helyx.Provider.Fake
  alias Helyx.TUI
  alias Helyx.TUI.{Composer, ViewModel}

  # A resumed session: two prompts with an answer between them.
  defp state(prompts) do
    messages =
      Enum.flat_map(prompts, &[Message.user(&1), %Message{role: :assistant, content: []}])

    vm =
      ViewModel.from_snapshot(%Session.Snapshot{
        instance_id: "i",
        seq: 1,
        messages: messages,
        turn: nil,
        model: "test/model",
        queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0}
      })

    %{vm: vm, composer: Composer.new(), scroll: nil, busy: nil}
  end

  defp press(state, code, modifiers \\ []) do
    {:noreply, state} =
      TUI.handle_event(%Key{code: code, kind: "press", modifiers: modifiers}, state)

    state
  end

  defp type(state, text), do: text |> String.graphemes() |> Enum.reduce(state, &press(&2, &1))

  defp value(state), do: ExRatatui.textarea_get_value(state.composer.input)
  defp row(state), do: elem(ExRatatui.textarea_cursor(state.composer.input), 0)

  test "Up recalls the prompts newest first, Down goes back to the draft" do
    state = state(["one", "two"]) |> type("draft")

    state = press(state, "up")
    assert value(state) == "two"
    state = press(state, "up")
    assert value(state) == "one"
    # No older prompt: the key moves the cursor, and the text stays.
    state = press(state, "up")
    assert value(state) == "one"

    state = press(state, "down")
    assert value(state) == "two"
    state = press(state, "down")
    assert value(state) == "draft"
    # The draft is not a prompt: Down only moves the cursor.
    assert value(press(state, "down")) == "draft"
  end

  # Ctrl+C shows its quit hint only when it clears nothing (#486): a draft
  # that Down can bring back counts, so Ctrl+C clears it with no hint.
  test "a composer that keeps a draft for Down has something to clear" do
    state = state(["one"])
    assert Composer.nothing_to_clear?(state.composer)

    state = state |> type("draft") |> press("up")
    ExRatatui.textarea_set_value(state.composer.input, "")
    refute Composer.nothing_to_clear?(state.composer)

    # An empty draft behind a recalled prompt leaves nothing to lose.
    state = state(["one"]) |> press("up")
    ExRatatui.textarea_set_value(state.composer.input, "")
    assert Composer.nothing_to_clear?(state.composer)
  end

  test "with no prompt, Up and Down only move the cursor" do
    state = state([]) |> type("a") |> press("j", ["ctrl"]) |> type("b")

    state = press(state, "up")
    assert {value(state), row(state)} == {"a\nb", 0}
    state = press(state, "down")
    assert {value(state), row(state)} == {"a\nb", 1}
  end

  test "Up recalls only from the first row, Down only from the last row" do
    state = state(["x\ny"]) |> type("a") |> press("j", ["ctrl"]) |> type("b")

    # On the second row, Up moves the cursor up.
    state = press(state, "up")
    assert {value(state), row(state)} == {"a\nb", 0}

    # A recalled prompt starts with the cursor on its first row.
    state = press(state, "up")
    assert {value(state), row(state)} == {"x\ny", 0}

    # Down on the first row of two moves the cursor down.
    state = press(state, "down")
    assert {value(state), row(state)} == {"x\ny", 1}

    # The draft comes back with the cursor at its end.
    state = press(state, "down")
    assert {value(state), row(state)} == {"a\nb", 1}
  end

  test "Shift+Up moves the cursor and recalls nothing" do
    state = state(["one"]) |> type("draft") |> press("up", ["shift"])
    assert value(state) == "draft"
  end

  # An edit of a recalled prompt becomes the draft (#532).
  test "Up after an edit keeps the edit as the draft, and the history does not change" do
    state = state(["one", "two"]) |> press("up") |> type("!")
    assert value(state) == "!two"

    # The edit ends the recall: Up starts again from the newest prompt.
    state = press(state, "up")
    assert value(state) == "two"
    state = press(state, "down")
    assert value(state) == "!two"
  end

  test "an edit of a recalled prompt goes after the draft, one per line" do
    state = state(["one", "two"]) |> type("draft") |> press("up") |> press("up") |> type("!")
    assert value(state) == "!one"

    # The cursor stays on the same character, so Down on the last row ends
    # the recall and shows the joined draft.
    state = press(state, "down")
    assert value(state) == "draft\n!one"
    assert ExRatatui.textarea_cursor(state.composer.input) == {1, 1}
    assert value(press(state, "down")) == "draft\n!one"

    # Up from the first row of the edit, with an older prompt to go to, ends
    # the recall, then moves the cursor into the draft.
    state = state(["one", "two"]) |> type("d") |> press("up") |> type("!") |> press("up")
    assert {value(state), row(state)} == {"d\n!two", 0}
    state = state |> press("up") |> press("down")
    assert value(state) == "d\n!two"
  end

  test "away from the edge, a key in an edited recalled prompt only moves the cursor" do
    state = state(["a\nb\nc"]) |> type("d") |> press("up") |> press("down") |> type("X")
    assert {value(state), row(state)} == {"a\nXb\nc", 1}

    state = press(state, "down")
    assert {value(state), row(state)} == {"a\nXb\nc", 2}
    assert {_at, "a\nb\nc", "d", _pastes} = state.composer.recall

    # Up off the first row also only moves the cursor.
    state = press(state, "up")
    assert {value(state), row(state)} == {"a\nXb\nc", 1}
    assert {_at, "a\nb\nc", "d", _pastes} = state.composer.recall

    # Down on the last row ends the recall with the join.
    state = state |> press("down") |> press("down")
    assert value(state) == "d\na\nXb\nc"
    assert state.composer.recall == nil
  end

  test "Up on the edited oldest prompt only moves the cursor" do
    state = state(["one", "two"]) |> type("d") |> press("up") |> press("up") |> type("X")
    state = press(state, "up")
    assert {value(state), row(state)} == {"Xone", 0}
    assert {0, "one", "d", _pastes} = state.composer.recall

    state = press(state, "down")
    assert value(state) == "d\nXone"
  end

  test "the cursor stays on the same character of a multibyte edit" do
    state = state(["hé🙂llo"]) |> type("dé🙂") |> press("up")
    state = state |> press("right") |> press("right") |> press("right") |> type("X")
    state = press(state, "down")

    assert {value(state), ExRatatui.textarea_cursor(state.composer.input)} ==
             {"dé🙂\nhé🙂Xllo", {1, 4}}

    assert value(type(state, "Y")) == "dé🙂\nhé🙂XYllo"
  end

  test "a recalled prompt that the user empties drops from the join" do
    state = state(["one", "two"]) |> type("d") |> press("up")
    state = Enum.reduce(1..3, state, fn _, state -> press(state, "delete") end)
    assert value(state) == ""
    state = press(state, "down")
    assert value(state) == "d"

    # The recall ended: Up starts again from the newest prompt.
    assert value(press(state, "up")) == "two"
  end

  test "a recalled prompt with no edit changes nothing" do
    # An edit that is undone is no edit: Up goes on to the older prompt.
    state =
      state(["one", "two"])
      |> type("draft")
      |> press("up")
      |> type("!")
      |> press("backspace")
      |> press("up")

    assert value(state) == "one"
    state = state |> press("down") |> press("down")
    assert value(state) == "draft"
  end

  test "the pastes of the draft and of the edit both expand" do
    draft = Enum.map_join(1..6, "\n", &"d#{&1}")
    edit = Enum.map_join(1..6, "\n", &"e#{&1}")
    {:noreply, state} = TUI.handle_event(%Paste{content: draft}, state(["one"]))
    state = press(state, "up")
    {:noreply, state} = TUI.handle_event(%Paste{content: edit}, state)
    state = press(state, "down")

    assert value(state) ==
             "[Pasted text #1, 6 lines]\u0001\n[Pasted text #2, 6 lines]\u0001one"

    assert Composer.submit(state.composer) == {:message, draft <> "\n" <> edit <> "one"}
  end

  test "the draft comes back with its paste" do
    paste = Enum.map_join(1..6, "\n", &"l#{&1}")
    {:noreply, state} = TUI.handle_event(%Paste{content: paste}, state(["one"]))

    state = state |> press("up") |> press("down")
    assert Composer.submit(state.composer) == {:message, paste}
  end

  test "a recalled prompt is cleaned as a paste is" do
    marker = "[Pasted text #1, 6 lines]\u0001"
    state = state(["a\rb" <> marker]) |> press("up")
    assert value(state) == "a\nb[Pasted text #1, 6 lines]"
  end

  describe "the texts that an abort gives back" do
    defp dropped(state, texts), do: deliver(state, :queue_dropped, %{texts: texts})

    defp deliver(state, type, data) do
      event = %Event{
        type: type,
        session_id: "s",
        instance_id: "i",
        turn_id: "t",
        seq: 2,
        data: data
      }

      {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
      state
    end

    test "come before the draft, in order, one per line; no other event changes the composer" do
      state = state([]) |> type("draft") |> deliver(:queue_update, %{steers: 0, follow_ups: 0})
      assert value(state) == "draft"
      state = dropped(state, ["s", "f"])
      assert value(state) == "s\nf\ndraft"
      assert ExRatatui.textarea_cursor(state.composer.input) == {2, 5}
      assert Composer.submit(state.composer) == {:message, "s\nf\ndraft"}

      assert value(dropped(state([]), ["s", "f"])) == "s\nf"
    end

    test "go before the draft and a recalled prompt, edited or not, with the pastes of both" do
      state = state(["one"]) |> type("draft") |> press("up") |> dropped(["s"])
      assert value(state) == "s\ndraft\none"
      # No draft is left behind for Down to bring back.
      assert value(press(state, "down")) == "s\ndraft\none"

      paste = Enum.map_join(1..6, "\n", &"l#{&1}")
      {:noreply, state} = TUI.handle_event(%Paste{content: paste}, state(["one"]))
      state = state |> press("up") |> type("E")
      {:noreply, state} = TUI.handle_event(%Paste{content: paste <> "!"}, state)
      state = dropped(state, ["s"])
      assert {:message, "s\n" <> rest} = Composer.submit(state.composer)
      assert rest == paste <> "\nE" <> paste <> "!one"
    end

    test "keep the draft's paste, and a text cannot forge a marker" do
      paste = Enum.map_join(1..6, "\n", &"l#{&1}")
      {:noreply, state} = TUI.handle_event(%Paste{content: paste}, state([]))
      marker = "[Pasted text #1, 6 lines]"

      state = dropped(state, ["x" <> marker <> "\u0001\r"])
      assert value(state) == "x" <> marker <> "\n\n" <> marker <> "\u0001"
      assert Composer.submit(state.composer) == {:message, "x" <> marker <> "\n\n" <> paste}
    end
  end

  test "a prompt of this session is recalled and Enter sends it again" do
    core = :"composer_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake]})
    :ok = Fake.script(core, "again", [["ok"], ["ok"]])
    {:ok, session} = Session.start(core, model: "fake/again")
    {:ok, state} = TUI.mount(session: session)

    state = state |> type("hi") |> press("enter") |> drain()
    assert value(state) == ""

    state = state |> press("up") |> press("enter") |> drain()
    assert value(state) == ""

    prompts = for %Message{role: :user} = m <- ViewModel.cells(state.vm), do: Message.text(m)
    assert prompts == ["hi", "hi"]
  end

  defp drain(state) do
    receive do
      {:helyx_event, %Event{} = event} ->
        {:noreply, state} = TUI.handle_info({:helyx_event, event}, state)
        if event.type == :turn_end, do: state, else: drain(state)
    after
      Helyx.Test.Events.wait_ms() -> flunk("no turn_end; view model: #{inspect(state.vm)}")
    end
  end
end
