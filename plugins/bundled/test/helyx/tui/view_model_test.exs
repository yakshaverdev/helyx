defmodule Helyx.TUI.ViewModelTest do
  # The event fold, driven by scripted event lists, as the ticket requires.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message}
  alias Helyx.TUI.ViewModel

  import Helyx.Test.TUIRender, only: [texts: 1, view_model: 1, view_model: 2]

  # Builds a session's event list with sequence numbers assigned in order.
  defp events(specs) do
    specs
    |> Enum.with_index(1)
    |> Enum.map(fn {{type, data}, seq} ->
      %Event{type: type, session_id: "s", instance_id: "i", turn_id: "t", seq: seq, data: data}
    end)
  end

  defp fold(specs),
    do: Enum.reduce(events(specs), new(), &ViewModel.apply(&2, &1))

  defp new, do: view_model([], "test/model")

  defp cells(vm), do: ViewModel.cells(vm)

  defp tool_end(result), do: {:tool_execution_end, %{message: result}}

  defp user(text), do: Message.user(text)

  defp assistant(blocks, stop_reason \\ :end_turn) do
    %Message{role: :assistant, content: blocks, model: "test/model", stop_reason: stop_reason}
  end

  test "a prompt and a streamed answer become cells in order" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
    answer = assistant([%Message.Text{text: "Listing."}, call], :tool_use)

    vm =
      fold([
        {:turn_start, %{}},
        {:message_start, %{message: user("hello")}},
        {:message_end, %{message: user("hello")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{text_delta: "List"}},
        {:message_update, %{text_delta: "ing."}},
        {:message_update, %{tool_call: call}},
        {:message_end, %{message: answer}}
      ])

    assert [%Message{role: :user}, %Message{role: :assistant} = done, {:tool, ^call, _, nil}] =
             cells(vm)

    assert Message.text(done) == "Listing."
    assert vm.streaming == nil
    assert vm.running?
  end

  test "deltas stream into the open assistant message" do
    vm =
      fold([
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{thinking_delta: "hm"}},
        {:message_update, %{thinking_delta: "m"}},
        {:message_update, %{text_delta: "Hi"}},
        {:message_update, %{text_delta: "!"}}
      ])

    assert vm.streaming == [
             %Message.Text{text: "Hi!"},
             %Message.Thinking{thinking: "hmm"}
           ]
  end

  # The cells of an assistant message: the message, then an open cell for
  # each call.
  defp calls_end(calls), do: {:message_end, %{message: assistant(calls, :tool_use)}}

  defp open(call), do: {:tool, call, ViewModel.call_line(call), nil}
  defp closed(call, result), do: {:tool, call, ViewModel.call_line(call), result}

  test "a call gets an open cell from its message, and its result closes it" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
    result = Message.tool_result(call, {:ok, "lib\ntest"})
    head = [{:turn_start, %{}}, {:message_end, %{message: user("hi")}}]

    open_vm = fold(head ++ [calls_end([call])])
    assert List.last(cells(open_vm)) == open(call)

    closed_vm = fold(head ++ [calls_end([call]), tool_end(result)])
    assert List.last(cells(closed_vm)) == closed(call, result)
  end

  # A harness program runs a call of the open message (#385): its cell shows
  # "awaiting result" before the message ends, and keeps its place.
  test "a call of the streaming message shows awaiting result until its result" do
    call = %Message.ToolCall{id: "h", name: "bash", arguments: %{"command" => "ls"}}
    result = Message.tool_result(call, {:ok, "lib"})

    streaming =
      fold([
        {:message_end, %{message: user("hi")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{text_delta: "Listing."}},
        {:message_update, %{tool_call: call}}
      ])

    assert streaming.streaming == [open(call), %Message.Text{text: "Listing."}]
    assert ["▌ hi", "Listing.", "⚙ bash command=\"ls\"", "… awaiting result"] == texts(streaming)

    ended =
      Enum.reduce(
        events([calls_end([%Message.Text{text: "Listing."}, call]), tool_end(result)]),
        streaming,
        &ViewModel.apply(&2, &1)
      )

    assert [_user, %Message{}, closed] = cells(ended)
    assert closed == closed(call, result)
  end

  # A rejected `/model` command adds a notice while the tool runs (#83).
  for {name, outcome} <- [{"an ok", {:ok, "lib"}}, {"an error", {:error, "exit 1"}}] do
    test "#{name} result attaches past a notice added during the tool run" do
      call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
      result = Message.tool_result(call, unquote(outcome))

      vm =
        [calls_end([call])]
        |> fold()
        |> ViewModel.notice("usage: /model provider/model")
        |> ViewModel.apply(hd(events([tool_end(result)])))

      assert cells(vm) == [
               assistant([call], :tool_use),
               closed(call, result),
               {:notice, "usage: /model provider/model"}
             ]
    end
  end

  # A provider can repeat an id: the first result answers the first call,
  # as in the session's transcript.
  test "a result goes to the oldest open tool cell with its id" do
    read = %Message.ToolCall{id: "t", name: "read", arguments: %{}}
    bash = %Message.ToolCall{id: "t", name: "bash", arguments: %{}}
    one = Message.tool_result(read, {:ok, "one"})

    vm = fold([calls_end([read, bash]), tool_end(one)])
    assert cells(vm) == [assistant([read, bash], :tool_use), closed(read, one), open(bash)]
  end

  # The fold does not depend on the order of the results: each open cell
  # gets its own result.
  test "two open tool cells get their own results, in any order" do
    c1 = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    c2 = %Message.ToolCall{id: "c2", name: "read", arguments: %{}}
    r1 = Message.tool_result(c1, {:ok, "one"})
    r2 = Message.tool_result(c2, {:error, "two"})
    expected = [assistant([c1, c2], :tool_use), closed(c1, r1), closed(c2, r2)]

    assert cells(fold([calls_end([c1, c2]), tool_end(r1), tool_end(r2)])) == expected
    assert cells(fold([calls_end([c1, c2]), tool_end(r2), tool_end(r1)])) == expected
  end

  # A provider can use the same id again in a later message.
  test "a result goes to the oldest open cell with its id, also across messages" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    first = Message.tool_result(call, {:ok, "first"})
    second = Message.tool_result(call, {:ok, "second"})
    message = assistant([call], :tool_use)

    assert cells(fold([calls_end([call]), tool_end(first), calls_end([call]), tool_end(second)])) ==
             [message, closed(call, first), message, closed(call, second)]

    assert cells(fold([calls_end([call]), calls_end([call]), tool_end(first), tool_end(second)])) ==
             [message, closed(call, first), message, closed(call, second)]
  end

  # Every call has an open cell from its message (#385, #405), so a result
  # with no open cell is a bug in Core (#407).
  test "a result with no open cell crashes" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    first = Message.tool_result(call, {:ok, "first"})
    second = Message.tool_result(call, {:ok, "second"})
    unknown = %{first | tool_call_id: "c9"}

    assert_raise KeyError, fn -> fold([{:turn_start, %{}}, tool_end(unknown)]) end
    assert_raise KeyError, fn -> fold([calls_end([call]), tool_end(unknown)]) end
    assert_raise KeyError, fn -> fold([calls_end([call]), tool_end(first), tool_end(second)]) end
  end

  # One pairing rule: the snapshot messages go through the live fold.
  test "a snapshot equals the live fold of the same messages" do
    t1 = %Message.ToolCall{id: "t", name: "read", arguments: %{}}
    t2 = %Message.ToolCall{id: "t", name: "bash", arguments: %{}}
    c3 = %Message.ToolCall{id: "c3", name: "ls", arguments: %{}}
    c4 = %Message.ToolCall{id: "c4", name: "ls", arguments: %{}}
    calls = assistant([%Message.Text{text: "Go."}, t1, t2, c3, c4], :tool_use)
    r1 = Message.tool_result(t1, {:ok, "one"})
    r2 = Message.tool_result(t2, {:error, "two"})
    r4 = Message.tool_result(c4, {:ok, "four"})
    messages = [user("hi"), calls, r4, r1, r2]

    live =
      fold([
        {:message_end, %{message: user("hi")}},
        {:message_end, %{message: calls}},
        tool_end(r4),
        tool_end(r1),
        tool_end(r2)
      ])

    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 5,
      messages: messages,
      turn: nil,
      model: "test/model",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      more: false,
      usage: %Helyx.Session.Totals{},
      context: nil
    }

    joined = ViewModel.from_snapshot(snapshot)
    assert cells(joined) == cells(live)

    assert cells(live) == [
             user("hi"),
             calls,
             closed(t1, r1),
             closed(t2, r2),
             open(c3),
             closed(c4, r4)
           ]
  end

  test "an aborted turn closes the stream and shows a notice" do
    vm =
      fold([
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{text_delta: "so far"}},
        {:message_end,
         %{message: assistant([%Message.Text{text: "so far"}], :aborted), error: :aborted}},
        {:turn_end, %{outcome: :aborted}}
      ])

    refute vm.running?
    assert vm.streaming == nil
    assert [_user, %Message{stop_reason: :aborted}, {:notice, "aborted"}] = cells(vm)
  end

  # The live fold and a late client that joins with the snapshot.
  defp stop_cells(stop) do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    answer = assistant([%Message.Text{text: "so far"}, call], stop)
    live = fold([{:message_end, %{message: user("hi")}}, {:message_end, %{message: answer}}])

    joined =
      ViewModel.from_snapshot(%Helyx.Session.Snapshot{
        instance_id: "i",
        seq: 2,
        messages: [user("hi"), answer],
        turn: nil,
        model: "test/model",
        queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
        persisting: true,
        more: false,
        usage: %Helyx.Session.Totals{},
        context: nil
      })

    {cells(live), cells(joined)}
  end

  for stop <- [:max_tokens, :refused] do
    test "an answer that stopped with #{stop} gets a stop line after its tool cells" do
      assert {[_user, _answer, {:tool, _, _, nil}, {:stop, unquote(stop)}] = cells, cells} =
               stop_cells(unquote(stop))
    end
  end

  for stop <- [:end_turn, :tool_use, :aborted, :error] do
    test "an answer that stopped with #{stop} gets no stop line" do
      assert {[_user, _answer, {:tool, _, _, nil}] = cells, cells} = stop_cells(unquote(stop))
    end
  end

  test "the transcript draws a stop line as a notice" do
    assert texts(view_model([{:stop, :max_tokens}, {:stop, :refused}])) == [
             "✕ the answer stopped at the token limit",
             "✕ the answer stopped: the provider refused or filtered it"
           ]
  end

  test "a failed turn shows the error" do
    vm =
      fold([
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:turn_end, %{outcome: :error, error: ":stream_ended"}}
      ])

    refute vm.running?
    assert List.last(cells(vm)) == {:notice, "error: :stream_ended"}
  end

  test "a tool call line is cut at 8,192 bytes, after newlines become ␤" do
    # A name and a key of newlines, each far over the cut: "␤" is 3 bytes
    # for 1, and neither is copied whole.
    lines = String.duplicate("\n", 1_000_000)
    call = %Message.ToolCall{id: "c", name: lines, arguments: %{lines => 1}}

    line = ViewModel.call_line(call)
    assert byte_size(line) in 8_190..8_192
    assert String.starts_with?(line, "⚙ ␤␤")
    refute line =~ "\n"

    # U+00A0 renders as `\u00A0` through `inspect/1`, and the keys are raw.
    arguments = Map.new(1..2_000, &{"k#{&1}", String.duplicate("\u00A0", 100)})
    line = ViewModel.call_line(%Message.ToolCall{id: "c", name: "bash", arguments: arguments})
    assert byte_size(line) in 8_190..8_192
    assert String.starts_with?(line, "⚙ bash k")
  end

  test "an error text shows as Core wrote it" do
    # Core bounds the text (ADR 0006 §2), so the TUI does not cut it.
    text = String.duplicate("é", 2_000)
    vm = fold([{:turn_end, %{outcome: :error, error: text}}])
    assert List.last(cells(vm)) == {:notice, "error: " <> text}
  end

  test "queue updates change the counts, including the nil-turn drain" do
    vm =
      fold([
        {:turn_start, %{}},
        {:queue_update, %{steers: 1, follow_ups: 0}},
        {:queue_update, %{steers: 1, follow_ups: 2}}
      ])

    assert vm.queue == %{steers: 1, follow_ups: 2}

    drain = %Event{
      type: :queue_update,
      session_id: "s",
      instance_id: "i",
      turn_id: nil,
      seq: 4,
      data: %{steers: 0, follow_ups: 0}
    }

    assert ViewModel.apply(vm, drain).queue == %{steers: 0, follow_ups: 0}
  end

  test "an event of an unknown type leaves the view model unchanged" do
    vm = fold([{:turn_start, %{}}, {:message_start, %{message: assistant([])}}])

    unknown = %Event{
      type: :from_a_newer_core,
      session_id: "s",
      instance_id: "i",
      turn_id: "t",
      seq: 3,
      data: %{}
    }

    assert ViewModel.apply(vm, unknown) == vm
  end

  # A value from a newer Core in a known event type.
  defmodule NewBlock do
    @moduledoc false
    defstruct [:data]
  end

  test "a new block kind shows a placeholder" do
    vm =
      fold([
        {:message_start, %{message: assistant([])}},
        {:message_end, %{message: assistant([%NewBlock{data: 1}, %Message.Text{text: "hi"}])}}
      ])

    assert ["[unsupported block: new_block]", "hi"] == texts(vm)
  end

  test "a new block kind in a user message or a tool result shows a placeholder" do
    block = %NewBlock{data: 1}
    call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}
    result = %{Message.tool_result(call, {:ok, "x"}) | content: [block]}

    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 3,
      messages: [
        %Message{role: :user, content: [%Message.Text{text: "see "}, block]},
        assistant([call], :tool_use),
        result
      ],
      turn: nil,
      model: "test/model",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      more: false,
      usage: %Helyx.Session.Totals{},
      context: nil
    }

    assert ["▌ see [unsupported block: new_block]", "⚙ read", "  [unsupported block: new_block]"] ==
             texts(ViewModel.from_snapshot(snapshot))
  end

  test "a snapshot of a session that does not save ends with its notice, after the transcript" do
    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 2,
      messages: [user("hi"), assistant([%Message.Text{text: "done"}])],
      turn: nil,
      model: "test/model",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: false,
      more: false,
      usage: %Helyx.Session.Totals{},
      context: nil
    }

    assert [%Message{role: :user}, %Message{role: :assistant}, notice] =
             ViewModel.cells(ViewModel.from_snapshot(snapshot))

    assert notice == {:notice, Helyx.Reason.text(:not_saved)}

    assert ViewModel.cells(ViewModel.from_snapshot(%{snapshot | persisting: true})) |> length() ==
             2
  end

  test "a snapshot keeps a new block kind" do
    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 3,
      messages: [
        user("hi"),
        assistant([%NewBlock{data: 1}, %Message.Text{text: "done"}])
      ],
      turn: %{
        id: "t",
        partial: assistant([%NewBlock{data: 2}, %Message.Text{text: "more"}]),
        running: []
      },
      model: "test/model",
      queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0},
      persisting: true,
      more: false,
      usage: %Helyx.Session.Totals{},
      context: nil
    }

    vm = ViewModel.from_snapshot(snapshot)

    assert [%Message{role: :user}, %Message{role: :assistant}] = cells(vm)
    assert vm.streaming == [%Message.Text{text: "more"}, %NewBlock{data: 2}]

    assert ["▌ hi", "[unsupported block: new_block]", "done"] ++
             ["[unsupported block: new_block]", "more"] == texts(vm)
  end

  # Each known type that the TUI reads matches the type only, so a broken
  # payload reaches its clause and crashes; it never reaches the clause that
  # ignores an unknown type.
  test "every known type with a broken payload crashes" do
    for {type, data} <- [
          turn_end: %{},
          message_start: %{},
          message_start: %{message: "not a message"},
          message_end: %{},
          tool_execution_end: %{message: Message.user("not a result")},
          queue_update: %{steers: 1},
          model_change: %{},
          model_change: %{model: nil},
          notice: %{},
          steer_unconfirmed: %{},
          resume_id: %{provider: "p"}
        ] do
      [event] = events([{type, data}])
      assert catch_error(ViewModel.apply(new(), event)), inspect(type)
    end
  end

  test "a turn_end with the outcome error and no error field crashes" do
    event = %Event{
      type: :turn_end,
      session_id: "s",
      instance_id: "i",
      turn_id: "t",
      seq: 1,
      data: %{outcome: :error}
    }

    assert_raise CaseClauseError, fn -> ViewModel.apply(new(), event) end
  end

  test "a message_update with no known delta key, a known key of another type, or two known keys, crashes" do
    vm = fold([{:message_start, %{message: assistant([])}}])

    for data <- [
          %{},
          %{signature_delta: "x"},
          %{tool_call: "not a call"},
          %{text_delta: 42},
          %{thinking_delta: nil},
          %{text_delta: "a", tool_call: "bad"}
        ] do
      event = %Event{
        type: :message_update,
        session_id: "s",
        instance_id: "i",
        turn_id: "t",
        seq: 2,
        data: data
      }

      assert_raise CaseClauseError, fn -> ViewModel.apply(vm, event) end
    end
  end

  test "a compaction adds one information line, at most about 40 bytes" do
    vm =
      fold(
        compaction: %{trigger: :manual, tokens_before: 29_557, tokens_after: 3_926},
        compaction: %{trigger: :auto, tokens_before: 999, tokens_after: nil},
        compaction: %{trigger: :auto, tokens_before: 1_000_000_000, tokens_after: 0}
      )

    assert cells(vm) == [
             {:info, "compacted: 30k → 4k tokens"},
             {:info, "compacted (auto)"},
             {:info, "compacted: 1000000k → 0 tokens (auto)"}
           ]

    assert Enum.all?(cells(vm), fn {:info, text} -> byte_size(text) <= 40 end)
  end

  test "a model change updates the model and adds an information cell" do
    vm = fold(model_change: %{model: "other/model"})
    assert vm.model == "other/model"
    assert cells(vm) == [{:info, "model: other/model"}]
  end

  test "the transcript draws an information cell dim and without the error mark" do
    vm = view_model([{:info, "model: other/model"}, {:notice, "aborted"}], "other/model")

    %ExRatatui.Widgets.Paragraph{text: lines} =
      Helyx.TUI.Transcript.widget(vm, {0, 0}, %ExRatatui.Layout.Rect{width: 80, height: 10})

    assert [
             [%{content: "· model: other/model", style: %{fg: nil, modifiers: [:dim]}}],
             [],
             [%{content: "✕ aborted", style: %{fg: :red}}],
             []
           ] = Enum.map(lines, & &1.spans)
  end

  test "consecutive information cells join into one dim row with no empty row between" do
    vm =
      view_model([
        {:info, "resumed session"},
        {:info, "model: a/b"},
        {:notice, "aborted"},
        {:info, "model: c/d"}
      ])

    %ExRatatui.Widgets.Paragraph{text: lines} =
      Helyx.TUI.Transcript.widget(vm, {0, 0}, %ExRatatui.Layout.Rect{width: 80, height: 10})

    assert [
             [%{content: "· resumed session · model: a/b", style: %{modifiers: [:dim]}}],
             [],
             [%{content: "✕ aborted"}],
             [],
             [%{content: "· model: c/d"}],
             []
           ] = Enum.map(lines, & &1.spans)

    # The run is one item of the scroll position: item 2 is the last run,
    # and its 2 rows to the end are not more than a screen of 3 rows.
    assert Helyx.TUI.Transcript.hold(vm, {2, 0}, 80, 3) == nil
  end

  test "the transcript draws assistant text as Markdown and user text as it is" do
    reply = %Helyx.Message{
      role: :assistant,
      content: [%Helyx.Message.Text{text: "**a** `b`"}]
    }

    vm = view_model([Helyx.Message.user("**a**"), reply])

    %ExRatatui.Widgets.Paragraph{text: lines} =
      Helyx.TUI.Transcript.widget(vm, {0, 0}, %ExRatatui.Layout.Rect{width: 20, height: 10})

    assert [
             [_bar, %{content: "**a**"}, _fill],
             [],
             [
               %{content: "a", style: %{fg: nil, modifiers: [:bold]}},
               %{content: " ", style: %{modifiers: []}},
               %{content: "b", style: %{fg: :yellow, modifiers: []}}
             ],
             []
           ] = Enum.map(lines, & &1.spans)
  end

  test "a mark after a closing sign or a prefix is drawn" do
    # The mark joins the letter before it, or the last space of a bullet or
    # a code indent.
    for {text, drawn} <- [
          {"**e**́x", "éx"},
          {"- **́x**", "• ́x"},
          {"```\ńx\n```", " ́x"}
        ] do
      reply = %Helyx.Message{role: :assistant, content: [%Helyx.Message.Text{text: text}]}
      area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: 6, height: 1}
      terminal = ExRatatui.init_test_terminal(6, 1)

      :ok =
        ExRatatui.draw(terminal, [
          {Helyx.TUI.Transcript.widget(view_model([reply]), {0, 0}, area), area}
        ])

      assert ExRatatui.get_buffer_content(terminal) =~ drawn, inspect(text)
    end
  end

  test "a user message has a bar and a tint on every row, filled to the width" do
    vm = view_model([Helyx.Message.user("one two three four")])

    %ExRatatui.Widgets.Paragraph{text: lines} =
      Helyx.TUI.Transcript.widget(vm, {0, 0}, %ExRatatui.Layout.Rect{width: 12, height: 10})

    tint = %ExRatatui.Style{fg: :white, bg: :black}
    fill = String.duplicate(" ", 12)

    assert [
             [
               %{content: "▌ ", style: %{fg: :blue, bg: :black}},
               %{content: "one two", style: ^tint},
               %{content: ^fill, style: ^tint}
             ],
             [%{content: "▌ "}, %{content: "three four"}, %{content: ^fill, style: ^tint}],
             []
           ] = Enum.map(lines, & &1.spans)
  end

  test "the text of a user row is never wider than the width, but for a glyph wider than it" do
    vm = view_model([Helyx.Message.user("a 語 क्षि b")])

    for width <- 0..8 do
      %ExRatatui.Widgets.Paragraph{text: lines} =
        Helyx.TUI.Transcript.widget(vm, {0, 0}, %ExRatatui.Layout.Rect{width: width, height: 30})

      for %{spans: [_ | _] = spans} <- lines do
        text = spans |> Enum.map_join(& &1.content) |> String.trim_trailing()
        # A glyph wider than the width has a row of its own, with no bar.
        assert Helyx.TUI.Wrap.columns(text) <= max(width, 1) or String.length(text) == 1,
               "width #{width}: #{inspect(text)}"
      end
    end
  end

  test "the tint of a user row reaches the edge, also after an emoji sequence" do
    # A glyph that the rule counts wider than the text width gets no bar,
    # and its row keeps the tint: 語 at 3, and a conjunct that the rule
    # counts as 79 columns at 80, which the terminal draws narrower.
    conjunct = String.duplicate("क्", 39) <> "क"

    for {text, width} <- [
          {"hi", 12},
          {"👩‍💻", 12},
          {"🇺🇸 x", 12},
          {"👍🏽", 12},
          {"語", 3},
          {"👍🏽", 5},
          {"hi", 2},
          {"क्", 3},
          {"123456789\u0600", 12},
          {"\u0600", 1},
          {"\u0600", 3},
          {conjunct, 80}
        ] do
      vm = view_model([Helyx.Message.user(text)])
      area = %ExRatatui.Layout.Rect{x: 0, y: 0, width: width, height: 1}
      terminal = ExRatatui.init_test_terminal(width, 1)
      hashes = %ExRatatui.Widgets.Paragraph{text: String.duplicate("#", width)}

      :ok =
        ExRatatui.draw(terminal, [
          {hashes, area},
          {Helyx.TUI.Transcript.widget(vm, {0, 0}, area), area}
        ])

      refute ExRatatui.get_buffer_content(terminal) =~ "#", inspect(text)
    end
  end

  test "a resume id shows a notice when the provider lost its session or got a cut transcript" do
    fresh = %{provider: "claude-code", resume_id: "s", lost: false, cut: 0}
    assert cells(fold(resume_id: fresh)) == []

    assert cells(fold(resume_id: %{fresh | lost: true, cut: 4})) == [
             {:notice, "claude-code lost its own session; a fresh one got the transcript"},
             {:notice, "claude-code got the transcript without its 4 oldest messages"}
           ]
  end

  test "an unconfirmed steer shows a notice with its text" do
    assert cells(fold(steer_unconfirmed: %{text: "more"})) == [
             {:notice, "the steer was not confirmed; send it again if needed: more"}
           ]
  end

  test "a session notice shows its text" do
    assert cells(fold(notice: %{text: "the session file could not be written"})) == [
             {:notice, "the session file could not be written"}
           ]
  end

  test "a reject adds no cell, and a session event keeps its reason" do
    vm = ViewModel.reject(new(), "not sent: the queue is full")
    assert cells(vm) == []

    # A session event does not clear the reason; the TUI does, on a key press or a paste.
    [event] = events([{:queue_update, %{steers: 1, follow_ups: 0}}])
    kept = ViewModel.apply(vm, event)
    assert kept.reason == "not sent: the queue is full"
  end
end
