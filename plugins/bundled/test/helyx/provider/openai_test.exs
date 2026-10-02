defmodule Helyx.Provider.OpenAITest do
  # Provider seam: call stream/3 on the plugin modules with Req's test adapter
  # and recorded response bodies. Nothing here touches the network. The
  # session loop above this seam is covered by the Fake provider tests.
  # Not async: the tests mutate OPENCODE_API_KEY and the :openai_req_options app env.
  use ExUnit.Case, async: false

  alias Helyx.Provider.OpenAI

  setup do
    System.put_env("OPENCODE_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("OPENCODE_API_KEY") end)
  end

  defp sse(chunks) do
    Enum.map_join(chunks, fn
      chunk when is_binary(chunk) -> "data: #{chunk}\n\n"
      chunk -> "data: #{JSON.encode!(chunk)}\n\n"
    end)
  end

  defp delta(delta, finish \\ nil) do
    %{choices: [%{delta: delta, finish_reason: finish}]}
  end

  defp plug(fun) do
    Application.put_env(:helyx_plugins, :openai_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :openai_req_options) end)
  end

  defp stub(events) do
    test = self()

    plug(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, JSON.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse(events))
    end)
  end

  test "opencode-go and opencode refs route to the two plugins" do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [OpenAI.Go, OpenAI.Zen]})

    assert {:ok, OpenAI.Go} = Helyx.Provider.find(core, "opencode-go")
    assert {:ok, OpenAI.Zen} = Helyx.Provider.find(core, "opencode")
  end

  test "a streamed text response yields deltas, thinking, usage, and done" do
    stub([
      delta(%{role: "assistant", content: ""}),
      delta(%{reasoning_content: "hmm"}),
      delta(%{content: "Hel"}),
      delta(%{content: "lo"}),
      delta(%{}, "stop"),
      %{choices: [], usage: %{prompt_tokens: 12, completion_tokens: 3}},
      "[DONE]"
    ])

    context = %Helyx.Context{system: "Be brief.", messages: [Helyx.Message.user("hi")]}
    opts = [session_id: "s123", turn_id: "t1"]

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, opts)

    assert Enum.to_list(stream) == [
             {:thinking_delta, "hmm"},
             {:text_delta, "Hel"},
             {:text_delta, "lo"},
             {:done, %{stop_reason: :end_turn, usage: %{input: 12, output: 3}}}
           ]

    assert_received {:request, conn, body}
    assert conn.host == "opencode.ai"
    assert conn.request_path == "/zen/go/v1/chat/completions"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
    assert Plug.Conn.get_req_header(conn, "x-opencode-session") == ["s123"]

    assert body["model"] == "kimi-k2"
    assert body["stream"] == true
    assert body["stream_options"] == %{"include_usage" => true}

    assert body["messages"] == [
             %{"role" => "system", "content" => "Be brief."},
             %{"role" => "user", "content" => "hi"}
           ]
  end

  test "reasoning is thinking too, and a non-string field emits nothing" do
    stub([
      delta(%{reasoning: "why"}),
      delta(%{content: 42}),
      delta(%{reasoning_content: %{"a" => 1}}),
      delta(%{content: "ok"}, "stop"),
      "[DONE]"
    ])

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s", turn_id: "t")

    assert Enum.to_list(stream) == [
             {:thinking_delta, "why"},
             {:text_delta, "ok"},
             {:done, %{stop_reason: :end_turn, usage: %{}}}
           ]
  end

  test "a streamed tool call is assembled from deltas into one block" do
    stub([
      delta(%{content: "Listing."}),
      delta(%{
        tool_calls: [
          %{index: 0, id: "call_1", type: "function", function: %{name: "bash", arguments: ""}}
        ]
      }),
      delta(%{tool_calls: [%{index: 0, function: %{arguments: ~s({"comm)}}]}),
      delta(%{tool_calls: [%{index: 0, function: %{arguments: ~s(and": "ls"})}}]}),
      delta(%{}, "tool_calls"),
      "[DONE]"
    ])

    call = %Helyx.Message.ToolCall{id: "call_0", name: "bash", arguments: %{"command" => "pwd"}}

    context = %Helyx.Context{
      messages: [
        Helyx.Message.user("list the files"),
        %Helyx.Message{
          role: :assistant,
          content: [
            %Helyx.Message.Thinking{thinking: "I should list."},
            %Helyx.Message.Text{text: "First."},
            call
          ]
        },
        Helyx.Message.tool_result(call, {:ok, "/repo"})
      ],
      tools: [%{name: "bash", description: "Runs a command.", parameters: %{"type" => "object"}}]
    }

    assert {:ok, stream} = OpenAI.Zen.stream("gpt-5", context, [])

    assert Enum.to_list(stream) == [
             {:text_delta, "Listing."},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]

    assert_received {:request, conn, body}
    assert conn.request_path == "/zen/v1/chat/completions"

    assert body["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "bash",
                 "description" => "Runs a command.",
                 "parameters" => %{"type" => "object"}
               }
             }
           ]

    assert body["messages"] == [
             %{"role" => "user", "content" => "list the files"},
             %{
               "role" => "assistant",
               "content" => "First.",
               "reasoning_content" => "I should list.",
               "tool_calls" => [
                 %{
                   "id" => "call_0",
                   "type" => "function",
                   "function" => %{"name" => "bash", "arguments" => ~s({"command":"pwd"})}
                 }
               ]
             },
             %{"role" => "tool", "tool_call_id" => "call_0", "content" => "/repo"}
           ]
  end

  defmodule BinaryTool do
    @moduledoc false
    # A tool whose result is not valid UTF-8, so the composition test below
    # can show the hands deliver text the request encoder accepts.
    @behaviour Helyx.Tool

    @impl true
    def name, do: "binary"
    @impl true
    def description, do: "Returns invalid bytes."
    @impl true
    def parameters, do: %{"type" => "object"}
    @impl true
    def run(_args, _cwd), do: {:ok, <<"a", 255, "b">>}
  end

  test "a tool result with invalid bytes from the hands encodes and sends" do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [OpenAI.Go, BinaryTool]})
    {:ok, tools} = Helyx.Tool.specs(core)
    tools = Map.new(tools, fn {tool, spec} -> {spec.name, tool} end)

    {:ok, hands} =
      Helyx.Session.Hands.start_link(core: core, cwd: File.cwd!(), session: self(), tools: tools)

    call = %Helyx.Message.ToolCall{id: "call_1", name: "binary", arguments: %{}}
    :ok = Helyx.Session.Hands.run(hands, "t1", call)
    assert_receive {:tool_result, "t1", "call_1", result}

    stub([delta(%{content: "ok"}, "stop"), "[DONE]"])

    context = %Helyx.Context{
      messages: [
        Helyx.Message.user("go"),
        %Helyx.Message{role: :assistant, content: [call]},
        Helyx.Message.tool_result(call, result)
      ]
    }

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert List.last(Enum.to_list(stream)) == {:done, %{stop_reason: :end_turn, usage: %{}}}

    assert_received {:request, _conn, body}

    assert List.last(body["messages"]) ==
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "a�b"}
  end

  test "a non-2xx response yields one error event with the body" do
    plug(&Plug.Conn.send_resp(&1, 401, ~s({"error": "bad key"})))
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert Enum.to_list(stream) == [{:error, {:http_status, 401, ~s({"error": "bad key"})}}]
  end

  test "a transport error at connect is an error event" do
    plug(&Req.Test.transport_error(&1, :econnrefused))
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert [{:error, %Req.TransportError{reason: :econnrefused}}] = Enum.to_list(stream)
  end

  test "a stream that drops before [DONE] yields no done event" do
    stub([delta(%{content: "Hel"}), delta(%{}, "stop")])
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, [])
    assert Enum.to_list(stream) == [{:text_delta, "Hel"}]
  end

  test "an in-stream error object is an error event" do
    chunks = [sse([%{error: %{message: "overloaded"}}])]

    assert Enum.to_list(OpenAI.events(chunks)) ==
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

    assert Enum.to_list(OpenAI.events(chunks)) == [
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c1", name: "read", arguments: %{"a" => 1}}},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "c2", name: "bash", arguments: %{"b" => 2}}},
             {:done, %{stop_reason: :tool_use, usage: %{}}}
           ]
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

    assert Enum.to_list(OpenAI.events(chunks)) == [
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
           ] = Enum.to_list(OpenAI.events(chunks))
  end

  # The provider callbacks come from `Helyx.Provider.Loop`; the test
  # process stands in for the provider process.
  test "through the helper, a rejected call gets its result and a good one goes to Core" do
    stub([
      delta(%{tool_calls: [%{id: "c1", function: %{name: "read", arguments: "[1]"}}]}),
      delta(%{tool_calls: [%{id: "c2", function: %{name: "bash", arguments: ~s({"b": 1})}}]}),
      delta(%{}, "tool_calls"),
      "[DONE]"
    ])

    {:ok, state} = OpenAI.Go.init("kimi-k2", [], session_id: "s1")
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}
    {:ok, [{:reply, :from, :ok}], state} = OpenAI.Go.request({:turn, "t1", context}, :from, state)

    assert [
             {:tool_call, %{id: "c1"}},
             {:tool_call, %{id: "c2"}},
             {:message_end, :tool_use, %{}},
             {:tool_result, "c1", {:error, "tool call not run: " <> @not_object}},
             {:tool_request, "0", "bash", %{"b" => 1}}
           ] = loop_events(state, [])
  end

  # The events of the model call up to the first tool request.
  defp loop_events(state, acc) do
    receive do
      {:request, _conn, _body} ->
        loop_events(state, acc)

      message ->
        {:ok, actions, state} = OpenAI.Go.info(message, state)
        acc = acc ++ for {:event, "t1", event} <- actions, do: event

        if match?({:tool_request, _, _, _}, List.last(acc)),
          do: acc,
          else: loop_events(state, acc)
    after
      Helyx.Test.Events.wait_ms() -> flunk("no tool request")
    end
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

    assert Enum.to_list(OpenAI.events(chunks)) ==
             [{:text_delta, "Hi"}, {:error, {:bad_tool_arguments, "bash"}}]
  end

  test "a missing api key is an error before any request" do
    System.delete_env("OPENCODE_API_KEY")
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:error, {:missing_env, "OPENCODE_API_KEY"}} =
             OpenAI.Go.stream("kimi-k2", context, [])
  end

  # The transport hands the parser arbitrary chunks. Req's test adapter sends
  # one chunk per response, so the reassembly cases run on events/1 directly.
  test "a data line split across chunks is reassembled and blank data is skipped" do
    chunks = [
      "data: {\"choices\":[{\"delta\":{\"con",
      "tent\":\"Hi\"}}]}\n\ndata:\n\ndata: {\"choices\":[{\"delta\":{},",
      "\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    ]

    assert Enum.to_list(OpenAI.events(chunks)) == [
             {:text_delta, "Hi"},
             {:done, %{stop_reason: :end_turn, usage: %{}}}
           ]
  end

  test "a chunk that does not parse is an error event" do
    assert Enum.to_list(OpenAI.events(["data: {oops\n\n"])) ==
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
        ~s({"choices":[{"delta":{"tool_calls":[{"index":10001}]}}]})
      ] do
    test "a chunk with the wrong shape is an error event: #{chunk}" do
      assert Enum.to_list(OpenAI.events([sse([unquote(chunk)])])) ==
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

      assert [{:text_delta, _}] = Enum.to_list(OpenAI.events(chunks))
    end
  end

  test "an SSE line over the limit ends the stream with one error event" do
    chunks = [content_line_of(@max_line_bytes + 1) <> "\n\n", sse(["[DONE]"])]

    assert Enum.to_list(OpenAI.events(chunks)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  test "a multibyte character at the line limit parses and one over errors" do
    at = [content_line_of(@max_line_bytes, "😀") <> "\n\ndata: [DONE]\n\n"]
    assert [{:text_delta, _}] = Enum.to_list(OpenAI.events(at))

    over = [content_line_of(@max_line_bytes + 1, "😀") <> "\n\ndata: [DONE]\n\n"]

    assert Enum.to_list(OpenAI.events(over)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  test "a CRLF terminator split across chunks does not count against the limit" do
    at = [content_line_of(@max_line_bytes) <> "\r", "\n\ndata: [DONE]\n\n"]
    assert [{:text_delta, _}] = Enum.to_list(OpenAI.events(at))

    over = [content_line_of(@max_line_bytes + 1) <> "\r", "\n\ndata: [DONE]\n\n"]

    assert Enum.to_list(OpenAI.events(over)) ==
             [{:error, {:line_over_limit, @max_line_bytes}}]
  end

  test "an unterminated line over the limit errors before any terminator" do
    half = String.duplicate("a", div(@max_line_bytes, 2) + 1)
    chunks = ["data: " <> half, half, half]

    assert Enum.to_list(OpenAI.events(chunks)) ==
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
      events = Enum.to_list(OpenAI.events([sse(call_deltas(unquote(bytes)))]))

      assert [
               {:tool_call,
                %Helyx.Message.ToolCall{id: "c1", name: "bash", arguments: %{"a" => _}}},
               {:done, _}
             ] = events
    end
  end

  test "tool arguments over the limit end the stream with one error event" do
    events = Enum.to_list(OpenAI.events([sse(call_deltas(@max_tool_call_bytes + 1))]))

    assert events == [{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}]
  end

  test "multibyte tool arguments at the limit assemble and one over errors" do
    at = Enum.to_list(OpenAI.events([sse(call_deltas(@max_tool_call_bytes, "😀"))]))
    assert [{:tool_call, %Helyx.Message.ToolCall{}}, {:done, _}] = at

    over = Enum.to_list(OpenAI.events([sse(call_deltas(@max_tool_call_bytes + 1, "😀"))]))
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

    events = Enum.to_list(OpenAI.events([sse(deltas ++ ["[DONE]"])]))

    assert events == [{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}]
  end

  # A delta that only names an index still creates an entry; the entry and
  # its key are charged, so index spraying is bounded too.
  test "tool call entry keys count toward the limit" do
    deltas =
      for i <- 0..12,
          do: delta(%{tool_calls: [%{index: "#{i}#{String.duplicate("k", 900_000)}"}]})

    events = Enum.to_list(OpenAI.events([sse(deltas ++ ["[DONE]"])]))

    assert events == [{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}]
  end

  @max_error_body_bytes 16_384

  for bytes <- [@max_error_body_bytes, @max_error_body_bytes - 1] do
    test "an error body of #{bytes} bytes arrives whole" do
      body = String.duplicate("a", unquote(bytes))
      plug(&Plug.Conn.send_resp(&1, 500, body))

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, [])
      assert Enum.to_list(stream) == [{:error, {:http_status, 500, body}}]
    end
  end

  test "an error body over the limit is cut and marked" do
    body = String.duplicate("a", @max_error_body_bytes + 1)
    plug(&Plug.Conn.send_resp(&1, 500, body))

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, [])
    assert [{:error, {:http_status, 500, cut}}] = Enum.to_list(stream)

    assert cut ==
             binary_part(body, 0, @max_error_body_bytes) <>
               "\n[truncated at the #{@max_error_body_bytes}-byte limit]"
  end

  test "an error body cut inside a multibyte character retreats to a boundary" do
    body = String.duplicate("a", @max_error_body_bytes - 2) <> "😀😀"
    plug(&Plug.Conn.send_resp(&1, 500, body))

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, [])
    assert [{:error, {:http_status, 500, cut}}] = Enum.to_list(stream)

    assert cut ==
             String.duplicate("a", @max_error_body_bytes - 2) <>
               "\n[truncated at the #{@max_error_body_bytes}-byte limit]"

    assert String.valid?(cut)
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

    assert Enum.to_list(OpenAI.events(chunks)) ==
             [{:text_delta, "Hi"}, {:error, {:bad_chunk, ~s({"choices":[42]})}}]
  end
end
