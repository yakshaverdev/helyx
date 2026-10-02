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
              contract_version: 2,
              seq: 0,
              messages: [],
              turn: nil,
              model: "test/ok",
              queue: %{steers: 0, follow_ups: 0}
            }} = Session.subscribe(session)
  end

  test "a snapshot during tool calls lists every call with no result", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/abort")
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")

    # Every call starts at the `message_end`.
    collect_until(:tool_execution_start)
    assert_receive {:helyx_event, %Event{type: :tool_execution_start}}
    assert_receive {:helyx_event, %Event{type: :tool_execution_start, seq: seq}}

    # A second client subscribes during the turn; the test process already
    # has its entry.
    test = self()
    pid = spawn(fn -> send(test, {:snapshot, self(), Session.subscribe(session)}) end)

    assert_receive {:snapshot, ^pid, {:ok, snapshot}}
    assert %{seq: ^seq, turn: %{partial: nil, running: ["1", "2", "3"]}} = snapshot

    assert [%Helyx.Message{role: :user}, %Helyx.Message{role: :assistant, content: calls}] =
             snapshot.messages

    assert Enum.map(calls, & &1.id) == ["1", "2", "3"]
    :ok = Session.abort(session)
  end

  test "a stream that ends without a terminal event ends the turn with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/empty")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == :stream_ended

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  @tag :capture_log
  test "a task crash fails the turn and the session accepts the next prompt", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert {:task_exit, {%RuntimeError{message: "boom"}, _}} = List.last(events).data.error

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  # Halt-on-error only cancels the provider's request if the session never
  # pulls past the error; the fixture's tail raises on a drain.
  test "an error event fails the turn without pulling the stream further", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/error_tail")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :error
    assert List.last(events).data.error == :overloaded

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :error
  end

  test "consumption stops at the first terminal event", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/overrun")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert stop_reason(events) == :end_turn
    assert final_text(events) == "kept"
    refute_receive {:helyx_event, _}, 100
  end

  @tag :capture_log
  test "a failure after deltas closes the partial message with an error", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/crash")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    types = Enum.map(events, & &1.type)

    assert Enum.slice(types, -4..-1) == [
             :message_start,
             :message_update,
             :message_end,
             :agent_end
           ]

    message_end = Enum.at(events, -2)
    assert %Helyx.Message{role: :assistant, stop_reason: :error} = message_end.data.message
    assert Helyx.Message.text(message_end.data.message) == "so far"
    assert {:task_exit, _} = message_end.data.error
    refute Enum.any?(events, &(&1.type == :turn_end))
  end

  test "thinking, text, and tool call events build one assistant message in order", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/blocks")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)

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
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:agent_end)
    end

    test "a harness session id of 1 byte is kept", %{core: core} do
      events = harness_turn(core, "id1")

      assert [%{resume_id: "a"}] =
               for(%Event{type: :provider_session, data: d} <- events, do: d)
    end

    test "a harness session id of 256 bytes is kept", %{core: core} do
      events = harness_turn(core, "id256")

      assert [%{resume_id: id}] =
               for(%Event{type: :provider_session, data: d} <- events, do: d)

      assert byte_size(id) == 256
      assert stop_reason(events) == :end_turn
    end

    test "a cut of 100 digits is kept", %{core: core} do
      events = harness_turn(core, "max_cut")
      cut = Integer.pow(10, 100) - 1

      assert [%{cut: ^cut}] = for(%Event{type: :provider_session, data: d} <- events, do: d)
      assert stop_reason(events) == :end_turn
    end

    test "an id of 257 bytes, 0 bytes, or not UTF-8, or a cut over the digit limit or below 0 fails the turn",
         %{core: core} do
      for model <- ["id257", "id0", "raw_id", "big_cut", "neg_cut"] do
        assert {:bad_stream_event, {:resume, _, _}} =
                 List.last(harness_turn(core, model)).data.error,
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

    test "the size check runs before the UTF-8 repair, which can make the text larger",
         %{core: core} do
      events = harness_turn(core, "result_raw")

      assert [%{message: result}] =
               for(%Event{type: :tool_execution_end, data: d} <- events, do: d)

      assert Helyx.Message.text(result) == String.duplicate("�", 65_536)
      assert stop_reason(events) == :end_turn
    end

    test "a harness tool result over 65,536 bytes fails the turn with no text, and the session goes on",
         %{core: core} do
      for {model, bytes} <- [{"result_65537", 65_537}, {"result_multibyte", 65_537}] do
        {:ok, session} = Session.start(core, model: "conn/events.#{model}")
        {:ok, _} = Session.subscribe(session)
        :ok = Session.prompt(session, "hello")
        events = collect_until(:agent_end)

        assert List.last(events).data.error == {:tool_result_too_large, bytes, 65_536}
        assert stop_reason(events) == :error

        transcript = :sys.get_state(Session.pid(session)).transcript

        assert [:user, :assistant, :tool_result] = Enum.map(transcript, & &1.role)
        assert Helyx.Message.text(List.last(transcript)) == "aborted"

        :ok = Session.set_model(session, "conn/events.id1")
        :ok = Session.prompt(session, "again")
        assert stop_reason(collect_until(:agent_end)) == :end_turn
      end
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
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:agent_end)

      transcript = :sys.get_state(Session.pid(session)).transcript

      assert [:user, :assistant, :tool_result, :tool_result, :assistant] =
               Enum.map(transcript, & &1.role)

      assert [{"read", "one"}, {"bash", "aborted"}] =
               for(m <- Enum.slice(transcript, 2, 2), do: {m.tool_name, Helyx.Message.text(m)})
    end

    test "a new message gives the open calls their aborted results, and a late result is dropped",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/events.late_result")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      collect_until(:agent_end)
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

    @tag :capture_log
    test "a crash reason with an integer over the digit limit is capped", %{core: core} do
      marker = "integer of more than #{Helyx.Message.max_integer_digits()} digits removed"

      assert {:task_exit, {:boom, ^marker}} =
               List.last(harness_turn(core, "exit_big")).data.error
    end

    # `rejected_tool_call` is an event of `Helyx.Provider.Loop`'s stream, not
    # of a provider.
    test "a rejected_tool_call event is malformed, and nothing reaches the transcript",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/events.rejected")
      {:ok, _} = Session.subscribe(session)
      :ok = Session.prompt(session, "hello")
      events = collect_until(:agent_end)

      assert {:bad_stream_event, {:rejected_tool_call, %{id: "r"}, "bad"}} =
               List.last(events).data.error

      refute Enum.any?(
               events,
               &(&1.type == :message_start and &1.data.message.role == :assistant)
             )

      assert [:user] = Enum.map(:sys.get_state(Session.pid(session)).transcript, & &1.role)
    end
  end

  # Each model sends one stream event that Core rejects. The reason of
  # `wide_int` holds the marker, not the 400,000 digits (#79).
  for {name, model, event} <- [
        {"a delta that is not a string", "garbage", quote(do: {:text_delta, 42})},
        {"an event with an extra field", "wide", quote(do: {:text_delta, "hello", :extra})},
        {"an extra field with a wide integer", "wide_int",
         quote(do: {:text_delta, "hello", "integer of more than 100 digits removed"})},
        {"a delta that is not valid UTF-8", "raw_bytes", quote(do: {:text_delta, <<"hi", 255>>})},
        {"a tool call that is not valid UTF-8", "raw_call", quote(do: {:tool_call, _})},
        {"a tool call with an empty id", "empty_id",
         quote(do: {:tool_call, %Helyx.Message.ToolCall{id: ""}})},
        {"a tool call with a bad field shape", "bad_call",
         quote(do: {:tool_call, %Helyx.Message.ToolCall{name: %{}}})},
        {"a tool call whose arguments the file cannot hold", "bad_args",
         quote(do: {:tool_call, _})},
        {"a stop reason outside the format's set", "bad_stop",
         quote(do: {:done, %{stop_reason: :refusal}})},
        {"a harness event from a model provider", "harness_event",
         quote(do: {:message_end, :end_turn, %{}})}
      ] do
    test "a malformed stream event fails the turn and the session lives: #{name}",
         %{core: core} do
      {:ok, session} = Session.start(core, model: "test/" <> unquote(model))
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")

      assert {:bad_stream_event, unquote(event)} =
               List.last(collect_until(:agent_end)).data.error

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:agent_end)) == :error
    end
  end

  test "a prompt during a turn is rejected", %{core: core} do
    {:ok, session} = Session.start(core, model: gated_model())
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    assert_receive {:waiting, stream}
    assert {:error, :turn_running} = Session.prompt(session, "again")
    send(stream, :go)
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end

  test "an error reason from a provider holds no integer over the digit limit", %{core: core} do
    for model <- ["error_int", "refuse_int"] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      error = List.last(collect_until(:agent_end)).data.error
      assert error == {:oops, "integer of more than 100 digits removed"}
    end
  end

  test "arguments or a usage that are a struct fail the turn and the session lives",
       %{core: core} do
    for model <- ["struct_usage", "struct_args"] do
      {:ok, session} = Session.start(core, model: "test/#{model}")
      {:ok, _} = Session.subscribe(session)

      :ok = Session.prompt(session, "hello")
      events = collect_until(:agent_end)
      assert {:bad_stream_event, _} = List.last(events).data.error
      refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))

      :ok = Session.prompt(session, "again")
      assert stop_reason(collect_until(:agent_end)) == :error
    end
  end

  test "a done payload that is a struct with the large integer ends the turn", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/struct_done")
    {:ok, _} = Session.subscribe(session)

    :ok = Session.prompt(session, "hello")
    events = collect_until(:agent_end)
    assert final_text(events) == "hi"
    assert stop_reason(events) == :end_turn
    refute Enum.any?(events, &(:erlang.external_size(&1) > 10_000))

    :ok = Session.prompt(session, "again")
    assert stop_reason(collect_until(:agent_end)) == :end_turn
  end
end
