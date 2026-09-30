defmodule Helyx.Session.StreamTest do
  use ExUnit.Case, async: true

  alias Helyx.{Context, Message}
  alias Helyx.Session.Stream, as: SessionStream

  @marker "integer of more than 100 digits removed"

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Helyx.Test.Provider]})
    %{core: core}
  end

  defp run(core, model, opts \\ []) do
    SessionStream.run(%{
      model_context: nil,
      compaction: nil,
      provider: Keyword.get(opts, :provider, Helyx.Test.Provider),
      model: model,
      context: %Context{messages: Keyword.get(opts, :messages, [])},
      opts: [core: core, turn_id: "t1"],
      session: self(),
      turn_id: "t1"
    })
  end

  # The messages the run sent to the session, in order.
  defp sent(acc \\ []) do
    receive do
      :filler -> sent(acc)
      {:stream_event, "t1", _} = message -> sent([message | acc])
      {:rejected_call, "t1", _, _} = message -> sent([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "a valid stream forwards each event in order and returns done", %{core: core} do
    assert {:done, %{stop_reason: :end_turn, usage: %{}}} = run(core, "blocks")

    assert [
             {:stream_event, "t1", {:thinking_delta, "hm"}},
             {:stream_event, "t1", {:thinking_delta, "m"}},
             {:stream_event, "t1", {:text_delta, "Listing"}},
             {:stream_event, "t1", {:text_delta, "."}},
             {:stream_event, "t1", {:tool_call, %Message.ToolCall{id: "call_1"}}}
           ] = sent()
  end

  test "a send over the session queue cap fails the turn and stops the stream", %{core: core} do
    # At the cap one more send is allowed; over it the next send fails.
    for _ <- 1..10_000, do: send(self(), :filler)

    assert run(core, "blocks") == {:error, {:session_behind, 10_001, 10_000}}
    assert [{:stream_event, "t1", {:thinking_delta, "hm"}}] = sent()
  end

  test "a malformed event is the terminal and stops the stream", %{core: core} do
    assert {:error, {:bad_stream_event, {:text_delta, 42}}} = run(core, "garbage")
    assert sent() == []
  end

  test "a delta that is not valid UTF-8 is a malformed event", %{core: core} do
    assert {:error, {:bad_stream_event, {:text_delta, <<"hi", 255>>}}} = run(core, "raw_bytes")
    assert sent() == []
  end

  test "an integer over the digit limit in arguments is capped and the call rejected first",
       %{core: core} do
    assert {:done, _} = run(core, "big_int")
    messages = sent()

    assert [
             {:rejected_call, "t1", %Message.ToolCall{id: "c1"} = rejected,
              "an integer in the arguments has more than 100 digits"},
             {:stream_event, "t1", {:tool_call, first}} | _
           ] =
             messages

    assert rejected == first
    assert %{"n" => [%{"deep" => @marker}]} = first.arguments

    # The call at the limit passes and is not rejected.
    assert Enum.any?(messages, &match?({:stream_event, _, {:tool_call, %{id: "c3"}}}, &1))
    refute Enum.any?(messages, &match?({:rejected_call, _, %{id: "c3"}, _}, &1))
  end

  test "a rejected tool call is sent with its reason before its stream event", %{core: core} do
    assert {:done, _} = run(core, "rejected")
    reason = "the arguments are not a valid JSON object"

    assert [
             {:stream_event, "t1", {:text_delta, "Trying"}},
             {:stream_event, "t1", {:tool_call, %Message.ToolCall{id: "c1"}}},
             {:rejected_call, "t1", %Message.ToolCall{id: "c2"} = rejected, ^reason},
             {:stream_event, "t1", {:tool_call, rejected}}
           ] = sent()
  end

  # The bound is on bytes: 512 "é" are 1,024 bytes, and one more "x" is over.
  for {model, bytes} <- [
        {"reject_bytes_1023", 1023},
        {"reject_bytes_1024", 1024},
        {"reject_multibyte_1024", 1024}
      ] do
    test "a reason from #{model} passes", %{core: core} do
      assert {:done, _} = run(core, unquote(model))
      assert [{:rejected_call, "t1", _, reason}, {:stream_event, "t1", _}] = sent()
      assert byte_size(reason) == unquote(bytes)
    end
  end

  for model <- ["reject_bytes_1025", "reject_multibyte_1025", "reject_raw", "reject_atom"] do
    test "a rejected tool call from #{model} is a malformed event", %{core: core} do
      assert {:error, {:bad_stream_event, {:rejected_tool_call, _, _}}} =
               run(core, unquote(model))

      assert sent() == []
    end
  end

  test "a rejected tool call on a connected turn is a malformed event" do
    event = {:rejected_tool_call, %Message.ToolCall{id: "r", name: "read", arguments: %{}}, "bad"}
    assert {:bad, {:error, {:bad_stream_event, ^event}}} = SessionStream.check(event, true)
  end

  test "an integer over the digit limit in usage is capped, and the extra key dropped",
       %{core: core} do
    call = %Message.ToolCall{id: "c1", name: "upcase", arguments: %{}}
    messages = [Message.tool_result(call, {:ok, "ONE"})]

    assert {:done, done} = run(core, "big_int", messages: messages)
    assert done == %{stop_reason: :end_turn, usage: %{input: @marker, output: 3}}
  end

  test "a harness event from a model provider is a malformed event", %{core: core} do
    assert {:error, {:bad_stream_event, {:message_end, :end_turn, %{}}}} =
             run(core, "harness_event")

    assert [{:stream_event, "t1", {:text_delta, "hi"}}] = sent()
  end

  test "a connected turn can send harness events" do
    event = {:harness_session, "a", 0}
    assert {:send, ^event, nil} = SessionStream.check(event, true)
  end

  test "a harness tool result that is not valid UTF-8 is repaired after the size check" do
    # 65,536 invalid bytes pass the limit as sent; the repair makes each a
    # 3-byte U+FFFD.
    event = {:tool_result, "c1", {:ok, :binary.copy(<<255>>, 65_536)}}

    assert {:send, {:tool_result, "c1", {:ok, text}}, nil} = SessionStream.check(event, true)
    assert text == String.duplicate("\uFFFD", 65_536)
  end

  test "a user_message passes only from a connected turn, with two strings" do
    event = {:user_message, "s1", "more"}
    assert {:send, ^event, nil} = SessionStream.check(event, true)
    assert {:bad, {:error, {:bad_stream_event, ^event}}} = SessionStream.check(event, false)
    assert {:bad, {:error, _}} = SessionStream.check({:user_message, :s1, "more"}, true)
    assert {:bad, {:error, _}} = SessionStream.check({:user_message, "s1", nil}, true)
  end

  # The bound is `HarnessIO.cap_error/1`: 2,000 bytes of valid UTF-8.
  test "a notice passes from any turn with valid text of at most 2,000 bytes" do
    for connected? <- [true, false],
        text <- ["", String.duplicate("x", 1_999), String.duplicate("é", 1_000)] do
      assert {:send, {:notice, ^text}, nil} = SessionStream.check({:notice, text}, connected?)
    end

    for text <- [
          String.duplicate("x", 2_001),
          String.duplicate("é", 1_000) <> "x",
          <<"hi", 255>>,
          :hi
        ] do
      event = {:notice, text}
      assert {:bad, {:error, {:bad_stream_event, ^event}}} = SessionStream.check(event, true)
    end
  end

  test "the error reason of the provider call is capped", %{core: core} do
    assert {:error, {:oops, @marker}} = run(core, "refuse_int")
  end
end
