defmodule Helyx.TUI.SelectionTest do
  # The selection over a view model with no session: the TUI state is the
  # map of the three keys that `Selection.handle/3` reads. The transcript is 5
  # rows of 20 columns at column 2, as in a 24 by 9 terminal.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [with_io: 1]
  import Helyx.Test.TUIRender

  alias ExRatatui.Event.Mouse
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Block
  alias Helyx.Message
  alias Helyx.TUI.{Selection, Transcript}

  @area %Rect{x: 2, y: 0, width: 20, height: 5}

  defp state(cells), do: %{selection: nil, vm: view_model(cells), scroll: nil}

  defp assistant(text), do: %Message{role: :assistant, content: [%Message.Text{text: text}]}

  # The state after a mouse event; a copy on standard output goes to the
  # test process.
  defp mouse(state, kind, x, y, area \\ @area) do
    event = %Mouse{kind: kind, button: "left", x: x, y: y}
    {answer, written} = with_io(fn -> Selection.handle(event, state, area && [area]) end)
    if written != "", do: send(self(), {:copy, written})
    elem(answer, 1)
  end

  # A press, a drag, and a release; the copied text, or nil.
  defp drag(state, {x0, y0}, {x1, y1}, area \\ @area) do
    state =
      state
      |> mouse("down", x0, y0, area)
      |> mouse("drag", x1, y1, area)
      |> mouse("up", x1, y1, area)

    receive do
      {:copy, "\e]52;c;" <> rest} ->
        assert String.ends_with?(rest, "\a")
        {state, rest |> String.trim_trailing("\a") |> Base.decode64!()}
    after
      0 -> {state, nil}
    end
  end

  test "a drag over rows copies their text with no bar and no fill" do
    # Rows: "▌ alpha", empty, "▌ beta", empty. The drag ends on the "t".
    {_state, text} = drag(state([Message.user("alpha"), Message.user("beta")]), {2, 0}, {6, 2})
    assert text == "alpha\n\nbet"
  end

  test "a drag to the left copies the same columns, both ends included" do
    {_state, text} = drag(state([assistant("hello world")]), {6, 0}, {3, 0})
    assert text == "ello"
  end

  test "a wide glyph is in the text when one of its columns is" do
    # Columns: a 0, 世 1 and 2, b 3.
    {_state, text} = drag(state([assistant("a世b")]), {4, 0}, {5, 0})
    assert text == "世b"
  end

  test "a zero-width grapheme takes no column, as ExRatatui draws it" do
    # Columns: a 0, U+200B and b 1, c 2, d 3.
    state = state([assistant("a\u200Bbcd")])
    assert {_state, "cd"} = drag(state, {4, 0}, {5, 0})
    assert {_state, "\u200Bbc"} = drag(state, {3, 0}, {4, 0})
  end

  test "a click copies nothing, and a press outside the transcript clears the selection" do
    state = state([assistant("hello")])
    assert {_state, nil} = drag(state, {3, 0}, {3, 0})

    {selected, "hel"} = drag(state, {2, 0}, {4, 0})
    assert %Selection{} = selected.selection
    assert mouse(selected, "down", 2, 6).selection == nil
    assert mouse(selected, "down", 0, 0).selection == nil
    assert {_state, nil} = drag(state, {2, 7}, {4, 0})
  end

  test "a drag past the edges selects to the last row and column" do
    {_state, text} = drag(state([assistant("one two"), assistant("three")]), {2, 0}, {30, 8})
    assert text == "one two\n\nthree\n"
  end

  test "a selection holds its text over a scroll and reaches the scrollback" do
    # The follow view starts at the empty row after m8: m9 is on row 1 and
    # m10 on row 3. Three rows up, m7 is on row 0.
    state = state(for n <- 1..10, do: Message.user("m#{n}"))
    state = mouse(state, "down", 6, 3)
    state = %{state | scroll: Transcript.page(state.vm, nil, "scroll_up", 20, 5)}
    assert state.scroll == {6, 0}

    state |> mouse("drag", 2, 0) |> mouse("up", 2, 0)
    assert_received {:copy, "\e]52;c;" <> rest}
    assert rest |> String.trim_trailing("\a") |> Base.decode64!() == "m7\n\nm8\n\nm9\n\nm10"
  end

  test "the text is copied up to 75,000 bytes, and over that the footer says why" do
    # One row as wide as the text, selected from its first to its last column.
    copy = fn text ->
      columns = String.length(text)
      area = %Rect{@area | width: columns}

      case drag(state([assistant(text)]), {2, 0}, {columns + 1, 0}, area) do
        {state, ^text} ->
          assert state.vm.reason == nil
          :copied

        {state, nil} ->
          state.vm.reason
      end
    end

    assert copy.(String.duplicate("a", 74_999)) == :copied
    assert copy.(String.duplicate("a", 75_000)) == :copied
    assert copy.(String.duplicate("a", 75_001)) == "not copied: over 75 KB"
    assert copy.(String.duplicate("é", 37_500)) == :copied
    assert copy.(String.duplicate("é", 37_501)) == "not copied: over 75 KB"
  end

  test "with no terminal size a mouse event changes nothing" do
    state = state([assistant("hello")])
    assert mouse(state, "down", 2, 0, nil) == state
  end

  test "the selected cells get a reverse video block over the drawn text" do
    state =
      state([assistant("one two three four five six")])
      |> mouse("down", 5, 0)
      |> mouse("drag", 3, 1)

    [{_paragraph, @area} | marks] =
      widgets = Selection.widgets(state.selection, state.vm, state.scroll, @area)

    assert [{%Block{style: %{modifiers: [:reversed]}}, first}, {%Block{}, second}] = marks
    assert first == %Rect{x: 5, y: 0, width: 17, height: 1}
    assert second == %Rect{x: 2, y: 1, width: 2, height: 1}

    terminal = ExRatatui.init_test_terminal(24, 5)
    :ok = ExRatatui.draw(terminal, widgets)
    assert ExRatatui.get_buffer_content(terminal) =~ "one two three four"
  end
end
