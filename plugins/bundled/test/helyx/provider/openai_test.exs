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

  # Core checks the type of a delta (`Helyx.Session.Stream`).
  test "a reasoning field emits nothing, and a non-string field goes to Core as it is" do
    stub([
      delta(%{reasoning: "why"}),
      delta(%{content: 42}),
      delta(%{content: "ok"}, "stop"),
      "[DONE]"
    ])

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s", turn_id: "t")

    assert Enum.to_list(stream) == [
             {:text_delta, 42},
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

  @not_object "the arguments are not a valid JSON object"

  # The provider callbacks come from `Helyx.Provider.Loop`; the test
  # process stands in for the provider process.
  test "through the helper, every call goes to Core at once and the results join in call order" do
    stub([
      delta(%{
        tool_calls: [%{index: 0, id: "c1", function: %{name: "read", arguments: ~s({"a": 1})}}]
      }),
      delta(%{tool_calls: [%{index: 1, id: "c2", function: %{name: "read", arguments: "[1]"}}]}),
      delta(%{
        tool_calls: [%{index: 2, id: "c3", function: %{name: "bash", arguments: ~s({"b": 1})}}]
      }),
      delta(%{}, "tool_calls"),
      "[DONE]"
    ])

    {:ok, state} = OpenAI.Go.init("kimi-k2", [], session_id: "s1")
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}
    {:ok, [{:reply, :from, :ok}], state} = OpenAI.Go.request({:turn, "t1", context}, :from, state)
    {events, state} = loop_events(state, [])

    assert [
             {:tool_call, %{id: "c1"}},
             {:tool_call, %{id: "c2"}},
             {:tool_call, %{id: "c3"}},
             {:message_end, :tool_use, %{}},
             {:tool_request, "c1", "read", %{"a" => 1}},
             {:tool_request, "c2", "read", "[1]"},
             {:tool_request, "c3", "bash", %{"b" => 1}}
           ] = events

    # The session answers the raw text with its rejection.
    {:ok, [{:reply, :r3, :ok}], state} =
      OpenAI.Go.request({:tool_result, "t1", "c3", {:ok, "three"}}, :r3, state)

    {:ok, [{:reply, :r2, :ok}], state} =
      OpenAI.Go.request(
        {:tool_result, "t1", "c2", {:error, "tool call not run: " <> @not_object}},
        :r2,
        state
      )

    {:ok, [{:reply, :r1, :ok} | actions], _state} =
      OpenAI.Go.request({:tool_result, "t1", "c1", {:ok, "one"}}, :r1, state)

    assert actions == [
             {:event, "t1", {:tool_result, "c1", {:ok, "one"}}},
             {:event, "t1", {:tool_result, "c2", {:error, "tool call not run: " <> @not_object}}},
             {:event, "t1", {:tool_result, "c3", {:ok, "three"}}},
             {:need_context, "t1"}
           ]
  end

  # The events of the model call up to its message end.
  defp loop_events(state, acc) do
    receive do
      {:request, _conn, _body} ->
        loop_events(state, acc)

      message ->
        {:ok, actions, state} = OpenAI.Go.info(message, state)
        acc = acc ++ for {:event, "t1", event} <- actions, do: event

        if Enum.any?(acc, &match?({:message_end, _, _}, &1)),
          do: {acc, state},
          else: loop_events(state, acc)
    after
      Helyx.Test.Events.wait_ms() -> flunk("no message end")
    end
  end

  test "a missing api key is an error before any request" do
    System.delete_env("OPENCODE_API_KEY")
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:error, {:missing_env, "OPENCODE_API_KEY"}} =
             OpenAI.Go.stream("kimi-k2", context, [])
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
end
