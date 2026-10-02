defmodule Helyx.Provider.OpenAI.EventsTest do
  # The SSE parser on its own: chunks in, provider stream events out. The
  # tests through Req and the API key are in `Helyx.Provider.OpenAITest`.
  use ExUnit.Case, async: true

  alias Helyx.Provider.OpenAI.Events

  defp sse(chunks) do
    Enum.map_join(chunks, fn
      chunk when is_binary(chunk) -> "data: #{chunk}\n\n"
      chunk -> "data: #{JSON.encode!(chunk)}\n\n"
    end)
  end

  defp delta(delta, finish \\ nil) do
    %{choices: [%{delta: delta, finish_reason: finish}]}
  end

  test "an in-stream error object is an error event" do
    chunks = [sse([%{error: %{message: "overloaded"}}])]

    assert Enum.to_list(Events.events(chunks)) ==
             [{:error, {:api_error, %{"message" => "overloaded"}}}]
  end

  test "tool calls without indexes stay separate calls" do
    chunks = [
      sse([
        delta(%{tool_calls: [%{id: "c1", function: %{name: "read", arguments: ~s({"a": 1})}}]}),
        delta(%{tool_calls: [%{id: "c2", function: %{name: "bash", arguments: ~s({"b": 2})}}]}),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert Enum.to_list(Events.events(chunks)) == [
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c1", name: "read", arguments: %{"a" => 1}}},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c2", name: "bash", arguments: %{"b" => 2}}},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]
  end

  # The chunk is the unit, not the call: the parser cannot tell which call
  # a string or null index means, so a fragment could go to the wrong call
  # or start a call with no id. The stream ends with no tool call.
  for index <- [~s("0"), "null"] do
    test "an index of #{index} ends the stream before any tool call" do
      bad =
        ~s({"choices":[{"delta":{"tool_calls":[{"index":#{unquote(index)},"id":"c2","function":{"arguments":"}"}}]}}]})

      chunks = [
        sse([
          delta(%{
            tool_calls: [%{index: 0, id: "c1", function: %{name: "bash", arguments: "{"}}]
          }),
          bad,
          delta(%{}, "tool_calls"),
          "[DONE]"
        ])
      ]

      assert Enum.to_list(Events.events(chunks)) == [{:error, {:bad_chunk, bad}}]
    end
  end

  @not_object "the arguments are not a valid JSON object"

  test "bad JSON in one of two calls rejects that call alone" do
    chunks = [
      sse([
        delta(%{content: "Hi"}),
        delta(%{tool_calls: [%{id: "c1", function: %{name: "read", arguments: ~s({"a": 1})}}]}),
        delta(%{tool_calls: [%{id: "c2", function: %{name: "bash", arguments: ~s({"b": )}}]}),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert Enum.to_list(Events.events(chunks)) == [
             {:text_delta, "Hi"},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c1", name: "read", arguments: %{"a" => 1}}},
             {:rejected_tool_call,
              %Helyx.Message.ToolCall{id: "c2", name: "bash", arguments: %{}}, @not_object},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]
  end

  test "JSON that is not an object rejects the call" do
    chunks = [
      sse([
        delta(%{tool_calls: [%{id: "c1", function: %{name: "read", arguments: "[1]"}}]}),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert [
             {:rejected_tool_call, %Helyx.Message.ToolCall{id: "c1", arguments: %{}},
              @not_object},
             {:done, _}
           ] = Enum.to_list(Events.events(chunks))
  end

  test "bad JSON in a call with no id fails the turn with no raw JSON" do
    json = ~s({"secret": ) <> String.duplicate("x", 1_000)

    chunks = [
      sse([
        delta(%{content: "Hi"}),
        delta(%{tool_calls: [%{index: 0, function: %{name: "bash", arguments: json}}]}),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert Enum.to_list(Events.events(chunks)) ==
             [{:text_delta, "Hi"}, {:error, {:bad_tool_arguments, "bash"}}]
  end

  # The transport hands the parser arbitrary chunks. Req's test adapter sends
  # one chunk per response, so the reassembly cases run on events/1 directly.
  test "a data line split across chunks is reassembled and blank data is skipped" do
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"con",
      "tent\":\"Hi\"}}]}\n\ndata:\n\ndata: {\"choices\":[{\"delta\":{},",
      "\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    ]

    assert Enum.to_list(Events.events(chunks)) == [
             {:text_delta, "Hi"},
             {:done, %{stop_reason: :end_turn, usage: %{}}}
           ]
  end

  test "a chunk that does not parse is an error event" do
    assert Enum.to_list(Events.events(["data: {oops\n\n"])) ==
             [{:error, {:bad_chunk, "{oops"}}]
  end

  for chunk <- [
        ~s({"choices":[{"delta":"oops"}]}),
        ~s({"choices":{"a":1}}),
        ~s({"choices":[42]}),
        ~s([1,2]),
        ~s({"choices":[{"delta":{"tool_calls":"x"}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"function":"x"}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"function":{"arguments":{}}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"id":42}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"function":{"name":42}}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":[1]}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":-1}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":10001}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":1.0}]}}]})
      ] do
    test "a chunk with the wrong shape is an error event: #{chunk}" do
      assert Enum.to_list(Events.events([sse([unquote(chunk)])])) ==
               [{:error, {:bad_chunk, unquote(chunk)}}]
    end
  end

  # Limits on network input. At the limit and one under pass; one over ends
  # the stream with one error event.

  @max_line_bytes 1_048_576

  defp content_line(pad), do: ~s(data: {"choices":[{"delta":{"content":"#{pad}"}}]})

  # A full SSE line, `data: ` prefix included, of exactly `bytes` bytes,
  # the content ending in `tail`.
  defp content_line_of(bytes, tail \\ "") do
    pad = String.duplicate("a", bytes - byte_size(content_line("")) - byte_size(tail))
    content_line(pad <> tail)
  end

  for bytes <- [@max_line_bytes, @max_line_bytes - 1] do
    test "an SSE line of #{bytes} bytes parses normally" do
      chunks = [content_line_of(unquote(bytes)) <> "\n\ndata: [DONE]\n\n"]

      assert [{:text_delta, _}] = Enum.to_list(Events.events(chunks))
    end
  end

  test "an SSE line over the limit ends the stream with one error event" do
    chunks = [content_line_of(@max_line_bytes + 1) <> "\n\n", sse(["[DONE]"])]

    assert Enum.to_list(Events.events(chunks)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  test "a multibyte character at the line limit parses and one over errors" do
    at = [content_line_of(@max_line_bytes, "😀") <> "\n\ndata: [DONE]\n\n"]
    assert [{:text_delta, _}] = Enum.to_list(Events.events(at))

    over = [content_line_of(@max_line_bytes + 1, "😀") <> "\n\ndata: [DONE]\n\n"]

    assert Enum.to_list(Events.events(over)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  test "a CRLF terminator split across chunks does not count against the limit" do
    at = [content_line_of(@max_line_bytes) <> "\r", "\n\ndata: [DONE]\n\n"]
    assert [{:text_delta, _}] = Enum.to_list(Events.events(at))

    over = [content_line_of(@max_line_bytes + 1) <> "\r", "\n\ndata: [DONE]\n\n"]

    assert Enum.to_list(Events.events(over)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  test "an unterminated line over the limit errors before any terminator" do
    half = String.duplicate("a", div(@max_line_bytes, 2) + 1)
    chunks = ["data: " <> half, half, half]

    assert Enum.to_list(Events.events(chunks)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  @max_tool_call_bytes 10_485_760
  @call_entry_bytes 100
  @call_fragment_bytes 64

  defp n_fragments(json_bytes), do: div(json_bytes - 1, 500_000) + 1

  defp binary_chunks(bin, size) when byte_size(bin) <= size, do: [bin]

  defp binary_chunks(bin, size) do
    <<head::binary-size(^size), rest::binary>> = bin
    [head | binary_chunks(rest, size)]
  end

  # One tool call whose charged bytes (entry, id, name, argument fragments
  # with their per-fragment charge) total exactly `bytes`, the arguments
  # ending in `tail`. The tail stays inside the last fragment, so every
  # fragment is valid UTF-8 and survives the JSON encode in `sse/1`.
  defp call_deltas(bytes, tail \\ "") do
    charged = byte_size("c1") + byte_size("bash") + @call_entry_bytes

    # The per-fragment charge depends on the fragment count, so settle the
    # JSON size in a second pass; away from a 500 KB boundary it converges.
    json_bytes = bytes - charged
    json_bytes = bytes - charged - @call_fragment_bytes * n_fragments(json_bytes)

    pad = String.duplicate("a", json_bytes - byte_size(~s({"a":""})) - byte_size(tail))
    json = ~s({"a":"#{pad}#{tail}"})

    first =
      delta(%{tool_calls: [%{index: 0, id: "c1", function: %{name: "bash", arguments: ""}}]})

    fragments =
      for frag <- binary_chunks(json, 500_000),
          do: delta(%{tool_calls: [%{index: 0, function: %{arguments: frag}}]})

    [first | fragments] ++ [delta(%{}, "tool_calls"), "[DONE]"]
  end

  for bytes <- [@max_tool_call_bytes, @max_tool_call_bytes - 1] do
    test "tool arguments of #{bytes} bytes assemble into the call" do
      events = Enum.to_list(Events.events([sse(call_deltas(unquote(bytes)))]))

      assert [
               {:tool_call,
                %Helyx.Message.ToolCall{id: "c1", name: "bash", arguments: %{"a" => _}}},
               {:done, _}
             ] = events
    end
  end

  test "tool arguments over the limit end the stream with one error event" do
    events = Enum.to_list(Events.events([sse(call_deltas(@max_tool_call_bytes + 1))]))

    assert events == [{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}]
  end

  test "multibyte tool arguments at the limit assemble and one over errors" do
    at = Enum.to_list(Events.events([sse(call_deltas(@max_tool_call_bytes, "😀"))]))
    assert [{:tool_call, %Helyx.Message.ToolCall{}}, {:done, _}] = at

    over = Enum.to_list(Events.events([sse(call_deltas(@max_tool_call_bytes + 1, "😀"))]))
    assert over == [{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}]
  end

  test "tool call ids and names count toward the limit" do
    name = String.duplicate("n", 900_000)

    deltas =
      for i <- 0..12,
          do:
            delta(%{
              tool_calls: [%{index: i, id: "c#{i}", function: %{name: name, arguments: ""}}]
            })

    events = Enum.to_list(Events.events([sse(deltas ++ ["[DONE]"])]))

    assert events == [{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}]
  end

  # The [DONE] arrives in a later chunk so the test covers both halts: the
  # line one inside the bad chunk and the chunk one that cancels the request.
  test "a bad chunk ends the stream after the events before it" do
    chunks = [
      sse([
        delta(%{content: "Hi"}),
        delta(%{tool_calls: [%{index: 0, id: "c1", function: %{name: "bash", arguments: "{"}}]}),
        ~s({"choices":[42]}),
        delta(%{}, "stop")
      ]),
      sse(["[DONE]"])
    ]

    assert Enum.to_list(Events.events(chunks)) ==
             [{:text_delta, "Hi"}, {:error, {:bad_chunk, ~s({"choices":[42]})}}]
  end
end
