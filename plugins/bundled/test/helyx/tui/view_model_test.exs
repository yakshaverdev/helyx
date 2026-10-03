defmodule Helyx.TUI.ViewModelTest do
  # The event fold, driven by scripted event lists, as the ticket requires.
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message}
  alias Helyx.TUI.ViewModel

  import Helyx.Test.TUIRender, only: [texts: 1, view_model: 2]

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

    assert [%Message{role: :user}, %Message{role: :assistant} = done, {:tool, ^call, _, nil}] =
             cells(vm)

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

  # The cells of an assistant message: the message, then an open cell for
  # each call.
  defp calls_end(calls), do: {:message_end, %{message: assistant(calls, :tool_use)}}

  defp open(call), do: {:tool, call, ViewModel.call_line(call), nil}
  defp closed(call, result), do: {:tool, call, ViewModel.call_line(call), result}

  test "a call gets an open cell from its message, and its result closes it" do
    call = %Message.ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
    result = Message.tool_result(call, {:ok, "lib\ntest"})
    head = [{:agent_start, %{}}, {:turn_start, %{}}, {:message_end, %{message: user("hi")}}]

    # The start event changes no cell.
    open_vm = fold(head ++ [calls_end([call])])
    assert List.last(cells(open_vm)) == open(call)

    assert cells(fold(head ++ [calls_end([call]), {:tool_execution_start, %{tool_call: call}}])) ==
             cells(open_vm)

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
    assert ["› hi", "Listing.", "⚙ bash command=\"ls\"", "… awaiting result"] == texts(streaming)

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

    assert_raise KeyError, fn -> fold([{:agent_start, %{}}, tool_end(unknown)]) end
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
      queue: %{steers: 0, follow_ups: 0}
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
    assert [_user, %Message{stop_reason: :aborted}, {:notice, "aborted"}] = cells(vm)
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
    assert List.last(cells(vm)) == {:notice, "error: :stream_ended"}
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
      assert {:notice, "error: " <> text} = List.last(cells(vm))
      assert byte_size(text) in 8_190..8_192
      assert String.valid?(text)
    end
  end

  test "an error text with a control or invalid byte renders as text, not as bytes" do
    # perl's warnings quote the environment as raw bytes (#141).
    for text <- ["perl \x01 byte", "perl \u0085 byte", "perl \xE9 byte"] do
      vm = fold([{:agent_end, %{stop_reason: :error, error: {:not_started, text}}}])
      assert {:notice, "error: {:not_started, \"perl " <> _} = List.last(cells(vm))
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

  test "an event of an unknown type leaves the view model unchanged" do
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

  # A value from a newer Core in a known event type.
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

    assert ViewModel.apply(vm, update) == vm
  end

  test "a message_start or a message_end with a new role leaves the view model unchanged" do
    vm = fold([{:agent_start, %{}}])
    message = %Message{role: :from_a_newer_core, content: [%Message.Text{text: "x"}]}

    for type <- [:message_start, :message_end] do
      event = %Event{
        type: type,
        session_id: "s",
        instance_id: "i",
        turn_id: "t",
        seq: 2,
        data: %{message: message}
      }

      assert ViewModel.apply(vm, event) == vm
    end
  end

  test "an image and a new block kind show a placeholder" do
    image = %Message.Image{mime_type: "image/png", data: "AAAA"}

    vm =
      fold([
        {:message_start, %{message: assistant([])}},
        {:message_end,
         %{message: assistant([image, %NewBlock{data: 1}, %Message.Text{text: "hi"}])}}
      ])

    assert ["[unsupported block: image]", "[unsupported block: new_block]", "hi"] == texts(vm)
  end

  # The session file decodes an image block for every role.
  test "an image in a user message or a tool result shows a placeholder" do
    image = %Message.Image{mime_type: "image/png", data: "AAAA"}
    call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}
    result = %{Message.tool_result(call, {:ok, "x"}) | content: [image]}

    snapshot = %Helyx.Session.Snapshot{
      instance_id: "i",
      seq: 3,
      messages: [
        %Message{role: :user, content: [%Message.Text{text: "see "}, image]},
        assistant([call], :tool_use),
        result
      ],
      turn: nil,
      model: "test/model",
      queue: %{steers: 0, follow_ups: 0}
    }

    assert ["› see [unsupported block: image]", "⚙ read", "  [unsupported block: image]"] ==
             texts(ViewModel.from_snapshot(snapshot))
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

  test "a snapshot drops a message of a new role and keeps a new block kind" do
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

    assert [%Message{role: :user}, %Message{role: :assistant}] = cells(vm)
    assert vm.streaming == [%Message.Text{text: "more"}, %NewBlock{data: 2}]

    assert ["› hi", "[unsupported block: new_block]", "done"] ++
             ["[unsupported block: new_block]", "more"] == texts(vm)
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

    assert_raise MatchError, fn -> ViewModel.apply(new(), event) end
  end

  # Each known type that the TUI reads matches the type only, so a broken
  # payload reaches its clause and crashes; it never reaches the clause that
  # ignores an unknown type.
  test "every known type with a broken payload crashes" do
    for {type, data} <- [
          agent_end: %{},
          message_start: %{message: "not a message"},
          message_end: %{},
          tool_execution_end: %{message: Message.user("not a result")},
          queue_update: %{steers: 1},
          model_change: %{},
          notice: %{},
          steer_unconfirmed: %{},
          provider_session: %{provider: "p"}
        ] do
      [event] = events([{type, data}])
      assert catch_error(ViewModel.apply(new(), event)), inspect(type)
    end
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
    assert cells(vm) == []
  end

  test "a model change updates the model" do
    vm = fold(model_change: %{model: "other/model"})
    assert vm.model == "other/model"
  end

  test "a provider session shows a notice when the provider lost its session or got a cut transcript" do
    fresh = %{provider: "claude-code", resume_id: "s", lost: false, cut: 0}
    assert cells(fold(provider_session: fresh)) == []

    assert cells(fold(provider_session: %{fresh | lost: true, cut: 4})) == [
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

  test "a reject sets the reason, events keep it, and clear_reason/1 removes it" do
    vm = new()
    assert vm.reason == nil

    vm = ViewModel.reject(vm, "not sent: the queue is full")
    assert vm.reason == "not sent: the queue is full"
    assert cells(vm) == []

    # A session event does not clear the reason; the TUI does, on a key press or a paste.
    [event] = events([{:queue_update, %{steers: 1, follow_ups: 0}}])
    kept = ViewModel.apply(vm, event)
    assert kept.reason == "not sent: the queue is full"

    assert ViewModel.clear_reason(kept).reason == nil
  end

  test "a client notice joins the cells" do
    vm = ViewModel.notice(new(), "unknown provider: x")
    assert cells(vm) == [{:notice, "unknown provider: x"}]
  end
end
