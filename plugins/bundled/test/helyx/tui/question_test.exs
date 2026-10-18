defmodule Helyx.TUI.QuestionTest do
  # The picker of the question tool (docs/features/question-tool.md, "The
  # TUI picker"): the TUI callbacks driven directly on a session with the
  # tool, and the fold of the asks.
  use ExUnit.Case, async: true

  alias ExRatatui.Event.{Key, Paste}
  alias Helyx.{Event, Message, Session}
  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.TUI
  alias Helyx.TUI.{Question, ViewModel}

  setup do
    core = :"tui_core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.Question]})
    %{core: core}
  end

  defp option(label), do: %{"label" => label, "description" => "about " <> label}

  defp item(question, labels, multi? \\ false),
    do: %{
      "question" => question,
      "header" => "Pick",
      "options" => Enum.map(labels, &option/1),
      "multi_select" => multi?
    }

  # A TUI on a session whose model calls the tool with `questions`, at the
  # first ask.
  defp asked(core, questions) do
    model = "q_#{System.unique_integer([:positive])}"
    call = %ToolCall{id: "q1", name: "question", arguments: %{"questions" => questions}}
    :ok = Fake.script(core, model, [[call], ["Done."]])
    {:ok, session} = Helyx.Test.SavedSession.start(core, "fake/#{model}")
    {:ok, state} = TUI.mount(session: session, terminal_size_fn: fn -> {80, 24} end)
    assert_receive {ref, _branch} when ref == state.branch_ref
    :ok = Session.prompt(session, "go")
    until(state, &(&1.question != nil))
  end

  # The session events through the TUI until `done?` holds for the state.
  defp until(state, done?) do
    if done?.(state) do
      state
    else
      assert_receive {:helyx_event, %Event{}} = message, 5_000
      {:noreply, state} = TUI.handle_info(message, state)
      until(state, done?)
    end
  end

  # The turn end starts a branch task, whose git port must not outlive the
  # test (see tui_test.exs, `branch_reply/1`).
  defp ended(state) do
    %{branch_ref: ref} = state = until(state, &(not &1.vm.running?))
    assert_receive {^ref, _branch}
    state
  end

  defp press(state, code) do
    {:noreply, state} = TUI.handle_event(%Key{code: code, kind: "press", modifiers: []}, state)
    state
  end

  defp type(state, text), do: text |> String.graphemes() |> Enum.reduce(state, &press(&2, &1))

  defp result(state) do
    [{:tool, _call, _line, %Message{} = result}] =
      for {:tool, _, _, _} = cell <- ViewModel.cells(state.vm), do: cell

    Message.text(result)
  end

  defp screen(state, width, height) do
    terminal = ExRatatui.init_test_terminal(width, height)
    :ok = ExRatatui.draw(terminal, TUI.render(state, %{width: width, height: height}))
    ExRatatui.get_buffer_content(terminal)
  end

  test "Enter picks an option, the next question shows, and the last sends the answers",
       %{core: core} do
    state =
      asked(core, [
        item("Which one?", ~w(a b)),
        item("Which ones?", ~w(x y z), true),
        item("Why?", ~w(m n))
      ])

    text = screen(state, 80, 24)
    assert text =~ "Pick 1/3"
    assert text =~ "Which one?"
    assert text =~ "› a  about a"
    assert text =~ "Other:"

    state = state |> press("down") |> press("enter")
    assert screen(state, 80, 24) =~ "Pick 2/3"
    assert screen(state, 80, 24) =~ "[ ] x"

    state = state |> press(" ") |> press("down") |> press("down") |> press(" ")
    assert screen(state, 80, 24) =~ "[x] z"
    state = press(state, "enter")

    state = state |> type("bec") |> press("backspace") |> type("ause") |> press("enter")
    assert screen(state, 80, 24) =~ "answer sent"
    assert press(state, "up") == state

    state = ended(state)
    assert state.question == nil

    assert result(state) ==
             "The user answered:\n\nQ: Which one?\nA: b\n\nQ: Which ones?\nA: x, z\n\n" <>
               "Q: Why?\nA: other: beause"
  end

  test "an empty Other line takes no Enter; a marked option goes with the text", %{core: core} do
    state = asked(core, [item("Which ones?", ~w(x y), true)])
    state = state |> press(" ") |> press("down") |> press("down")
    assert press(state, "enter") == state

    {:noreply, state} = TUI.handle_event(%Paste{content: "one\ntwo"}, state)
    state = state |> press("enter") |> ended()
    assert result(state) == "The user answered:\n\nQ: Which ones?\nA: x; other: one two"
  end

  test "an answer of another client closes the picker", %{core: core} do
    state = asked(core, [item("Which one?", ~w(a b))])
    assert [%{ask_id: id, call_id: "q1"}] = state.vm.asks
    assert state.question.ask_id == id
    :ok = Session.answer(state.session, id, %{"answers" => [%{"selected" => ["a"]}]})
    state = until(state, &(&1.question == nil))
    assert state.vm.asks == []
    assert result(ended(state)) == "The user answered:\n\nQ: Which one?\nA: a"
  end

  test "Escape aborts the turn and the picker closes", %{core: core} do
    state = asked(core, [item("Which one?", ~w(a b))])
    state = press(state, "esc")
    state = ended(state)
    assert state.question == nil
    assert result(state) == "aborted"
  end

  test "an answer over 16 KiB stays in the picker, and the footer says why", %{core: core} do
    state = asked(core, [item("Which one?", ~w(a b))])
    # Each quote is two bytes of JSON: 16,384 bytes of text are over the bound.
    {:noreply, state} = TUI.handle_event(%Paste{content: String.duplicate("\"", 20_000)}, state)
    assert byte_size(state.question.other) == 16_384
    state = press(state, "enter")

    assert state.vm.reason == "not sent: the answers are over 16 KiB"
    assert state.question.at == 0
    assert Helyx.Test.Events.snapshot(state.session).asks != []
  end

  test "an answer goes on only with room for each later question", %{core: core} do
    state = asked(core, [item("Which one?", ~w(a b)), item("Why?", ~w(m n))])

    # The room of the first answer leaves the longest option of the second
    # question: `{"selected":["m"]}` and a comma, 19 bytes.
    room = 16_384 - byte_size(~s({"answers":[{"other":"","selected":[]}]})) - 19
    {:noreply, state} = TUI.handle_event(%Paste{content: String.duplicate("o", room + 1)}, state)
    state = press(state, "enter")
    assert state.vm.reason == "not sent: the answers are over 16 KiB"
    assert state.question.at == 0

    state = state |> press("backspace") |> press("enter")
    assert state.question.at == 1
    state = state |> press("enter") |> ended()
    assert result(state) =~ "Q: Why?\nA: m"
  end

  test "Escape aborts the turn also over a search that the picker hides", %{core: core} do
    state = asked(core, [item("Which one?", ~w(a b))])
    state = %{state | search: %Helyx.TUI.Search{}}
    state = state |> press("esc") |> ended()
    assert result(state) == "aborted"
  end

  test "Enter on a multi-select option with no mark takes that option", %{core: core} do
    state = asked(core, [item("Which ones?", ~w(x y), true)])
    state = state |> press("down") |> press("enter") |> ended()
    assert result(state) == "The user answered:\n\nQ: Which ones?\nA: y"
  end

  test "the Other line shows the end of its text that fits the row", %{core: core} do
    state = asked(core, [item("Which one?", ~w(a b))])
    text = String.duplicate("word ", 20) <> "lastword"
    {:noreply, state} = TUI.handle_event(%Paste{content: text}, state)

    # 80 columns, the margins of 2 and the borders leave 74; the pointer,
    # "Other: ", and the cursor take 10 more, with 2 of slack.
    assert screen(state, 80, 24) =~ "Other: " <> String.slice(text, -64..-1)
    refute screen(state, 80, 24) =~ String.slice(text, -65..-1)
  end

  test "the picker shows only an ask of the question tool" do
    vm = Helyx.Test.TUIRender.view_model([])
    other = %{ask_id: "k2", call_id: "c2", tool: "other", request: %{}}
    state = Question.sync(%{vm: %{vm | asks: [other]}, question: nil})
    assert state.question == nil
  end

  test "a second ask of the same call gets a fresh picker" do
    vm = Helyx.Test.TUIRender.view_model([])

    first = %{
      ask_id: "k1",
      call_id: "q1",
      tool: "question",
      request: %{"questions" => [item("Which one?", ~w(a b))]}
    }

    state = Question.sync(%{vm: %{vm | asks: [first]}, question: nil})
    state = %{state | question: %{state.question | cursor: 1, sent?: true}}

    state = Question.sync(%{state | vm: %{vm | asks: [%{first | ask_id: "k2"}]}})
    assert %Question{ask_id: "k2", cursor: 0, sent?: false} = state.question
  end

  test "the picker fits its room: the question rows are cut first", %{core: core} do
    long = String.duplicate("word ", 199) <> "end?"
    state = asked(core, [item(long, ~w(a b c d))])

    # 200 words of 5 columns are 14 rows of 15 words at 74 columns; the 4
    # options, the Other line, and the borders take 7 rows more.
    assert Question.rows(state.question, 76, 100) == 21
    assert Question.rows(state.question, 76, 10) == 9

    text = screen(state, 80, 14)
    assert text =~ "› a  about a"
    assert text =~ "d  about d"
    assert text =~ "Other:"
    refute text =~ "end?"
  end

  defp event(type, data),
    do: %Event{type: type, data: data, session_id: "s", instance_id: "i", turn_id: "t", seq: 1}

  test "the view model folds the asks, and a snapshot gives them" do
    ask = %{ask_id: "k1", call_id: "c1", tool: "question", request: %{"questions" => []}}
    other = %{ask_id: "k2", call_id: "c2", tool: "other", request: %{}}
    vm = Helyx.Test.TUIRender.view_model([])

    vm = ViewModel.apply(vm, event(:ask, ask))
    vm = ViewModel.apply(vm, event(:ask, other))
    assert vm.asks == [ask, other]
    ended = event(:ask_end, %{ask_id: "k1", outcome: :ended})
    assert ViewModel.apply(vm, ended).asks == [other]

    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 0,
      messages: [],
      turn: nil,
      model: "fake/m",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      more: false,
      usage: %Helyx.Session.Totals{},
      context: nil,
      asks: [other]
    }

    assert ViewModel.from_snapshot(snapshot).asks == [other]
  end
end
