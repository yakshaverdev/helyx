defmodule Helyx.Session.StreamEventsTest do
  # How a provider stream ends a turn, harness events, and malformed or
  # oversized stream events.
  use ExUnit.Case, async: true

  import Helyx.Test.Events
  import Helyx.Test.SessionCase

  alias Helyx.{Event, Session}

  setup :start_core

  test "subscribe returns the empty state of a new session", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ok")

    assert {:ok,
            %Helyx.Session.Snapshot{
              seq: 0,
              messages: [],
              turn: nil,
              model: "test/ok",
              queue: %{steers: 0, follow_ups: 0, running: 0, held: 0, waiting: 0}
            }, _} = Session.subscribe(session)
  end

  test "a snapshot during tool calls holds every call in its messages", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    assert_receive {:helyx_event,
                    %Event{type: :message_end, seq: seq, data: %{message: %{role: :assistant}}}}

    # A second client subscribes during the turn; the test process already
    # has its entry.
    test = self()
    pid = spawn(fn -> send(test, {:snapshot, self(), Session.subscribe(session)}) end)

    assert_receive {:snapshot, ^pid, {:ok, snapshot, _}}
    assert %{seq: ^seq, turn: %{partial: nil}} = snapshot

    assert [%Helyx.Message{role: :user}, %Helyx.Message{role: :assistant, content: calls}] =
             snapshot.messages

    assert Enum.map(calls, & &1.id) == ["1", "2", "3"]
    :ok = Session.abort(session)
  end

  test "a stream that ends without a terminal event ends the turn with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/empty")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == ":stream_ended"

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:turn_end)) == :error
  end

  test "a task crash fails the turn and the session accepts the next prompt", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == "boom"
    refute handle?(events)

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:turn_end)) == :error
  end

  describe "the error text of a failed turn (ADR 0006 §2)" do
    defp error_of(core, model) do
      {:ok, session} = Session.start(core, model: "test/" <> model)
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      List.last(collect_until(:turn_end)).data.error
    end

    test "of 3999 and 4000 bytes is kept whole, and one of 4001 bytes is cut", %{core: core} do
      for {n, kept} <- [{3999, 3999}, {4000, 4000}, {4001, 4000}] do
        assert error_of(core, "error_bytes.#{n}") == String.duplicate("a", kept)
      end
    end

    test "of a crash with its stack in a stream is its short message, with no stacktrace", %{
      core: core
    } do
      for {how, text} <- [
            {"badarg", "argument error"},
            {"undef",
             "function :helyx_no_such_module.f/0 is undefined (module :helyx_no_such_module is not available)"},
            {"throw", "Erlang error: {:nocatch, :boom}"},
            {"exit_crash", "argument error"},
            {"exit_shutdown", "argument error"},
            {"catch", "argument error"},
            {"exit_signal", "argument error"}
          ] do
        {:ok, session} = Session.start(core, model: "test/fail_after." <> how)
        {:ok, _, _} = Session.subscribe(session)
        :ok = Session.prompt(session, "hello")
        events = collect_until(:turn_end)

        assert [
                 %{type: :message_end, data: %{error: ^text}},
                 %{type: :turn_end, data: %{error: ^text}}
               ] = Enum.take(events, -2),
               how
      end
    end

    test "is at most 4000 bytes, cut on a character boundary", %{core: core} do
      assert error_of(core, "long_error") == "a" <> String.duplicate("é", 1999)
    end

    test "of an exception is its message", %{core: core} do
      assert error_of(core, "exception_error") == "rate limited"
    end

    test "of a plugin exception whose message throws is its name, or of a struct whose code exits is the plain term",
         %{core: core} do
      assert error_of(core, "throw_message") == "Helyx.Test.ThrowMessage"

      assert error_of(core, "exit_inspect") =~
               ~r/^{:oops, %{.*__struct__: Helyx.Test.ExitInspect.*}}$/
    end

    test "of plugin code that fails on a crash or a struct holds no stacktrace", %{core: core} do
      for {how, plain} <- [
            {"raise_message", ~r/^Helyx.Test.RaiseMessage$/},
            {"throw_message", ~r/^Helyx.Test.ThrowMessage$/},
            {"raise_inspect", ~r/^{:oops, %{.*__struct__: Helyx.Test.RaiseInspect.*}}$/}
          ] do
        assert error_of(core, "fail_after." <> how) =~ plain, how
      end
    end

    test "holds no stacktrace from any part of the reason, and shows :stacktrace in its place",
         %{core: core} do
      for how <- ["exit_exception", "match", "map_key"] do
        refute error_of(core, "fail_after." <> how) =~ "m.erl", how
      end

      assert error_of(core, "fail_after.map_key") == inspect(%{stacktrace: :key})
      assert error_of(core, "fail_after.tail_stack") == inspect([:context, :stacktrace])
      assert error_of(core, "fail_after.fun_frame") == "Erlang error: :oops"
    end

    test "of an improper list is its term", %{core: core} do
      assert error_of(core, "fail_after.improper") == inspect({:failure, [:item | :tail]})
    end

    test "of a raising plugin Inspect inside a MatchError term is the name of the error",
         %{core: core} do
      assert error_of(core, "fail_after.match_inspect") == "MatchError"

      assert error_of(core, "fail_after.exit_exception") ==
               inspect(
                 {:task_exit, %Helyx.Test.StackMessage{message: "held", stack: :stacktrace}}
               )

      assert error_of(core, "fail_after.match") =~
               "{:error, {:badarg, :stacktrace}}"
    end

    test "of a plugin exception whose message exits or gives no string is its name",
         %{core: core} do
      for how <- ["exit_message", "atom_message"] do
        assert error_of(core, "fail_after." <> how) == "Helyx.Test.OddMessage", how
      end
    end

    test "comes from a walk of at most 10,000 terms; past it, the rest is :cut",
         %{core: core} do
      # The reason is n + 3 terms; the walk keeps the first 10,000.
      for {n, text} <- [
            {9_996, "9996 items, last :x"},
            {9_997, "9997 items, last :x"},
            {9_998, "9998 items, last :cut"}
          ] do
        assert error_of(core, "fail_after.nodes.#{n}") == text
      end

      for {n, text} <- [{9_997, "9997 items, last :x"}, {9_998, "9998 items, last :cut"}] do
        assert error_of(core, "fail_after.tuple_nodes.#{n}") == text
      end

      # A map of n pairs is 2n + 3 terms: 4,998 pairs fit, and at 5,000 the
      # rest of the map is `:cut`.
      for {n, text} <- [{4_998, "4998 items, cut: false"}, {5_000, "5000 items, cut: true"}] do
        assert error_of(core, "fail_after.map_nodes.#{n}") == text
      end
    end

    test "of a provider error that ends in the atom :stacktrace reads as a crash, accepted",
         %{core: core} do
      assert error_of(core, "fail_after.marker") == "Erlang error: :oops"
    end

    test "of a provider error whose list looks like a stacktrace is the term", %{core: core} do
      assert error_of(core, "fail_after.params") ==
               inspect({:invalid_params, [{:field, :name, "required", []}]})
    end

    test "keeps the item limit of inspect, and the log line has a bound too", %{core: core} do
      {error, log} = ExUnit.CaptureLog.with_log(fn -> error_of(core, "wide_error") end)
      assert error == inspect(Enum.to_list(1..100), limit: 50)
      assert error =~ "50, ...]"
      assert log =~ "turn failed: " <> inspect(Enum.to_list(1..100), limit: 50)

      {_error, log} = ExUnit.CaptureLog.with_log(fn -> error_of(core, "error_bytes.100000") end)
      assert log =~ inspect(String.duplicate("a", 100_000), printable_limit: 160)
      refute log =~ String.duplicate("a", 161)
    end
  end

  # Halt-on-error only cancels the provider's request if the session never
  # pulls past the error; the fixture's tail raises on a drain.
  test "an error event fails the turn without pulling the stream further", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/error_tail")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == ":overloaded"

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:turn_end)) == :error
  end

  test "consumption stops at the first terminal event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/overrun")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert stop_reason(events) == :end_turn
    assert final_text(events) == "kept"
    refute_receive {:helyx_event, _}, 100
  end

  test "a failure after deltas closes the partial message with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    types = Enum.map(events, & &1.type)

    assert Enum.slice(types, -4..-1) == [
             :message_start,
             :message_update,
             :message_end,
             :turn_end
           ]

    message_end = Enum.at(events, -2)
    assert %Helyx.Message{role: :assistant, stop_reason: :error} = message_end.data.message
    assert Helyx.Message.text(message_end.data.message) == "so far"
    assert message_end.data.error == "boom"
  end

  test "thinking, text, and tool call events build one assistant message in order", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/blocks")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)

    message =
      Enum.find_value(events, fn
        %{type: :message_end, data: %{message: %{role: :assistant} = m}} -> m
        _ -> nil
      end)

    assert message.content == [
             %Helyx.Message.Thinking{thinking: "hmm"},
             %Helyx.Message.Text{text: "Listing."},
             %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}
           ]

    assert Helyx.Message.text(message) == "Listing."
    updates = for %{type: :message_update, data: data} <- events, do: data

    assert Enum.take(updates, 5) == [
             %{thinking_delta: "hm"},
             %{thinking_delta: "m"},
             %{text_delta: "Listing"},
             %{text_delta: "."},
             %{tool_call: List.last(message.content)}
           ]
  end

  describe "harness events (#10)" do
    defp harness_turn(core, model) do
      {:ok, session} = Session.start(core, model: "conn/events.#{model}")
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:turn_end)
    end

    # The session stopped the provider process: `:ending` until its
    # `provider_down`, then gone.
    defp stopped?(conn), do: conn == nil or conn.status == :ending

    test "a harness session id of 1 byte is kept", %{core: core} do
      events = harness_turn(core, "id1")

      assert [%{resume_id: "a"}] =
               for(%Event{type: :resume_id, data: d} <- events, do: d)
    end

    test "a harness session id of 256 bytes is kept", %{core: core} do
      events = harness_turn(core, "id256")

      assert [%{resume_id: id}] =
               for(%Event{type: :resume_id, data: d} <- events, do: d)

      assert byte_size(id) == 256
      assert stop_reason(events) == :end_turn
    end

    test "a cut of 100 digits is kept", %{core: core} do
      events = harness_turn(core, "max_cut")
      cut = Integer.pow(10, 100) - 1

      assert [%{cut: ^cut}] = for(%Event{type: :resume_id, data: d} <- events, do: d)
      assert stop_reason(events) == :end_turn
    end

    test "an id of 257 bytes, 0 bytes, or not UTF-8, or a cut over the digit limit or below 0 fails the turn",
         %{core: core} do
      for model <- ["id257", "id0", "raw_id", "big_cut", "neg_cut"] do
        assert List.last(harness_turn(core, model)).data.error =~
                 "{:bad_stream_event, {:resume_id, ",
               model
      end
    end

    test "a harness tool result of at most 65,536 bytes is recorded as the provider sent it",
         %{core: core} do
      for bytes <- [65_535, 65_536] do
        events = harness_turn(core, "result_#{bytes}")

        assert [%{message: result}] =
                 for(%Event{type: :tool_execution_end, data: d} <- events, do: d)

        assert Helyx.Message.text(result) == String.duplicate("x", bytes)
        assert stop_reason(events) == :end_turn
      end
    end

    test "the first result of a call in the open message closes it", %{core: core} do
      events = harness_turn(core, "result_1")

      types =
        for %Event{type: t} <- events,
            t in [:message_end, :tool_execution_end],
            do: t

      assert [
               :message_end,
               :message_end,
               :tool_execution_end,
               :message_end
             ] = types

      assert [
               _user,
               %{content: [%Helyx.Message.ToolCall{id: "c1"}], stop_reason: :tool_use},
               _last
             ] =
               messages(events)
    end

    test "a harness tool result of 60,000 invalid bytes is stored as valid UTF-8 within the limit",
         %{core: core} do
      events = harness_turn(core, "result_raw")

      assert [%{message: result}] =
               for(%Event{type: :tool_execution_end, data: d} <- events, do: d)

      text = Helyx.Message.text(result)
      assert String.valid?(text)
      assert byte_size(text) <= 65_536

      assert text =~
               ~r/^\[cut to \d+ of 180000 bytes, start and end kept\]\n\x{FFFD}+\n\[… cut …\]\n\x{FFFD}+$/u

      assert stop_reason(events) == :end_turn
    end

    test "a harness tool result over 65,536 bytes keeps its head and tail with a notice, and the turn ends done",
         %{core: core} do
      for {model, bytes, ending} <- [
            {"result_200000", 200_000, "xx"},
            {"result_multibyte", 65_537, "xé"}
          ] do
        events = harness_turn(core, model)

        assert [%{message: result}] =
                 for(%Event{type: :tool_execution_end, data: d} <- events, do: d)

        text = Helyx.Message.text(result)
        assert [notice, head, marker, tail] = String.split(text, "\n")
        kept = byte_size(head) + byte_size(tail)
        assert notice == "[cut to #{kept} of #{bytes} bytes, start and end kept]"
        assert marker == "[… cut …]"
        assert head == String.duplicate("x", byte_size(head))
        # The tail keeps the end of the text, the 2-byte character included.
        assert String.ends_with?(tail, ending)
        assert byte_size(text) <= 65_536
        assert stop_reason(events) == :end_turn
        assert List.last(events).data.outcome == :done
      end
    end

    test "an open assistant message of 8 MiB passes, and a message end starts the count again",
         %{core: core} do
      events = harness_turn(core, "message_at_bound")

      assert stop_reason(events) == :end_turn
      assert [_user, first, second] = messages(events)
      assert byte_size(Helyx.Message.text(first)) == 4 * 1_048_576
      assert byte_size(Helyx.Message.text(second)) == 4 * 1_048_576
    end

    test "an open assistant message over 8 MiB stops the provider process and fails the turn",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/events.message_over_bound")
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      events = collect_until(:turn_end)

      assert List.last(events).data.error == inspect({:message_too_large, 8_388_609, 8_388_608})
      assert stop_reason(events) == :error
      # The provider process is stopped, and the text-only message joins the
      # transcript with the stop reason `:error`, without the event over the bound.
      assert %{conn: conn, transcript: [%{role: :user}, %{stop_reason: :error}]} =
               :sys.get_state(Session.pid(session))

      assert stopped?(conn)

      :ok = Session.set_model(session, "conn/events.id1")
      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:turn_end)) == :end_turn
    end

    test "a tool call counts in the bound of the open message", %{core: core} do
      events = harness_turn(core, "call_at_bound")

      assert stop_reason(events) == :end_turn
      assert [_user, first, _second] = messages(events)
      assert %Helyx.Message.ToolCall{id: "c1"} = List.last(first.content)

      {:ok, session} = Session.start(core, model: "conn/events.call_over_bound")
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      events = collect_until(:turn_end)

      assert List.last(events).data.error == inspect({:message_too_large, 8_388_624, 8_388_608})
      assert stop_reason(events) == :error

      assert %{conn: conn, transcript: [%{role: :user}, %{stop_reason: :error}]} =
               :sys.get_state(Session.pid(session))

      assert stopped?(conn)
    end

    test "a first event over the bound ends the open message and stores no reply",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/events.first_over_bound")
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      events = collect_until(:turn_end)

      assert stop_reason(events) == :error

      assert [%{data: %{message: %{content: [], stop_reason: :error}, error: _}}] =
               for(
                 %Event{type: :message_end, data: %{message: %{role: :assistant}}} = e <- events,
                 do: e
               )

      assert %{conn: conn, transcript: [%{role: :user}]} = :sys.get_state(Session.pid(session))
      assert stopped?(conn)
    end

    test "the 1,025th block of the open message stops the provider process and fails the turn",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/events.blocks_over_bound")
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      events = collect_until(:turn_end)

      assert List.last(events).data.error == inspect({:too_many_blocks, 1_025, 1_024})
      assert stop_reason(events) == :error

      assert %{conn: conn, transcript: [%{role: :user}, %{stop_reason: :error}]} =
               :sys.get_state(Session.pid(session))

      assert stopped?(conn)
    end

    test "an empty delta makes no block and no event", %{core: core} do
      events = harness_turn(core, "empty_between")

      assert [_user, %{content: [%Helyx.Message.Text{text: "abok"}]}] = messages(events)
      updates = for %Event{type: :message_update, data: d} <- events, do: d
      assert updates == [%{text_delta: "a"}, %{text_delta: "b"}, %{text_delta: "ok"}]
    end

    test "a turn of only empty deltas then done ends normally", %{core: core} do
      events = harness_turn(core, "empty_only")

      assert stop_reason(events) == :end_turn
      refute Enum.any?(events, &(&1.type == :message_update))
    end

    test "a result goes to the first open call with its id", %{core: core} do
      events = harness_turn(core, "dup_id")
      ends = for %Event{type: :tool_execution_end, data: d} <- events, do: d.message

      assert [{"read", "one"}, {"bash", "two"}] =
               Enum.map(ends, &{&1.tool_name, Helyx.Message.text(&1)})
    end

    test "a call with no result at done gets its aborted result before the last message",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/events.open_call")
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:turn_end)

      transcript = :sys.get_state(Session.pid(session)).transcript

      assert [:user, :assistant, :tool_result, :tool_result, :assistant] =
               Enum.map(transcript, & &1.role)

      assert [{"read", "one"}, {"bash", "aborted"}] =
               for(m <- Enum.slice(transcript, 2, 2), do: {m.tool_name, Helyx.Message.text(m)})
    end

    test "a new message gives the open calls their aborted results, and a late result is dropped",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/events.late_result")
      {:ok, _, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:turn_end)
      transcript = :sys.get_state(Session.pid(session)).transcript

      assert [:user, :assistant, :tool_result, :assistant, :assistant] =
               Enum.map(transcript, & &1.role)

      assert Helyx.Message.text(Enum.at(transcript, 2)) == "aborted"
    end

    test "a result for a call of no completed message is dropped", %{core: core} do
      events = harness_turn(core, "orphan")
      refute Enum.any?(events, &(&1.type == :tool_execution_end))
      assert final_text(events) == "ok"
    end

    test "a result whose id is not valid UTF-8 is dropped like an unknown id", %{core: core} do
      events = harness_turn(core, "raw_result_id")
      refute Enum.any?(events, &(&1.type == :tool_execution_end))
      assert final_text(events) == "ok"
    end

    test "a crash reason with an integer over the digit limit is capped", %{core: core} do
      marker = "integer of more than #{Helyx.Message.max_integer_digits()} digits removed"

      assert List.last(harness_turn(core, "exit_big")).data.error ==
               inspect({:task_exit, {:boom, marker}})
    end
  end

  # Each model sends one stream event that Core rejects; the error text
  # holds the part given. The reason of `wide_int` holds the marker, not
  # the 400,000 digits (#79).
  for {name, model, part} <- [
        {"a delta that is not a string", "garbage", "{:text_delta, 42}}"},
        {"an event with an extra field", "wide", ~s({:text_delta, "hello", :extra}})},
        {"an extra field with a wide integer", "wide_int",
         ~s({:text_delta, "hello", "integer of more than 100 digits removed"}})},
        {"a usage with a wide integer", "wide_usage",
         ~s(usage: "integer of more than 100 digits removed")},
        {"a delta that is not valid UTF-8", "raw_bytes", ~S({:text_delta, "hi\xFF"}})},
        {"a tool call that is not valid UTF-8", "raw_call", ~S(name: "bash\xFF")},
        {"a tool call with an empty id", "empty_id",
         ~s({:tool_call, %Helyx.Message.ToolCall{id: "", )},
        {"a tool call with a bad field shape", "bad_call", "name: %{}"},
        {"a tool call whose arguments the file cannot hold", "bad_args", ~s(%{"text" => {1, 2}})},
        {"a stop reason outside the format's set", "bad_stop", "stop_reason: :banana"},
        {"the stop reason of an aborted turn", "aborted_stop", "stop_reason: :aborted"},
        {"the stop reason of a failed turn", "error_stop", "stop_reason: :error"},
        {"a harness event from a model provider", "harness_event",
         "{:message_end, :end_turn, nil}}"}
      ] do
    test "a malformed stream event fails the turn and the session lives: #{name}",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "test/" <> unquote(model))
      {:ok, _, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")

      error = List.last(collect_until(:turn_end)).data.error
      assert error =~ "{:bad_stream_event, "
      assert error =~ unquote(part)

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:turn_end)) == :error
    end
  end

  test "a prompt during a turn is rejected", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, stream}
    assert {:error, :turn_running} = Session.prompt(session, "again")
    send(stream, :go)
    assert stop_reason(collect_until(:turn_end)) == :end_turn
  end

  test "an error reason from a provider holds no integer over the digit limit", %{core: core} do
    for model <- ["error_int", "refuse_int"] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      {:ok, _, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      error = List.last(collect_until(:turn_end)).data.error
      assert error == inspect({:oops, "integer of more than 100 digits removed"})
    end
  end

  test "arguments or a usage of another struct type fail the turn and the session lives",
       %{core: core} do
    for model <- ["struct_usage", "struct_args"] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      {:ok, _, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      events = collect_until(:turn_end)
      assert List.last(events).data.error =~ "{:bad_stream_event, "
      refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:turn_end)) == :error
    end
  end

  test "a done payload that is a struct with the large integer ends the turn", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/struct_done")
    {:ok, _, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:turn_end)
    assert final_text(events) == "hi"
    assert stop_reason(events) == :end_turn
    refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:turn_end)) == :end_turn
  end
end
