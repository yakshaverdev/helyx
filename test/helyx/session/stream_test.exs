defmodule Helyx.Session.StreamTest do
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Session.Stream, as: SessionStream

  @marker "integer of more than 100 digits removed"

  defp huge, do: String.to_integer(String.duplicate("7", 400_000))

  # Arguments that are not a plain map are malformed. The error holds `%{}`
  # in place of raw text (#636).
  test "arguments that are raw text are malformed, and the error drops the text" do
    call = %Message.ToolCall{id: "c1", name: "read", arguments: ~s({"path": )}

    assert {:bad, {:error, {:bad_stream_event, {:tool_call, %{id: "c1", arguments: %{}}}}}} =
             SessionStream.check({:tool_call, call})

    assert {:bad, {:error, {:bad_stream_event, {:tool_request, "c1", "read", %{}}}}} =
             SessionStream.check({:tool_request, "c1", "read", "[1]"})

    # Other arguments that are not a map stay as they are.
    request = {:tool_request, "c1", "read", [1]}
    assert {:bad, {:error, {:bad_stream_event, ^request}}} = SessionStream.check(request)

    assert {:bad, {:error, {:bad_stream_event, {:tool_request, "", "read", %{}}}}} =
             SessionStream.check({:tool_request, "", "read", "secret"})
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

  test "arguments with an integer over the digit limit become %{}, with the reason not to run the call" do
    call = %Message.ToolCall{id: "c1", name: "upcase", arguments: %{"n" => [%{"deep" => huge()}]}}

    assert {:send, {:tool_call, %{arguments: %{}}, _bytes},
            "an integer in the arguments has more than 100 digits"} =
             SessionStream.check({:tool_call, call})

    request = {:tool_request, "c1", "upcase", %{"n" => 10 ** 100}}

    assert {:send, {:tool_request, %{id: "c1", name: "upcase", arguments: %{}}, _bytes},
            "an integer" <> _} =
             SessionStream.check(request)

    # The integer at the limit passes and is not rejected.
    at_limit = %{call | arguments: %{"n" => 10 ** 100 - 1}}

    assert {:send, {:tool_call, ^at_limit, _bytes}, nil} =
             SessionStream.check({:tool_call, at_limit})
  end

  # The bound of the open message counts the JSON bytes, not characters:
  # `["c1","é",{}]` is 14 bytes.
  test "a checked tool call carries the bytes of its JSON encode" do
    call = %Message.ToolCall{id: "c1", name: "é", arguments: %{}}
    assert {:send, {:tool_call, ^call, 14}, nil} = SessionStream.check({:tool_call, call})
  end

  # The struct bound of `Helyx.Usage` (`docs/features/usage-and-limits.md`,
  # "Value bounds"): at the bound, one under, and one over.
  @good_usages [
    nil,
    %Helyx.Usage{},
    %Helyx.Usage{input: 10 ** 15, output: 10 ** 15 - 1, cache_read: 10 ** 15},
    %Helyx.Usage{cache_write: 10 ** 15, context_tokens: 10 ** 15},
    %Helyx.Usage{cost: 10 ** 12, cost_kind: :list, context_window: 1},
    %Helyx.Usage{cost: 10 ** 12 - 0.5, cost_kind: :billed, context_window: 10 ** 9}
  ]

  @bad_usages [
    %{input: 1, output: 3},
    %{},
    %Helyx.Usage{input: 10 ** 15 + 1},
    %Helyx.Usage{output: 10 ** 15 + 1},
    %Helyx.Usage{cache_read: 10 ** 15 + 1},
    %Helyx.Usage{cache_write: 10 ** 15 + 1},
    %Helyx.Usage{context_tokens: 10 ** 15 + 1},
    %Helyx.Usage{input: 10 ** 100},
    %Helyx.Usage{cost: 10 ** 12 + 0.5, cost_kind: :list},
    %Helyx.Usage{cost: 1, cost_kind: nil},
    %Helyx.Usage{context_window: 0},
    %Helyx.Usage{context_window: 10 ** 9 + 1},
    %Date{year: 1, month: 1, day: 1}
  ]

  test "a usage is nil or a Helyx.Usage within the struct bound; an extra done key is dropped" do
    for usage <- @good_usages do
      done = %{stop_reason: :end_turn, usage: usage}
      assert {:terminal, {:done, ^done}} = SessionStream.check({:done, Map.put(done, :x, 1)})
      event = {:message_end, :end_turn, usage}
      assert {:send, ^event, nil} = SessionStream.check(event)
    end

    for usage <- @bad_usages do
      done = %{stop_reason: :end_turn, usage: usage}

      assert {:bad, {:error, {:bad_stream_event, {:done, ^done}}}} =
               SessionStream.check({:done, done})

      event = {:message_end, :end_turn, usage}
      assert {:bad, {:error, {:bad_stream_event, ^event}}} = SessionStream.check(event)
    end
  end

  test "a provider cannot send the stop reasons of a cut turn" do
    for stop <- [:aborted, :error] do
      assert {:bad, {:error, _}} = SessionStream.check({:done, %{stop_reason: stop, usage: nil}})
      assert {:bad, {:error, _}} = SessionStream.check({:message_end, stop, nil})
    end
  end

  test "a resume_id event passes" do
    event = {:resume_id, "a", 0}
    assert {:send, ^event, nil} = SessionStream.check(event)
  end

  test "a harness tool result that is not valid UTF-8 is repaired, then cut to the limit" do
    # The repair makes each invalid byte a 3-byte U+FFFD: 196,608 bytes.
    event = {:tool_result, "c1", {:ok, :binary.copy(<<255>>, 65_536)}}

    assert {:send, {:tool_result, "c1", {:ok, text}}, nil} = SessionStream.check(event)
    assert byte_size(text) <= 65_536

    assert text =~
             ~r/^\[cut to \d+ of 196608 bytes, start and end kept\]\n\x{FFFD}+\n\[… cut …\]\n\x{FFFD}+$/u
  end

  test "a user_message passes with a string steer id" do
    assert {:send, {:user_message, "s1"}, nil} = SessionStream.check({:user_message, "s1"})
    assert {:bad, {:error, _}} = SessionStream.check({:user_message, :s1})
    assert {:bad, {:error, _}} = SessionStream.check({:user_message, "s1", "more"})
  end

  test "an error terminal comes back with the integer cap, ready to send" do
    assert {:terminal, {:error, {:oops, @marker, 1}}} =
             SessionStream.check({:error, {:oops, 10 ** 100, 1}})
  end
end
