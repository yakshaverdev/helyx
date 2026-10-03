defmodule Helyx.Session.StreamTest do
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Session.Stream, as: SessionStream

  @marker "integer of more than 100 digits removed"

  defp huge, do: String.to_integer(String.duplicate("7", 400_000))

  test "a rejected_tool_call event is malformed" do
    event = {:rejected_tool_call, %Message.ToolCall{id: "r", name: "read", arguments: %{}}, "bad"}
    assert {:bad, {:error, {:bad_stream_event, ^event}}} = SessionStream.check(event)
  end

  # The next request names a result by the id of its call, so a call with
  # an empty id could never get its result.
  test "a tool call or a tool request with an empty id is malformed" do
    call = %Message.ToolCall{id: "", name: "read", arguments: %{}}

    assert {:bad, {:error, {:bad_stream_event, {:tool_call, ^call}}}} =
             SessionStream.check({:tool_call, call})

    request = {:tool_request, "", "read", %{}}
    assert {:bad, {:error, {:bad_stream_event, ^request}}} = SessionStream.check(request)
  end

  test "an integer over the digit limit in arguments is capped, with the reason not to run it" do
    call = %Message.ToolCall{id: "c1", name: "upcase", arguments: %{"n" => [%{"deep" => huge()}]}}

    assert {:send, {:tool_call, %{arguments: %{"n" => [%{"deep" => @marker}]}}},
            "an integer in the arguments has more than 100 digits"} =
             SessionStream.check({:tool_call, call})

    request = {:tool_request, "c1", "upcase", %{"n" => huge()}}

    assert {:send, {:tool_request, %{id: "c1", name: "upcase", arguments: %{"n" => @marker}}},
            "an integer" <> _} =
             SessionStream.check(request)

    # The integer at the limit passes and is not rejected.
    at_limit = %{call | arguments: %{"n" => 10 ** 100 - 1}}
    assert {:send, {:tool_call, ^at_limit}, nil} = SessionStream.check({:tool_call, at_limit})
  end

  test "an integer over the digit limit in usage is capped, and the extra key dropped" do
    done = Map.put(%{stop_reason: :end_turn, usage: %{input: huge(), output: 3}}, :extra, huge())

    assert {:terminal, {:done, %{stop_reason: :end_turn, usage: %{input: @marker, output: 3}}}} =
             SessionStream.check({:done, done})
  end

  test "a resume event passes" do
    event = {:resume, "a", 0}
    assert {:send, ^event, nil} = SessionStream.check(event)
  end

  test "a harness tool result that is not valid UTF-8 is repaired after the size check" do
    # 65,536 invalid bytes pass the limit as sent; the repair makes each a
    # 3-byte U+FFFD.
    event = {:tool_result, "c1", {:ok, :binary.copy(<<255>>, 65_536)}}

    assert {:send, {:tool_result, "c1", {:ok, text}}, nil} = SessionStream.check(event)
    assert text == String.duplicate("�", 65_536)
  end

  test "a user_message passes with a string steer id" do
    assert {:send, {:user_message, "s1"}, nil} = SessionStream.check({:user_message, "s1"})
    assert {:bad, {:error, _}} = SessionStream.check({:user_message, :s1})
    assert {:bad, {:error, _}} = SessionStream.check({:user_message, "s1", "more"})
  end

  # The bound is `HarnessIO.cap_error/1`: 2,000 bytes of valid UTF-8.
  test "a notice passes with valid text of at most 2,000 bytes" do
    for text <- ["", String.duplicate("x", 1_999), String.duplicate("é", 1_000)] do
      assert {:send, {:notice, ^text}, nil} = SessionStream.check({:notice, text})
    end

    for text <- [
          String.duplicate("x", 2_001),
          String.duplicate("é", 1_000) <> "x",
          <<"hi", 255>>,
          :hi
        ] do
      event = {:notice, text}
      assert {:bad, {:error, {:bad_stream_event, ^event}}} = SessionStream.check(event)
    end
  end
end
