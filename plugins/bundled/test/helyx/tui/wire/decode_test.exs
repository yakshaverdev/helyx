defmodule Helyx.TUI.Wire.DecodeTest do
  use ExUnit.Case, async: true

  alias Helyx.{Event, Message}
  alias Helyx.Message.{Text, Thinking, ToolCall}
  alias Helyx.Session.File.Scan
  alias Helyx.Session.{Snapshot, Totals}
  alias Helyx.Transport.WebSocket.Wire
  alias Helyx.TUI.{CallLine, Footer, Link, ViewModel}
  alias Helyx.TUI.Transcript.Item
  alias Helyx.TUI.ViewModel.Cut
  alias Helyx.TUI.Wire.Decode

  require Link

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
      event(:message_start, %{message: Message.user("h", %{kind: :hook, id: "Acme.Hook"})}),
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
      event(:queue_dropped, %{messages: [dropped]}, nil),
      event(:model_change, %{model: "fake/echo"}, nil),
      event(:resume_id, %{provider: "claude", resume_id: "r", lost: true, cut: 2}),
      event(:steer_unconfirmed, %{message: unconfirmed}),
      event(:compaction, %{trigger: :auto, tokens_before: nil, tokens_after: 5}),
      event(:compaction, %{trigger: :manual, tokens_before: 9, tokens_after: nil}),
      event(:notice, %{text: "n"}),
      event(:ask, @ask),
      event(:ask_end, %{ask_id: "k1", outcome: :answered}),
      event(:ask_end, %{ask_id: "k1", outcome: :ended}),
      event(:tools_change, %{activated: ["fs__read", "fs__write"]}),
      event(:tools_change, %{activated: []}, nil)
    ]

    for event <- events do
      assert Decode.event(wire(Wire.event(event))) == {:ok, event}
    end
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
          wire(Wire.event(event(:queue_dropped, %{messages: [partial()]}))),
          wire(Wire.event(event(:steer_unconfirmed, %{message: result()}))),
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
      turn: %{id: "t1", partial: partial(), elapsed_ms: 12},
      model: "fake/echo",
      queue: @queue,
      persisting: false,
      usage: %Totals{input: 1, output: 2, cache_read: 3, cache_write: 4, cost: 0.5, unknown: true},
      context: %{tokens: 10, window: 100, model: "m", bytes: 4},
      asks: [@ask],
      activated: ["fs__read"]
    }

    empty = %{
      snapshot
      | messages: [],
        turn: nil,
        context: nil,
        asks: [],
        activated: []
    }

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

    live = %{id: "s1", instance_id: "i1", cwd: "/w", model: "fake/echo", status: :running}
    wire_live = %{live | status: "running"}

    for {op, res, result} <- [
          {"steer", ok.(%{}), :ok},
          {"abort", ok.(%{"x" => 1}), :ok},
          {"start", ok.(%{"session" => "s1"}), {:ok, "s1"}},
          {"resume", ok.(%{"session" => "s1"}), {:ok, "s1"}},
          {"sessions.saved", ok.(%{"items" => [wire(Map.from_struct(summary))], "next" => "n"}),
           {:ok, [summary], "n"}},
          {"sessions.saved", ok.(%{"items" => [], "next" => nil}), {:ok, [], nil}},
          {"sessions.live", ok.(%{"sessions" => [wire(wire_live)]}), {:ok, [live]}},
          {"sessions.live", ok.(%{"sessions" => []}), {:ok, []}},
          {"stop", ok.(%{}), :ok},
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
          {"sessions.live", ok.(%{})},
          {"sessions.live", ok.(%{"sessions" => [Map.delete(wire_live, :cwd)]})},
          {"sessions.live", ok.(%{"sessions" => [%{wire_live | status: "gone"}]})},
          {"steer", %{"ok" => true, "result" => []}},
          {"steer", %{"ok" => "yes"}}
        ] do
      assert Decode.result(op, res) == :error, inspect(res)
    end

    # The codes of a Hub are codes of the schema (protocols 6 and 7); each
    # has a text of the footer, at most 27 bytes.
    for code <-
          ~w(forbidden too_many_records too_many_projects unknown_project unknown_token
             too_many_schedules unknown_schedule)a do
      assert Decode.result("steer", error.(Atom.to_string(code))) == {:ok, {:error, code}}
      assert Link.wire_error?(code) and byte_size(Link.error_text(code)) <= 27
    end
  end

  test "a partial of the turn is nil or an assistant message, and a tool call holds an integer of any size" do
    turn = %{id: "t1", partial: nil, elapsed_ms: 0}
    wire = wire(Wire.snapshot(%{snapshot_of([]) | turn: turn}))

    for partial <- [false, wire(Wire.value(user("hi"))), "partial"] do
      res = %{
        "ok" => true,
        "result" => %{"sub" => "1", "snapshot" => put_in(wire["turn"]["partial"], partial)}
      }

      assert Decode.result("subscribe", res) == :error, inspect(partial)
    end

    update = &wire(Wire.event(event(:message_update, %{tool_call: %{@call | arguments: &1}})))

    # The server caps an integer at 100 digits; the schema does not, and the
    # call line shows it as its text, within the cut of the line.
    for {args, n} <- [
          {%{"n" => 10 ** 100 - 1}, 10 ** 100 - 1},
          {%{"n" => [10 ** 100]}, 10 ** 100},
          {%{"n" => 10 ** 1_023}, 10 ** 1_023}
        ] do
      assert {:ok, %Event{data: %{tool_call: call}}} = Decode.event(update.(args))
      assert call.arguments == args
      line = CallLine.line(call)
      assert line =~ binary_part(Integer.to_string(n), 0, 90)
      assert byte_size(line) <= 8_192
    end
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
          %{"usage" => %{wire(Wire.value(@usage)) | "cost_kind" => "free"}},
          %{"usage" => %{wire(Wire.value(@usage)) | "cost" => -1}},
          %{"usage" => %{wire(Wire.value(@usage)) | "context_window" => 1.5}},
          %{"stop_reason" => 42},
          %{"stop_reason" => "done"},
          %{"model" => 1},
          %{"tool_name" => false},
          %{"is_error" => "no"},
          %{"origin" => %{"kind" => "user", "id" => 1}},
          %{"content" => [%{"type" => "image", "data" => ""}]},
          %{"content" => [%{"type" => "text", "text" => 1}]}
        ] do
      assert Decode.event(message_end(assistant(), fields)) == :error, inspect(fields)
    end

    for origin <- [%{"kind" => "robot", "id" => nil}, %{"kind" => "user"}, "user"] do
      assert Decode.event(message_end(user("hi"), %{"origin" => origin})) == :error
    end
  end

  test "a text for a person that becomes a notice is cut to the 4,000 bytes of an error text" do
    long = String.duplicate("é", 3_000)
    cut = Helyx.Reason.text(long)
    assert byte_size(cut) == 4_000

    for {type, data, path} <- [
          {:turn_end, %{outcome: :error, error: long}, [:error]},
          {:notice, %{text: long}, [:text]},
          {:resume_id, %{provider: long, resume_id: "r", lost: true, cut: 0}, [:provider]}
        ] do
      assert {:ok, %Event{data: decoded}} = Decode.event(wire(Wire.event(event(type, data))))
      assert get_in(decoded, path) == cut, inspect(type)
    end

    failed = message_end(assistant(), %{})
    failed = put_in(failed, ["data", "error"], %{"kind" => "failed", "text" => long})
    assert {:ok, %Event{data: %{error: ^cut}}} = Decode.event(failed)
  end

  test "a frame that the schema allows past the bounds of Core is taken, and drawn within the bounds of the TUI" do
    # An origin that Core does not make is dropped: the TUI shows none.
    for {message, origin, kept} <- [
          {user("hi"), %{"kind" => "product", "id" => ""}, nil},
          {user("hi"), %{"kind" => "user", "id" => "u"}, nil},
          {assistant(), %{"kind" => "user", "id" => nil}, nil},
          {result(), %{"kind" => "product", "id" => "p"}, nil}
        ] do
      fields = %{"origin" => origin}
      assert {:ok, %Event{data: %{message: decoded}}} = Decode.event(message_end(message, fields))
      assert decoded.origin == kept, inspect({message.role, origin})
    end

    # More blocks than Core makes: the cell keeps the first 1,024 and a cut
    # that counts the others but the calls, which have cells of their own;
    # a call past them still takes its result.
    call = %{@call | id: "c9"}
    texts = List.duplicate(%Text{text: "t"}, 1_026)
    many = %{assistant() | content: texts ++ [call]}
    assert {:ok, %Event{} = ended} = Decode.event(message_end(many, %{}))
    assert ended.data.message == many
    vm = ViewModel.apply(ViewModel.from_snapshot(snapshot_of([])), ended)
    closed = %{Message.tool_result(call, {:ok, "done"}) | id: "r9"}
    vm = ViewModel.apply(vm, %{event(:tool_execution_end, %{message: closed}) | seq: 8})
    assert [%Message{content: kept} = cell, {:tool, ^call, _line, ^closed}] = ViewModel.cells(vm)
    assert kept == Enum.take(texts, 1_024) ++ [%Cut{more: 2}]
    rows = Item.rows(cell, 40)
    assert {_line, {0, "[+2 more blocks]"}} = Enum.at(rows, -2)
    assert length(rows) == 1_024 + 2
    assert Item.search_text(cell) =~ ~r/t\n\[\+2 more blocks\]\z/

    # Only calls past the first 1,024: no cut line.
    calls = for n <- 1..3, do: %{@call | id: "x#{n}"}

    vm =
      ViewModel.apply(vm, %{ended | seq: 9, data: %{message: %{many | content: texts ++ calls}}})

    assert [_, _, %Message{content: kept} | _] = ViewModel.cells(vm)
    assert kept == Enum.take(texts, 1_024) ++ [%Cut{more: 2}]
    only_calls = %{many | id: "a5", content: Enum.take(texts, 1_024) ++ calls}
    vm = ViewModel.apply(vm, %{ended | seq: 10, data: %{message: only_calls}})
    assert %Message{content: content} = Enum.at(ViewModel.cells(vm), -4)
    assert content == Enum.take(texts, 1_024)

    # A user message and a tool result: the line ends their text.
    user = %{user("hi") | content: List.duplicate(%Text{text: "u"}, 1_025)}
    vm = ViewModel.apply(vm, %{event(:message_end, %{message: user}) | seq: 11})
    orphan = %{result() | id: "r8", tool_call_id: "none", content: user.content}
    vm = ViewModel.apply(vm, %{event(:tool_execution_end, %{message: orphan}) | seq: 12})
    [user_cell, {:tool, nil, _line, orphan_cell}] = vm |> ViewModel.cells() |> Enum.take(-2)
    assert Item.search_text(user_cell) == String.duplicate("u", 1_024) <> "\n[+1 more blocks]"
    assert Item.search_text({:tool, nil, "l", orphan_cell}) =~ ~r/u\n\[\+1 more blocks\]\z/

    # A delta with no message_start before it starts the message; the
    # streaming message draws its first 1,024 blocks and the cut.
    deltas =
      for {kind, n} <-
            Enum.with_index(Stream.cycle([:text_delta, :thinking_delta]) |> Enum.take(1_030)),
          do: %{event(:message_update, %{kind => "d"}) | seq: 13 + n}

    vm = Enum.reduce(deltas, vm, &ViewModel.apply(&2, &1))
    screen = Helyx.TUI.Transcript.screen(vm, nil, %ExRatatui.Layout.Rect{width: 40, height: 3})

    assert Enum.any?(screen, fn {_address, _line, {_column, text}} ->
             text == "[+6 more blocks]"
           end)

    # A text of a tool result over the cut of Core gets the cut, once.
    at = String.duplicate("é", div(Message.max_result_bytes(), 2))
    result = &event(:tool_execution_end, %{message: %{result() | content: [%Text{text: &1}]}})
    assert Decode.event(wire(Wire.event(result.(at)))) == {:ok, result.(at)}
    cut = Message.cut_result(at <> "x")
    assert Decode.event(wire(Wire.event(result.(at <> "x")))) == {:ok, result.(cut)}
    assert cut =~ ~r/\A\[cut to \d+ of 65537 bytes/

    # A model that is not a model ref: the fold keeps it whole, and the line
    # and the footer show at most 256 bytes of it, cleaned.
    model = "a model\e[2J" <> String.duplicate("m", 500)

    assert {:ok, changed} =
             Decode.event(wire(Wire.event(event(:model_change, %{model: model}, nil))))

    vm = ViewModel.apply(ViewModel.from_snapshot(snapshot_of([])), changed)
    assert vm.model == model
    assert [{:infos, ["model: " <> shown]}] = ViewModel.cells(vm)
    assert shown == Footer.model(model)
    assert byte_size(shown) == 256 and shown =~ ~r/\Aa model\?\[2Jm+\z/
    %{text: [_row1, %{spans: spans}]} = Footer.widget("~", vm, nil, nil, nil)
    assert Enum.map_join(spans, & &1.content) =~ shown
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

    for key <- ["messages", "asks", "activated"] do
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
      turn: nil,
      model: "fake/echo",
      queue: @queue,
      persisting: true,
      usage: %Totals{},
      context: nil
    }
  end

  test "a usage that Core would not make is the unknown usage" do
    wired = wire(Wire.value(@usage))
    unknown = %{assistant() | usage: %Helyx.Usage{}}

    for usage <- [
          Map.delete(wired, "cost_kind"),
          Map.delete(wired, "cost"),
          %{wired | "input" => 10 ** 16},
          %{wired | "context_tokens" => 2 ** 64},
          %{wired | "cost" => 1.0e13},
          %{wired | "context_window" => 0}
        ] do
      assert {:ok, %Event{data: %{message: ^unknown}}} =
               Decode.event(message_end(assistant(), %{"usage" => usage})),
             inspect(usage)
    end
  end

  test "a value of the schema past the bounds of Core is read in a form that the fold holds" do
    compaction =
      &wire(
        Wire.event(event(:compaction, %{trigger: :auto, tokens_before: &1, tokens_after: &1}))
      )

    # Any count of the schema, past the float range too: the line counts
    # in integers.
    big = 10 ** 1_023
    assert {:ok, %Event{} = compacted} = Decode.event(compaction.(big))
    vm = ViewModel.apply(ViewModel.from_snapshot(snapshot_of([])), compacted)
    assert [{:infos, [line]}] = ViewModel.cells(vm)
    assert line =~ "compacted: #{div(big, 1000)}k → "

    model = &wire(Wire.event(event(:model_change, %{model: &1}, nil)))

    for text <- ["p/" <> String.duplicate("m", 255), "p/a b", "no-slash", ""] do
      assert {:ok, %Event{data: %{model: ^text}}} = Decode.event(model.(text))
    end

    no_call_id =
      wire(Wire.event(event(:tool_execution_end, %{message: %{result() | tool_call_id: nil}})))

    # The schema has `tool_call_id` optional; the fold shows an orphan.
    assert {:ok, %Event{}} = Decode.event(no_call_id)

    # Two messages at the cost bound of one usage give a total of 2 × 10^12.
    usage = %{@usage | cost: 1.0e12, cost_kind: :billed}
    costly = [%{assistant() | id: "a1", usage: usage}, %{assistant() | id: "a3", usage: usage}]
    {totals, context} = Totals.of(costly)
    assert totals.cost == 2.0e12
    real = %{snapshot_of(costly) | usage: totals, context: context}
    assert subscribe(real) == {:ok, {:ok, real, "1"}}

    # The cap, the first float over it, the largest float, and an integer at
    # it and over it: a cost over the cap counts as the cap.
    at = %{snapshot_of([]) | usage: %Totals{cost: 1.0e300}}
    assert subscribe(at) == {:ok, {:ok, at, "1"}}
    <<bits::64>> = <<1.0e300::float>>
    <<over::float>> = <<bits + 1::64>>
    <<largest::float>> = <<0x7FEFFFFFFFFFFFFF::64>>
    whole = %{at | usage: %Totals{cost: trunc(1.0e300)}}
    assert subscribe(whole) == {:ok, {:ok, whole, "1"}}

    for cost <- [over, largest, trunc(1.0e300) + 1, 10 ** 1_023] do
      assert subscribe(%{at | usage: %Totals{cost: cost}}) == {:ok, {:ok, at, "1"}}
    end

    # A window of 0 is no window.
    windowless = %{at | context: %{tokens: 1, window: nil, model: "fake/echo", bytes: 0}}
    zero = %{windowless | context: %{windowless.context | window: 0}}
    assert subscribe(zero) == {:ok, {:ok, windowless, "1"}}

    # Counts past the float range: the footer counts them in integers.
    huge = %{
      at
      | usage: %Totals{input: big, output: big, cache_read: big, cache_write: 0, cost: nil},
        context: %{tokens: big, window: 1, model: "fake/echo", bytes: big}
    }

    assert {:ok, {:ok, decoded, "1"}} = subscribe(huge)

    %{text: [_row1, %{spans: spans}]} =
      Footer.widget("~", ViewModel.from_snapshot(decoded), nil, nil, nil)

    assert Enum.map_join(spans, & &1.content) =~ ~r/in >999B out >999B.*cache 50%.*>999%/

    # The footer draws the capped form at the cap, after a later message too.
    vm = ViewModel.from_snapshot(at)
    later = event(:message_end, %{message: %{assistant() | usage: usage}})

    for vm <- [vm, ViewModel.apply(vm, later)] do
      %{text: [_row1, %{spans: spans}]} = Footer.widget("~", vm, nil, nil, nil)
      assert Enum.map_join(spans, & &1.content) =~ ">$99999"
    end

    assert subscribe(%{at | model: "no-slash"}) == {:ok, {:ok, %{at | model: "no-slash"}, "1"}}
    # A result with no call before it in the snapshot is an orphan cell.
    orphan = snapshot_of([result()])
    assert subscribe(orphan) == {:ok, {:ok, orphan, "1"}}
    paired = snapshot_of([assistant(), result()])
    assert subscribe(paired) == {:ok, {:ok, paired, "1"}}
  end
end
