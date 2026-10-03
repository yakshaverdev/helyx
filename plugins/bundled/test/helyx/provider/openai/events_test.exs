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

  test "a null error is a missing error" do
    chunks = [sse([%{error: nil, choices: [%{delta: %{content: "Hi"}}]}])]
    assert Enum.to_list(Events.events(chunks)) == [{:text_delta, "Hi"}]
  end

  test "tool calls of two indexes stay separate calls" do
    chunks = [
      sse([
        delta(%{tool_calls: [%{index: 0, id: "c1", function: %{name: "read", arguments: "{"}}]}),
        delta(%{tool_calls: [%{index: 1, id: "c2", function: %{name: "bash", arguments: "{"}}]}),
        delta(%{tool_calls: [%{index: 0, function: %{arguments: ~s("a": 1})}}]}),
        delta(%{tool_calls: [%{index: 1, function: %{arguments: ~s("b": 2})}}]}),
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

  # The OpenAI streaming format gives every call delta an integer index. Any
  # other index, or none, fails the shape check, and the stream ends with no
  # tool call.
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

  test "an index that repeats its id, or gets its first id late, stays one call" do
    chunks = [
      sse([
        delta(%{tool_calls: [%{index: 0, function: %{name: "bash", arguments: "{"}}]}),
        delta(%{tool_calls: [%{index: 0, id: "c1", function: %{arguments: ~s("a":)}}]}),
        delta(%{tool_calls: [%{index: 0, id: "c1", function: %{arguments: "1}"}}]}),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert Enum.to_list(Events.events(chunks)) == [
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c1", name: "bash", arguments: %{"a" => 1}}},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]
  end

  test "bad JSON in one of two calls goes on as its raw text, in that call alone" do
    chunks = [
      sse([
        delta(%{content: "Hi"}),
        delta(%{
          tool_calls: [%{index: 0, id: "c1", function: %{name: "read", arguments: ~s({"a": 1})}}]
        }),
        delta(%{
          tool_calls: [%{index: 1, id: "c2", function: %{name: "bash", arguments: ~s({"b": )}}]
        }),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert Enum.to_list(Events.events(chunks)) == [
             {:text_delta, "Hi"},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c1", name: "read", arguments: %{"a" => 1}}},
             {:tool_call, %Helyx.Message.ToolCall{id: "c2", name: "bash", arguments: ~s({"b": )}},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]
  end

  test "JSON that is not an object goes on as its raw text" do
    chunks = [
      sse([
        delta(%{
          tool_calls: [%{index: 0, id: "c1", function: %{name: "read", arguments: "[1]"}}]
        }),
        delta(%{}, "tool_calls"),
        "[DONE]"
      ])
    ]

    assert [
             {:tool_call, %Helyx.Message.ToolCall{id: "c1", arguments: "[1]"}},
             {:done, _}
           ] = Enum.to_list(Events.events(chunks))
  end

  # Core rejects the empty id (`Helyx.Session.Stream`), so the turn fails.
  test "bad JSON in a call with no id goes on as its raw text" do
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
             [
               {:text_delta, "Hi"},
               {:tool_call, %Helyx.Message.ToolCall{id: "", name: "bash", arguments: json}},
               {:done, %{stop_reason: :tool_use, usage: %{}}}
             ]
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
        ~s({"choices":[{"delta":{"tool_calls":[{"index":1.0}]}}]}),
        ~s({"choices":[{"delta":false}]}),
        ~s({"choices":[{"delta":{},"finish_reason":5}]}),
        ~s({"choices":[{"delta":{},"finish_reason":false}]}),
        ~s({"choices":[],"usage":false}),
        ~s({"choices":[],"usage":{"prompt_tokens":"9"}}),
        ~s({"choices":[{"delta":{"tool_calls":false}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"index":0,"function":false}]}}]}),
        ~s({"choices":[{"delta":{"tool_calls":[{"id":"c1","function":{"name":"bash"}}]}}]})
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

  test "an unterminated line over the limit errors before any terminator" do
    half = String.duplicate("a", div(@max_line_bytes, 2) + 1)
    chunks = ["data: " <> half, half, half]

    assert Enum.to_list(Events.events(chunks)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  @max_tool_call_bytes 10_485_760

  defp binary_chunks(bin, size) when byte_size(bin) <= size, do: [bin]

  defp binary_chunks(bin, size) do
    <<head::binary-size(^size), rest::binary>> = bin
    [head | binary_chunks(rest, size)]
  end

  # One tool call whose id, name, and arguments total exactly `bytes`, the
  # arguments ending in `tail`. The tail stays inside the last fragment, so
  # every fragment is valid UTF-8 and survives the JSON encode in `sse/1`.
  defp call_deltas(bytes, tail \\ "") do
    json_bytes = bytes - byte_size("c1") - byte_size("bash")
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
