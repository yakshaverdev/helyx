defmodule Helyx.TUI.Wire.DecodeTest do
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message}
  alias Helyx.Message.{Text, Thinking, ToolCall}
  alias Helyx.Session.File.Scan
  alias Helyx.Session.{Snapshot, Totals}
  alias Helyx.Transport.WebSocket.Wire
  alias Helyx.TUI.{Footer, ViewModel}
  alias Helyx.TUI.Wire.Decode

  @call %ToolCall{id: "c1", name: "bash", arguments: %{"command" => "ls", "n" => [1, 2.5]}}
  @usage %Helyx.Usage{
    input: 1,
    output: 2,
    cache_read: 3,
    cache_write: 4,
    cost: 0.5,
    cost_kind: :list,
    context_tokens: 10,
    context_window: 100
  }
  @queue %{steers: 1, follow_ups: 2, running: 3, held: 4, waiting: 5}
  @ask %{ask_id: "k1", call_id: "c1", tool: "question", request: %{"questions" => [%{"a" => 1}]}}

  defp user(text), do: Message.user(text, %{kind: :user, id: nil})

  defp assistant do
    %Message{
      role: :assistant,
      id: "a1",
      content: [%Text{text: "é"}, %Thinking{thinking: "t"}, @call],
      model: "fake/echo",
      stop_reason: :tool_use,
      usage: @usage
    }
  end

  defp partial, do: %Message{role: :assistant, id: "a2", content: [%Text{text: "par"}]}
  defp result, do: %{Message.tool_result(@call, {:error, "no"}) | id: "r1"}

  defp event(type, data, turn_id \\ "t1"),
    do: %Event{
      type: type,
      session_id: "s1",
      instance_id: "i1",
      turn_id: turn_id,
      seq: 7,
      data: data
    }

  # The wire JSON of a value of the server, as a client reads it.
  defp wire(value), do: value |> JSON.encode!() |> JSON.decode!()

  # The decode of the subscribe result that has `snapshot`.
  defp subscribe(snapshot) do
    Decode.result("subscribe", %{
      "ok" => true,
      "result" => %{"sub" => "1", "snapshot" => wire(Wire.snapshot(snapshot))}
    })
  end

  test "each event of Core decodes from its wire form as it was" do
    dropped = user("q1")
    unconfirmed = user("s1")

    events = [
      event(:turn_start, %{}),
      event(:turn_start, %{origin: :provider}),
      event(:turn_start, %{origin: :compaction}),
      event(:message_start, %{message: user("hi")}),
      event(:message_start, %{message: Message.user("p", %{kind: :product, id: "job-1"})}),
      event(:message_update, %{text_delta: "a"}),
      event(:message_update, %{thinking_delta: "b"}),
      event(:message_update, %{tool_call: @call}),
      event(:message_end, %{message: assistant()}),
      event(:message_end, %{message: %{partial() | stop_reason: :aborted}, error: :aborted}),
      event(:message_end, %{message: %{partial() | stop_reason: :error}, error: "aborted"}),
      event(:tool_execution_end, %{message: result()}),
      event(:turn_end, %{outcome: :done}),
      event(:turn_end, %{outcome: :aborted}),
      event(:turn_end, %{outcome: :error, error: "boom"}),
      event(:queue_update, @queue, nil),
      event(:queue_dropped, %{texts: ["q1"], messages: [dropped]}, nil),
      event(:model_change, %{model: "fake/echo"}, nil),
      event(:resume_id, %{provider: "claude", resume_id: "r", lost: true, cut: 2}),
      event(:steer_unconfirmed, %{text: "s1", message: unconfirmed}),
      event(:compaction, %{trigger: :auto, tokens_before: nil, tokens_after: 5}),
      event(:compaction, %{trigger: :manual, tokens_before: 9, tokens_after: nil}),
      event(:notice, %{text: "n"}),
      event(:ask, @ask),
      event(:ask_end, %{ask_id: "k1", outcome: :answered}),
      event(:ask_end, %{ask_id: "k1", outcome: :ended})
    ]

    for event <- events do
      assert Decode.event(wire(Wire.event(event))) == {:ok, event}
    end
  end

  test "a user message of a file from before #649 keeps its unknown origin" do
    old = %Message{role: :user, id: "u0", origin: %{kind: :unknown, id: nil}, content: []}
    event = event(:message_end, %{message: old})
    assert %{"origin" => %{"kind" => "unknown", "id" => nil}} = wire(Wire.value(old))
    assert Decode.event(wire(Wire.event(event))) == {:ok, event}
  end

  test "an unknown event type is nil, and an unknown key is ignored" do
    notice = wire(Wire.event(event(:notice, %{text: "n"})))
    assert Decode.event(%{notice | "type" => "future"}) == {:ok, nil}

    extra = notice |> Map.put("x", 1) |> put_in(["data", "y"], [1])
    assert Decode.event(extra) == {:ok, event(:notice, %{text: "n"})}
  end

  test "a known event type with a broken shape is an error" do
    start = wire(Wire.event(event(:message_start, %{message: user("hi")})))
    update = wire(Wire.event(event(:message_update, %{text_delta: "a"})))
    turn_end = wire(Wire.event(event(:turn_end, %{outcome: :done})))

    for broken <- [
          %{start | "data" => %{}},
          put_in(start, ["data", "message", "role"], "system"),
          put_in(start, ["data", "message", "id"], 1),
          put_in(update, ["data", "thinking_delta"], "b"),
          put_in(update, ["data", "text_delta"], 1),
          put_in(turn_end, ["data", "outcome"], "maybe"),
          %{turn_end | "seq" => -1},
          %{turn_end | "data" => []},
          # A role that the fold does not take for the event.
          wire(Wire.event(event(:tool_execution_end, %{message: assistant()}))),
          wire(Wire.event(event(:queue_dropped, %{texts: ["p"], messages: [partial()]}))),
          wire(Wire.event(event(:steer_unconfirmed, %{text: "", message: result()}))),
          Map.delete(turn_end, "instance_id"),
          "event"
        ] do
      assert Decode.event(broken) == :error, inspect(broken)
    end
  end

  test "a snapshot decodes from its wire form as it was" do
    snapshot = %Snapshot{
      instance_id: "i1",
      seq: 3,
      messages: [user("hi"), assistant(), result()],
      more: true,
      turn: %{id: "t1", partial: partial(), elapsed_ms: 12},
      model: "fake/echo",
      queue: @queue,
      persisting: false,
      usage: %Totals{input: 1, output: 2, cache_read: 3, cache_write: 4, cost: 0.5, unknown: true},
      context: %{tokens: 10, window: 100, model: "m", bytes: 4},
      asks: [@ask]
    }

    empty = %{snapshot | messages: [], more: false, turn: nil, context: nil, asks: []}

    for snapshot <- [
          snapshot,
          empty,
          %{snapshot | turn: %{id: "t1", partial: nil, elapsed_ms: 0}}
        ] do
      assert subscribe(snapshot) == {:ok, {:ok, snapshot, "1"}}
    end
  end

  test "the results and the errors of the operations" do
    ok = &ok_res/1
    error = &%{"ok" => false, "error" => %{"code" => &1, "text" => "the text"}}
    summary = %Scan.Summary{id: "s1", cwd: "/w", model: "fake/echo", mtime: 5, prompt: "hi"}
    replay = [event(:notice, %{text: "n"})]
    future = %{wire(Wire.event(event(:notice, %{text: "f"}))) | "type" => "future"}

    for {op, res, result} <- [
          {"steer", ok.(%{}), :ok},
          {"abort", ok.(%{"x" => 1}), :ok},
          {"start", ok.(%{"session" => "s1"}), {:ok, "s1"}},
          {"resume", ok.(%{"session" => "s1"}), {:ok, "s1"}},
          {"sessions.saved", ok.(%{"items" => [wire(Map.from_struct(summary))], "next" => "n"}),
           {:ok, [summary], "n"}},
          {"sessions.saved", ok.(%{"items" => [], "next" => nil}), {:ok, [], nil}},
          {"subscribe", ok.(%{"sub" => "2", "replay" => [wire(Wire.event(hd(replay))), future]}),
           {:ok, {:replay, replay}, "2"}},
          {"steer", error.("queue_full"), {:error, :queue_full}},
          {"set_model", error.("unknown_provider"), {:error, {:unknown_provider, "the text"}}},
          {"set_model", error.("invalid_model_ref"), {:error, {:invalid_model_ref, "the text"}}},
          {"start", error.("start_failed"), {:error, {:start_failed, "the text"}}},
          {"answer", error.("not_waiting"), {:error, :not_waiting}}
        ] do
      assert Decode.result(op, res) == {:ok, result}, op
    end

    for {op, res} <- [
          {"steer", error.("no_such_code")},
          {"start", ok.(%{})},
          {"subscribe", ok.(%{"sub" => 2, "replay" => []})},
          {"sessions.saved", ok.(%{"items" => [%{"id" => "s1"}], "next" => nil})},
          {"steer", %{"ok" => true, "result" => []}},
          {"steer", %{"ok" => "yes"}}
        ] do
      assert Decode.result(op, res) == :error, inspect(res)
    end
  end

  test "a partial of the turn is nil or an assistant message, and a tool call holds no integer over 100 digits" do
    turn = %{id: "t1", partial: nil, elapsed_ms: 0}
    wire = wire(Wire.snapshot(%{snapshot_of([]) | turn: turn}))

    for partial <- [false, wire(Wire.value(user("hi"))), "partial"] do
      res = %{
        "ok" => true,
        "result" => %{"sub" => "1", "snapshot" => put_in(wire["turn"]["partial"], partial)}
      }

      assert Decode.result("subscribe", res) == :error, inspect(partial)
    end

    at = %{"n" => 10 ** 100 - 1}
    update = &wire(Wire.event(event(:message_update, %{tool_call: %{@call | arguments: &1}})))
    assert {:ok, %Event{data: %{tool_call: %{arguments: ^at}}}} = Decode.event(update.(at))
    assert Decode.event(update.(%{"n" => [10 ** 100]})) == :error
  end

  # A message_end whose wire message is `fields` over the wire form of
  # `message`.
  defp message_end(message, fields) do
    end_ = wire(Wire.event(event(:message_end, %{message: message})))
    update_in(end_, ["data", "message"], &Map.merge(&1, fields))
  end

  test "a message is checked strictly against the schema: the file decoder repairs none on the wire" do
    for fields <- [
          %{"content" => %{}},
          %{"content" => "text"},
          %{"usage" => "bad"},
          %{"usage" => %{}},
          %{"usage" => %{"input" => 1, "output" => 2, "cache_read" => 3}},
          %{"usage" => %{"input" => -1, "output" => 2, "cache_read" => 3, "cache_write" => 4}},
          %{"usage" => Map.delete(wire(Wire.value(@usage)), "cost_kind")},
          %{"usage" => %{wire(Wire.value(@usage)) | "cost_kind" => "free"}},
          %{"stop_reason" => 42},
          %{"stop_reason" => "done"},
          %{"model" => 1},
          %{"tool_name" => false},
          %{"is_error" => "no"},
          %{"origin" => %{"kind" => "user", "id" => nil}},
          %{"content" => [%{"type" => "image", "data" => ""}]},
          %{"content" => [%{"type" => "text", "text" => 1}]},
          %{"content" => List.duplicate(%{"type" => "text", "text" => "t"}, 1_025)}
        ] do
      assert Decode.event(message_end(assistant(), fields)) == :error, inspect(fields)
    end

    for origin <- [
          %{"kind" => "product", "id" => ""},
          %{"kind" => "user", "id" => "u"},
          %{"kind" => "unknown", "id" => "u"},
          %{"kind" => "robot", "id" => nil},
          "user"
        ] do
      assert Decode.event(message_end(user("hi"), %{"origin" => origin})) == :error
    end

    blocks = List.duplicate(%Text{text: "t"}, 1_024)
    many = %{assistant() | content: blocks}
    assert {:ok, %Event{}} = Decode.event(message_end(many, %{}))

    # The text of a tool result at the cut of Core, and one byte over it.
    at = String.duplicate("é", div(Message.max_result_bytes(), 2))
    result = &event(:tool_execution_end, %{message: %{result() | content: [%Text{text: &1}]}})
    assert Decode.event(wire(Wire.event(result.(at)))) == {:ok, result.(at)}
    assert Decode.event(wire(Wire.event(result.(at <> "x")))) == :error
  end

  test "a missing optional key is nil or false, and the unknown usage is the usage of Core" do
    bare = %Message{role: :user, id: "u1", content: [%Text{text: "hi"}]}
    unknown = %{assistant() | usage: %Helyx.Usage{}}

    for message <- [bare, unknown, %{partial() | model: nil}] do
      event = event(:message_end, %{message: message})
      assert Decode.event(wire(Wire.event(event))) == {:ok, event}
    end
  end

  test "an object in place of a list of the schema is an error" do
    replay = ok_res(%{"sub" => "1", "replay" => %{}})
    saved = ok_res(%{"items" => %{}, "next" => nil})
    assert Decode.result("subscribe", replay) == :error
    assert Decode.result("sessions.saved", saved) == :error

    snapshot = wire(Wire.snapshot(snapshot_of([])))

    for key <- ["messages", "asks"] do
      res = ok_res(%{"sub" => "1", "snapshot" => %{snapshot | key => %{}}})
      assert Decode.result("subscribe", res) == :error, key
    end
  end

  defp ok_res(result), do: %{"ok" => true, "result" => result}

  defp snapshot_of(messages) do
    %Snapshot{
      instance_id: "i1",
      seq: 0,
      messages: messages,
      more: false,
      turn: nil,
      model: "fake/echo",
      queue: @queue,
      persisting: true,
      usage: %Totals{},
      context: nil
    }
  end

  test "the bounds of Core that the fold trusts" do
    compaction =
      &wire(
        Wire.event(event(:compaction, %{trigger: :auto, tokens_before: &1, tokens_after: nil}))
      )

    assert {:ok, %Event{}} = Decode.event(compaction.(1_000_000_000))
    assert Decode.event(compaction.(1_000_000_001)) == :error

    model = &wire(Wire.event(event(:model_change, %{model: &1}, nil)))
    assert {:ok, %Event{}} = Decode.event(model.("p/" <> String.duplicate("m", 254)))
    assert Decode.event(model.("p/" <> String.duplicate("m", 255))) == :error
    assert Decode.event(model.("p/a b")) == :error

    no_call_id =
      wire(Wire.event(event(:tool_execution_end, %{message: %{result() | tool_call_id: nil}})))

    assert Decode.event(no_call_id) == :error

    # Two messages at the cost bound of one usage give a total of 2 × 10^12.
    usage = %{@usage | cost: 1.0e12, cost_kind: :billed}
    costly = [%{assistant() | id: "a1", usage: usage}, %{assistant() | id: "a3", usage: usage}]
    {totals, context} = Totals.of(costly)
    assert totals.cost == 2.0e12
    real = %{snapshot_of(costly) | usage: totals, context: context}
    assert subscribe(real) == {:ok, {:ok, real, "1"}}

    # The cap, the first float over it, and an integer at it and over it.
    at = %{snapshot_of([]) | usage: %Totals{cost: 1.0e300}}
    assert subscribe(at) == {:ok, {:ok, at, "1"}}
    <<bits::64>> = <<1.0e300::float>>
    <<over::float>> = <<bits + 1::64>>
    assert subscribe(%{at | usage: %Totals{cost: over}}) == :error
    whole = %{at | usage: %Totals{cost: trunc(1.0e300)}}
    assert subscribe(whole) == {:ok, {:ok, whole, "1"}}
    assert subscribe(%{at | usage: %Totals{cost: trunc(1.0e300) + 1}}) == :error

    # The footer draws the capped form at the cap, after a later message too.
    vm = ViewModel.from_snapshot(at)
    later = event(:message_end, %{message: %{assistant() | usage: usage}})

    for vm <- [vm, ViewModel.apply(vm, later)] do
      %{text: [_row1, %{spans: spans}]} = Footer.widget("~", vm, nil, nil, nil)
      assert Enum.map_join(spans, & &1.content) =~ ">$99999"
    end

    assert subscribe(%{at | model: "no-slash"}) == :error
    # A result with no call before it in the snapshot.
    assert subscribe(snapshot_of([result()])) == :error
    paired = snapshot_of([assistant(), result()])
    assert subscribe(paired) == {:ok, {:ok, paired, "1"}}
  end
end
