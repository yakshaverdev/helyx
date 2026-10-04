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
        queue: %{steers: 0, follow_ups: 0}
      })

    %{vm: vm, composer: Composer.new(), scroll: nil}
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

  test "editing a recalled prompt does not change the history" do
    state = state(["one", "two"]) |> press("up") |> type("!")
    assert value(state) == "!two"

    state = state |> press("up") |> press("down")
    assert value(state) == "two"
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
