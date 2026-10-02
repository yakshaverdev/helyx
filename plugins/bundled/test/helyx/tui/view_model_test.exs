defmodule Helyx.TUI.ViewModelTest do
  # The event fold, driven by scripted event lists, as the ticket requires.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message}
  alias Helyx.TUI.ViewModel

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

  # The view model of the instance of `events/1`.
  defp new, do: %{ViewModel.new("test/model") | instance_id: "i"}

  defp tool_end(result), do: {:tool_execution_end, %{message: result}}

  defp user(text), do: Message.user(text)

  defp assistant(blocks, stop_reason \\ :end_turn) do
    %Message{role: :assistant, content: blocks, model: "test/model", stop_reason: stop_reason}
  end

  test "a new view model shows the model and an idle session" do
    vm = ViewModel.new("test/model")
    assert vm.model == "test/model"
    assert vm.cells == []
    assert vm.streaming == nil
    refute vm.running?
    assert vm.queue == %{steers: 0, follow_ups: 0}
  end

  test "a prompt and a streamed answer become cells in order" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
    answer = assistant([%Message.Text{text: "Listing."}, call], :tool_use)

    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_start, %{message: user("hello")}},
        {:message_end, %{message: user("hello")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{text_delta: "List"}},
        {:message_update, %{text_delta: "ing."}},
        {:message_update, %{tool_call: call}},
        {:message_end, %{message: answer}}
      ])

    assert [%Message{role: :user}, %Message{role: :assistant} = done] = vm.cells
    assert Message.text(done) == "Listing."
    assert vm.streaming == nil
    assert vm.running?
  end

  test "deltas stream into the open assistant message" do
    vm =
      fold([
        {:agent_start, %{}},
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

  test "tool calls and results attach as they happen" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
    result = Message.tool_result(call, {:ok, "lib\ntest"})

    started =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:message_end, %{message: assistant([call], :tool_use)}},
        {:tool_execution_start, %{tool_call: call}}
      ])

    assert List.last(started.cells) == {:tool, call, ViewModel.call_line(call), nil}

    finished =
      ViewModel.apply(started, %Event{
        type: :tool_execution_end,
        session_id: "s",
        instance_id: "i",
        turn_id: "t",
        seq: 6,
        data: %{message: result}
      })

    assert List.last(finished.cells) == {:tool, call, ViewModel.call_line(call), result}
  end

  # A rejected `/model` command adds a notice while the tool runs (#83).
  for {name, outcome} <- [{"an ok", {:ok, "lib"}}, {"an error", {:error, "exit 1"}}] do
    test "#{name} result attaches past a notice added during the tool run" do
      call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
      result = Message.tool_result(call, unquote(outcome))

      vm =
        [{:tool_execution_start, %{tool_call: call}}]
        |> fold()
        |> ViewModel.notice("usage: /model provider/model")
        |> ViewModel.apply(%{hd(events([tool_end(result)])) | seq: 2})

      assert vm.cells == [
               {:tool, call, ViewModel.call_line(call), result},
               {:notice, "usage: /model provider/model"}
             ]
    end
  end

  # A connected turn starts all calls of a message at once, and a provider
  # can repeat an id: the first result answers the first call, as in the
  # session's transcript.
  test "a result goes to the oldest open tool cell with its id" do
    read = %Message.ToolCall{id: "t", name: "read", arguments: %{}}
    bash = %Message.ToolCall{id: "t", name: "bash", arguments: %{}}
    one = Message.tool_result(read, {:ok, "one"})

    vm =
      fold([
        {:tool_execution_start, %{tool_call: read}},
        {:tool_execution_start, %{tool_call: bash}},
        tool_end(one)
      ])

    assert vm.cells == [
             {:tool, read, ViewModel.call_line(read), one},
             {:tool, bash, ViewModel.call_line(bash), nil}
           ]
  end

  # The session runs tool calls one at a time (start, end, start, end). The
  # fold does not depend on that order: each open cell gets its own result.
  test "two open tool cells get their own results, in any order" do
    c1 = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    c2 = %Message.ToolCall{id: "c2", name: "read", arguments: %{}}
    r1 = Message.tool_result(c1, {:ok, "one"})
    r2 = Message.tool_result(c2, {:error, "two"})

    starts = [
      {:tool_execution_start, %{tool_call: c1}},
      {:tool_execution_start, %{tool_call: c2}}
    ]

    assert fold(starts ++ [tool_end(r1), tool_end(r2)]).cells == [
             {:tool, c1, ViewModel.call_line(c1), r1},
             {:tool, c2, ViewModel.call_line(c2), r2}
           ]

    assert fold(starts ++ [tool_end(r2), tool_end(r1)]).cells == [
             {:tool, c1, ViewModel.call_line(c1), r1},
             {:tool, c2, ViewModel.call_line(c2), r2}
           ]
  end

  test "the session order, one call at a time, attaches each result" do
    c1 = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    c2 = %Message.ToolCall{id: "c2", name: "read", arguments: %{}}
    r1 = Message.tool_result(c1, {:ok, "one"})
    r2 = Message.tool_result(c2, {:ok, "two"})

    vm =
      fold([
        {:tool_execution_start, %{tool_call: c1}},
        tool_end(r1),
        {:tool_execution_start, %{tool_call: c2}},
        tool_end(r2)
      ])

    assert vm.cells == [
             {:tool, c1, ViewModel.call_line(c1), r1},
             {:tool, c2, ViewModel.call_line(c2), r2}
           ]
  end

  test "a result goes to the oldest open cell and never replaces a result" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    first = Message.tool_result(call, {:ok, "first"})
    second = Message.tool_result(call, {:ok, "second"})
    start = {:tool_execution_start, %{tool_call: call}}

    # A provider can use the same id again in a later turn.
    assert fold([start, tool_end(first), start, tool_end(second)]).cells ==
             [
               {:tool, call, ViewModel.call_line(call), first},
               {:tool, call, ViewModel.call_line(call), second}
             ]

    # A second result for a closed cell changes nothing.
    assert fold([start, tool_end(first), tool_end(second)]).cells == [
             {:tool, call, ViewModel.call_line(call), first}
           ]

    # Two open cells with one id: the first result answers the first call,
    # the rule of the session's transcript.
    assert fold([start, start, tool_end(second)]).cells ==
             [
               {:tool, call, ViewModel.call_line(call), second},
               {:tool, call, ViewModel.call_line(call), nil}
             ]
  end

  test "a result for an unknown call changes nothing" do
    call = %Message.ToolCall{id: "c9", name: "bash", arguments: %{}}
    result = Message.tool_result(call, {:error, "aborted"})

    vm = fold([{:agent_start, %{}}, tool_end(result)])
    assert vm.cells == []

    # Also with cells, none of them an open tool cell for that id.
    other = %Message.ToolCall{id: "c1", name: "bash", arguments: %{}}
    specs = [{:message_end, %{message: user("hi")}}, {:tool_execution_start, %{tool_call: other}}]
    assert fold(specs ++ [tool_end(result)]).cells == fold(specs).cells
  end

  test "a result for a call that never started gets a closed cell, as in a snapshot" do
    a = %Message.ToolCall{id: "t", name: "bash", arguments: %{"n" => "a"}}
    b = %Message.ToolCall{id: "t", name: "bash", arguments: %{"n" => "b"}}
    ra = Message.tool_result(a, {:ok, "a"})
    rb = Message.tool_result(b, {:error, "aborted"})

    vm =
      fold([
        {:message_end, %{message: assistant([a, b], :tool_use)}},
        {:tool_execution_start, %{tool_call: a}},
        {:notice, %{text: "during the run"}},
        tool_end(ra),
        tool_end(rb),
        # No call with that id is left: no cell.
        tool_end(rb)
      ])

    assert [
             %Message{},
             {:tool, ^a, _, ^ra},
             {:notice, _},
             {:tool, ^b, line, ^rb}
           ] = vm.cells

    assert line == ViewModel.call_line(b)
  end

  test "an aborted turn closes the stream and shows a notice" do
    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:message_start, %{message: assistant([])}},
        {:message_update, %{text_delta: "so far"}},
        {:message_end,
         %{message: assistant([%Message.Text{text: "so far"}], :aborted), error: :aborted}},
        {:agent_end, %{stop_reason: :aborted}}
      ])

    refute vm.running?
    assert vm.streaming == nil
    assert [_user, %Message{stop_reason: :aborted}, {:notice, "aborted"}] = vm.cells
  end

  test "a failed turn shows the error" do
    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:agent_end, %{stop_reason: :error, error: :stream_ended}}
      ])

    refute vm.running?
    assert List.last(vm.cells) == {:notice, "error: :stream_ended"}
  end

  test "a tool call line of newlines is cut after they become ␤" do
    # A name and a key of newlines, each far over the cut: "␤" is 3 bytes
    # for 1, and neither is copied whole.
    lines = String.duplicate("\n", 1_000_000)
    call = %Message.ToolCall{id: "c", name: lines, arguments: %{lines => 1}}

    line = ViewModel.call_line(call)
    assert byte_size(line) in 8_190..8_192
    assert String.starts_with?(line, "⚙ ␤␤")
    refute line =~ "\n"
  end

  test "an error renders in at most 8,192 bytes, with no character cut in half" do
    # U+00A0 renders as `\u00A0`, three times its bytes; a nested term has
    # no total `inspect/1` limit; `{:xy, "` puts the cut inside an "é".
    nbsp = String.duplicate("\u00A0", 1_000)
    nested = Map.new(1..50, &{&1, String.duplicate("\e", 4_096)})

    for error <- [
          {:claude_code, nbsp, nbsp},
          {:bad_stream_event, nested},
          {:xy, String.duplicate("é", 5_000)}
        ] do
      vm = fold([{:agent_end, %{stop_reason: :error, error: error}}])
      assert {:notice, "error: " <> text} = List.last(vm.cells)
      assert byte_size(text) in 8_190..8_192
      assert String.valid?(text)
    end
  end

  test "an error text with a control or invalid byte renders as text, not as bytes" do
    # perl's warnings quote the environment as raw bytes (#141).
    for text <- ["perl \x01 byte", "perl \u0085 byte", "perl \xE9 byte"] do
      vm = fold([{:agent_end, %{stop_reason: :error, error: {:not_started, text}}}])
      assert {:notice, "error: {:not_started, \"perl " <> _} = List.last(vm.cells)
    end
  end

  test "queue updates change the counts, including the nil-turn drain" do
    vm =
      fold([
        {:agent_start, %{}},
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

  test "agent_end with an open stream and no message_end still closes it" do
    vm =
      fold([
        {:agent_start, %{}},
        {:turn_start, %{}},
        {:message_end, %{message: user("hi")}},
        {:agent_end, %{stop_reason: :error, error: :boom}}
      ])

    assert vm.streaming == nil
  end

  test "an event of an unknown type leaves the view model unchanged (ADR 0006, section 5)" do
    vm = fold([{:agent_start, %{}}, {:message_start, %{message: assistant([])}}])

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

  # A value from a newer Core in a known event type (ADR 0006, section 5).
  defmodule NewBlock do
    @moduledoc false
    defstruct [:data]
  end

  test "a message_update with a new data key leaves the view model unchanged" do
    vm = fold([{:agent_start, %{}}, {:message_start, %{message: assistant([])}}])

    update = %Event{
      type: :message_update,
      session_id: "s",
      instance_id: "i",
      turn_id: "t",
      seq: 3,
      data: %{signature_delta: "x"}
    }

    assert ViewModel.apply(vm, update) == %{vm | seq: 3}
  end

  test "a message_start or a message_end with a new role leaves the view model unchanged" do
    vm = fold([{:agent_start, %{}}])
    message = %Message{role: :from_a_newer_core, content: [%Message.Text{text: "x"}]}

    for {type, seq} <- [message_start: 2, message_end: 3] do
      event = %Event{
        type: type,
        session_id: "s",
        instance_id: "i",
        turn_id: "t",
        seq: seq,
        data: %{message: message}
      }

      assert ViewModel.apply(vm, event) == %{vm | seq: seq}
    end
  end

  test "a new block kind in an assistant message is dropped, so it never reaches the screen" do
    vm =
      fold([
        {:message_start, %{message: assistant([])}},
        {:message_end, %{message: assistant([%NewBlock{data: 1}, %Message.Text{text: "hi"}])}}
      ])

    assert [%Message{content: [%Message.Text{text: "hi"}]}] = vm.cells
    assert Helyx.TUI.transcript_lines(vm, 80) != []
  end

  test "a snapshot partial of a new role does not show" do
    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 1,
      messages: [],
      turn: %{id: "t", partial: %Message{role: :from_a_newer_core, content: []}, running: []},
      model: "test/model",
      queue: %{steers: 0, follow_ups: 0}
    }

    assert ViewModel.from_snapshot(snapshot).streaming == nil
  end

  test "a snapshot drops a message of a new role and a new block kind" do
    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 4,
      messages: [
        user("hi"),
        %Message{role: :from_a_newer_core, content: []},
        assistant([%NewBlock{data: 1}, %Message.Text{text: "done"}])
      ],
      turn: %{
        id: "t",
        partial: assistant([%NewBlock{data: 2}, %Message.Text{text: "more"}]),
        running: []
      },
      model: "test/model",
      queue: %{steers: 0, follow_ups: 0}
    }

    vm = ViewModel.from_snapshot(snapshot)

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "done"}]}] = vm.cells
    assert vm.streaming == [%Message.Text{text: "more"}]
    assert Helyx.TUI.transcript_lines(vm, 80) != []
  end

  test "a known type with a missing required field still crashes" do
    event = %Event{
      type: :message_start,
      session_id: "s",
      instance_id: "i",
      turn_id: "t",
      seq: 1,
      data: %{}
    }

    assert_raise FunctionClauseError, fn -> ViewModel.apply(new(), event) end
  end

  test "an agent_end with the stop reason error and no error field crashes" do
    event = %Event{
      type: :agent_end,
      session_id: "s",
      instance_id: "i",
      turn_id: "t",
      seq: 1,
      data: %{stop_reason: :error}
    }

    assert_raise CaseClauseError, fn -> ViewModel.apply(new(), event) end
  end

  test "a message_update with a known delta key of another type, or two known keys, crashes" do
    vm = fold([{:message_start, %{message: assistant([])}}])

    for data <- [
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

  test "the deltas of a message of a new role do not show" do
    message = %Message{role: :from_a_newer_core, content: []}

    vm =
      fold([
        {:message_start, %{message: message}},
        {:message_update, %{text_delta: "hidden"}},
        {:message_end, %{message: message}}
      ])

    assert vm.streaming == nil
    assert vm.cells == []
  end

  test "an event of another instance leaves the view model unchanged (#204)" do
    vm = fold([{:agent_start, %{}}, {:message_start, %{message: assistant([])}}])

    [update] = events(message_update: %{text_delta: "old"})

    for seq <- [1, 3] do
      other = %{update | instance_id: "other", seq: seq}
      assert ViewModel.apply(vm, other) == vm
    end
  end

  test "a model change updates the model" do
    vm = fold(model_change: %{model: "other/model"})
    assert vm.model == "other/model"
  end

  test "a harness session shows a notice when the harness lost its session or got a cut transcript" do
    fresh = %{provider: "claude-code", harness_session_id: "s", lost: false, cut: 0}
    assert fold(harness_session: fresh).cells == []

    assert fold(harness_session: %{fresh | lost: true, cut: 4}).cells == [
             {:notice, "claude-code lost its own session; a fresh one got the transcript"},
             {:notice, "claude-code got the transcript without its 4 oldest messages"}
           ]
  end

  test "an unconfirmed steer shows a notice with its text" do
    assert fold(steer_unconfirmed: %{text: "more"}).cells == [
             {:notice, "the steer was not confirmed; send it again if needed: more"}
           ]
  end

  test "a provider notice shows its text" do
    assert fold(notice: %{text: "claude-code: the error before the steer: boom"}).cells == [
             {:notice, "claude-code: the error before the steer: boom"}
           ]
  end

  test "a reject sets the reason, events keep it, and clear_reason/1 removes it" do
    vm = new()
    assert vm.reason == nil

    vm = ViewModel.reject(vm, "not sent: the queue is full")
    assert vm.reason == "not sent: the queue is full"
    assert vm.cells == []

    # A session event does not clear the reason; the TUI does, on a key press or a paste.
    [event] = events([{:queue_update, %{steers: 1, follow_ups: 0}}])
    kept = ViewModel.apply(vm, event)
    assert kept.reason == "not sent: the queue is full"

    assert ViewModel.clear_reason(kept).reason == nil
  end

  test "a client notice joins the cells" do
    vm = ViewModel.notice(ViewModel.new("test/model"), "unknown provider: x")
    assert vm.cells == [{:notice, "unknown provider: x"}]
  end
end
