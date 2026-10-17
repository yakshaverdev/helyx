defmodule Helyx.TUI.SearchTest do
  # The search over a view model with no session: the TUI state is the map
  # of the keys that `Search.handle/3` reads. The transcript is 5 rows of 20
  # columns at column 2, as in a 24 by 10 terminal. A user message is one
  # row and one empty row.
  use ExUnit.Case, async: true

  import Helyx.Test.TUIRender

  alias ExRatatui.Event.{Key, Paste}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias Helyx.Message
  alias Helyx.TUI.{Search, Transcript}

  @area %Rect{x: 2, y: 0, width: 20, height: 5}

  defp state(cells), do: %{search: nil, vm: view_model(cells), scroll: nil}

  defp users(count), do: for(n <- 1..count, do: Message.user("m#{n}"))

  defp event(state, event, area \\ @area) do
    {:noreply, state} = Search.handle(event, state, area && [area])
    state
  end

  defp press(state, code, modifiers \\ []),
    do: event(state, %Key{code: code, kind: "press", modifiers: modifiers})

  defp open(state), do: press(state, "f", ["ctrl"])

  defp type(state, text), do: text |> String.graphemes() |> Enum.reduce(state, &press(&2, &1))

  defp tool(id, result_text) do
    call = %Message.ToolCall{id: id, name: "bash", arguments: %{}}
    {:tool, call, "⚙ bash", Message.tool_result(call, {:ok, result_text})}
  end

  defp marks(state) do
    rows = Transcript.screen(state.vm, state.scroll, @area)
    Search.marks(state.search, rows, @area)
  end

  # The text of the search line, as the frame of `state` draws it, and
  # after two spaces the notes of the box title.
  defp line(state) do
    [{%Paragraph{text: %Line{spans: spans}, block: %Block{title: title}}, _area}] =
      Search.widgets(state.search, marks(state), %Rect{x: 2, y: 5, width: 20, height: 3})

    notes = if title, do: "  " <> String.trim(title.content), else: ""
    Enum.map_join(spans, & &1.content) <> notes
  end

  test "Ctrl+F opens the search, and the newest match comes first" do
    state = users(10) |> state() |> open()
    assert %Search{query: "", match: nil} = state.search

    # m1 and m10 match; m10 is the newest, in the follow view.
    state = type(state, "m1")
    assert state.search.match == 9
    assert state.scroll == nil

    state = press(state, "enter")
    assert {state.search.match, state.scroll, state.search.note} == {0, {0, 0}, nil}

    assert press(state, "up").search.note == "no older match"
    assert press(state, "up").search.match == 0

    state = press(state, "down")
    assert {state.search.match, state.scroll} == {9, nil}
    assert press(state, "down").search.note == "no newer match"
  end

  test "the query is literal and case-insensitive" do
    state = state([Message.user("axb"), Message.user("A.B"), Message.user("c")]) |> open()
    assert type(state, "a.b").search.match == 1
    assert type(state, "x").search.match == 0
    assert type(state, "[").search.note == "no match"
    assert type(state, "ÄB").search.note == "no match"
    # A match does not cross from one item into the next.
    assert type(state, "bA").search.note == "no match"
    assert state([Message.user("äb")]) |> open() |> type("ÄB") |> then(& &1.search.match) == 0
  end

  test "the view goes to the row of the match, and the match is marked" do
    # The text of a user row is 18 columns after the bar, so "needle" is on
    # the third row, "gggg hhhh needle", at column 2 + 10.
    long = Message.user("aaaa bbbb cccc dddd eeee ffff gggg hhhh needle")
    state = [long | users(10)] |> state() |> open() |> type("NEEDLE")

    assert state.search.match == 0
    assert state.scroll == {0, 2}
    assert [{%Block{style: %{bg: :yellow}}, rect}] = marks(state)
    assert rect == %Rect{x: 2 + 2 + 10, y: 0, width: 6, height: 1}
  end

  test "a match in the lines the short form hides moves to the cell and says so" do
    hidden = Enum.map_join(1..10, "\n", &"line #{&1}")
    state = [tool("c1", hidden) | users(10)] |> state() |> open() |> type("line 9")

    assert {state.search.match, state.scroll} == {0, {0, 0}}
    assert line(state) == "find: line 9   match not shown"
    assert marks(state) == []

    # With the Ctrl+O toggle on, the line shows, and it is marked.
    expanded = %{state | vm: %{state.vm | expanded?: true}} |> press("backspace") |> type("9")

    assert {expanded.search.match, expanded.scroll, line(expanded)} ==
             {0, {0, 9}, "find: line 9 "}

    assert [{%Block{}, %Rect{x: 4, y: 0, width: 6}}] = marks(expanded)

    # An end note does not hide that the match is not shown.
    assert line(press(state, "enter")) == "find: line 9   no older match, match not shown"

    # A shown line of the same cell marks it: the view starts at its row.
    state = state |> press("backspace") |> type("2")
    assert {state.search.match, state.scroll, line(state)} == {0, {0, 2}, "find: line 2 "}
    assert [{%Block{}, %Rect{x: 4, y: 0, width: 6}}] = marks(state)
  end

  test "a long query does not push the notes past the edge of an 80-column frame" do
    # A query of 40 bytes, in a line that the short form hides.
    prefix = String.duplicate("q", 33)
    hidden = Enum.map_join(1..10, "\n", &"#{prefix} line #{&1}")
    state = [tool("c1", hidden)] |> state() |> open() |> type(prefix <> " line 9")
    state = press(state, "enter")
    assert byte_size(state.search.query) == 40

    terminal = ExRatatui.init_test_terminal(80, 3)
    area = %Rect{x: 2, y: 0, width: 76, height: 3}
    :ok = ExRatatui.draw(terminal, Search.widgets(state.search, marks(state), area))
    frame = ExRatatui.get_buffer_content(terminal)
    assert frame =~ "no older match, match not shown"
    assert frame =~ "find: #{prefix} line 9"
  end

  test "the search text holds tool calls, notices, stop lines, and information cells" do
    cells = [
      {:notice, "a notice"},
      {:stop, :max_tokens},
      {:info, "model: x/y"},
      {:info, "resumed session"},
      %Message{role: :assistant, content: [%Message.Thinking{thinking: "deep"}]}
    ]

    state = cells |> state() |> open()
    assert type(state, "notice").search.match == 0
    assert type(state, "token limit").search.match == 1
    assert type(state, "resumed").search.match == 2
    assert type(state, "x/y · resumed").search.match == 2
    assert type(state, "deep").search.match == 3
    assert [tool("c", "x")] |> state() |> open() |> type("⚙ bash") |> then(& &1.search.match) == 0
  end

  test "a new query stays at the match the user reads when it still matches" do
    state = ["ab", "ab", "ab"] |> Enum.map(&Message.user/1) |> state() |> open() |> type("a")
    state = press(state, "up")
    assert state.search.match == 1
    assert type(state, "b").search.match == 1

    # With no match at or before the cursor, the nearest match after it.
    state = ["x1", "x2", "y", "x2"] |> Enum.map(&Message.user/1) |> state() |> open() |> type("x")
    state = state |> press("up") |> press("up")
    assert state.search.match == 0
    assert type(state, "2").search.match == 1
  end

  test "Backspace removes the last character, and an empty query has no match" do
    state = users(3) |> state() |> open() |> type("m2")
    state = press(state, "backspace")
    assert {state.search.query, state.search.match} == {"m", 1}

    state = press(state, "backspace")
    assert {state.search.query, state.search.match, state.search.regex} == {"", nil, nil}
    assert press(state, "enter").search == state.search
    assert press(state, "backspace").search.query == ""
  end

  test "the query has at most 256 bytes; a paste drops its control characters" do
    state = state([Message.user("x")]) |> open()

    full = type(state, String.duplicate("a", 256))
    assert byte_size(full.search.query) == 256
    assert press(full, "b").search.query == full.search.query

    wide = type(state, String.duplicate("é", 128))
    assert press(wide, "é").search.query == wide.search.query

    almost = type(state, String.duplicate("a", 255))
    assert byte_size(press(almost, "é").search.query) == 255

    # The cut comes before the clean: 255 bytes of whole characters; then
    # CR LF is one space, the tab two, and "\u0001" drops.
    pasted = event(state, %Paste{content: "a\r\nb\tc\u0001" <> String.duplicate("é", 200)})
    assert String.starts_with?(pasted.search.query, "a b  cé")
    assert byte_size(pasted.search.query) == 6 + 2 * 124
    assert String.valid?(pasted.search.query)

    # A format character, such as a zero-width joiner, stays, as in the
    # transcript.
    assert event(state, %Paste{content: "a\u200Db"}).search.query == "a\u200Db"
  end

  test "named keys and keys with Ctrl or Alt do not type" do
    state = state([Message.user("x")]) |> open()

    for {code, modifiers} <- [
          {"tab", []},
          {"f1", []},
          {"a", ["ctrl"]},
          {"a", ["alt"]},
          {"\u0001", []}
        ] do
      assert press(state, code, modifiers).search.query == ""
    end

    assert press(state, "A", ["shift"]).search.query == "A"

    # Enter, Up, Down, and Backspace with Ctrl or Alt do nothing.
    state = users(5) |> state() |> open() |> type("m")

    for code <- ["enter", "up", "down", "backspace"], modifier <- ["ctrl", "alt"] do
      assert press(state, code, [modifier]) == state
    end
  end

  test "Escape closes the search and keeps the view" do
    state = users(10) |> state() |> open() |> type("m3")
    assert state.scroll == {2, 0}

    closed = press(state, "esc")
    assert {closed.search, closed.scroll} == {nil, {2, 0}}
    assert Search.marks(closed.search, [], @area) == []
  end

  test "with no terminal size, only Escape acts" do
    state = users(3) |> state() |> open()
    assert event(state, %Key{code: "m", kind: "press"}, nil) == state
    assert event(state, %Paste{content: "m"}, nil) == state
    assert event(state, %Key{code: "esc", kind: "press"}, nil).search == nil
  end

  test "a release does not type, and a match that comes later is found by Enter" do
    state = users(2) |> state() |> open() |> type("late")
    assert state.search.note == "no match"
    assert event(state, %Key{code: "x", kind: "release"}) == state

    state = %{state | vm: view_model(users(2) ++ [Message.user("late")] ++ users(5))}
    state = press(state, "enter")
    assert {state.search.match, state.search.note} == {2, nil}
  end

  test "the marks cover each place of the query in the drawn rows only" do
    state = [Message.user("ab ab ab")] |> state() |> open() |> type("ab")
    assert [{_, a}, {_, b}, {_, c}] = marks(state)
    assert Enum.map([a, b, c], & &1.x) == [4, 7, 10]

    # A drawn frame: the marks sit over the text.
    rows = Transcript.screen(state.vm, state.scroll, @area)
    terminal = ExRatatui.init_test_terminal(24, 5)
    :ok = ExRatatui.draw(terminal, [{Transcript.widget(rows), @area} | marks(state)])
    assert ExRatatui.get_buffer_content(terminal) =~ "ab ab ab"
  end

  test "a tab matches as the two spaces that the row draws" do
    state = [tool("c", "name\tvalue")] |> state() |> open()
    assert type(state, "name  value").search.match == 0
    assert event(state, %Paste{content: "name\tvalue"}).search.match == 0
    assert type(state, "name value").search.note == "no match"
  end

  test "the open assistant message is searched, and a match in Markdown signs is not shown" do
    vm = view_model(users(10))
    vm = %{vm | streaming: [%Message.Text{text: "say **bold** now"}]}
    state = %{search: nil, vm: vm, scroll: nil} |> open() |> type("bold")
    assert state.search.match == 10
    assert [{_, %Rect{x: 6, width: 4}}] = marks(state)

    signs = type(%{state | search: nil} |> open(), "**bold")
    assert signs.search.match == 10
    assert line(signs) == "find: **bold   match not shown"
  end

  test "a cell that arrives during a stream takes the index of the open message" do
    streaming = [%Message.Text{text: "say bold"}]
    vm = %{view_model(users(3)) | streaming: streaming}
    state = %{search: nil, vm: vm, scroll: nil} |> open() |> type("bold")
    assert state.search.match == 3

    # The cursor stays at its index: a new item there is marked when it
    # holds the query, and else the line says the match is not shown.
    holds = %{
      state
      | vm: %{view_model(users(3) ++ [{:notice, "bold too"}]) | streaming: streaming}
    }

    assert [_mark] = marks(holds)
    assert line(holds) == "find: bold "

    other = %{state | vm: %{view_model(users(3) ++ [{:notice, "x"}]) | streaming: streaming}}
    assert line(other) == "find: bold   match not shown"
  end

  test "a match the view left says it is not shown, and a long query is cut at the edge" do
    state = users(10) |> state() |> open() |> type("m3")
    assert line(state) == "find: m3 "
    assert line(%{state | scroll: {6, 0}}) == "find: m3   match not shown"

    long = type(state, String.duplicate("q", 40))
    terminal = ExRatatui.init_test_terminal(24, 3)
    area = %Rect{x: 2, y: 0, width: 20, height: 3}
    :ok = ExRatatui.draw(terminal, Search.widgets(long.search, [], area))
    [_top, row, _bottom] = terminal |> ExRatatui.get_buffer_content() |> String.split("\n")
    assert row == "  │ find: m3qqqqqqqqq│"
  end
end
