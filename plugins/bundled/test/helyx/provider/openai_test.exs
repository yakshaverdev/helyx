defmodule Helyx.Provider.OpenAITest do
  # Provider seam: call stream/3 on the plugin modules with Req's test adapter
  # and recorded response bodies. Nothing here touches the network. The
  # session loop above this seam is covered by the Fake provider tests.
  # Not async: the tests mutate OPENCODE_API_KEY, the :openai_req_options app env, and Req's :default_options.
  use ExUnit.Case, async: false

  alias Helyx.Provider.OpenAI
  alias Helyx.Provider.OpenAI.Endpoint
  alias Helyx.ProviderError

  # An endpoint of a product: a local server with no key.
  defmodule Local do
    @moduledoc false
    use Helyx.Provider.OpenAI, id: "local", base_url: "http://localhost:11434/v1"
  end

  defp user_agent, do: "helyx/#{Application.spec(:helyx, :vsn)}"

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

  defp http_error(status, text, id \\ "opencode-go"),
    do: {:error, %ProviderError{provider: id, kind: status, text: text}}

  defp plug(fun) do
    Application.put_env(:helyx_plugins, :openai_req_options, plug: fun)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :openai_req_options) end)
  end

  defp stub(events) do
    test = self()

    plug(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, JSON.decode!(body)})
      reply(conn, events)
    end)
  end

  defp reply(conn, events) do
    conn
    |> Plug.Conn.put_resp_content_type("text/event-stream")
    |> Plug.Conn.send_resp(200, sse(events))
  end

  test "each endpoint module is a plugin with its ref prefix; opencode is no longer one" do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [OpenAI.Go, Local]})

    assert {:ok, OpenAI.Go} = Helyx.Provider.find(core, "opencode-go")
    assert {:ok, Local} = Helyx.Provider.find(core, "local")
    assert {:error, {:unknown_provider, "opencode"}} = Helyx.Provider.find(core, "opencode")
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
             {:done,
              %{
                stop_reason: :end_turn,
                usage: %Helyx.Usage{input: 12, output: 3, context_tokens: 15}
              }}
           ]

    assert_received {:request, conn, body}
    assert conn.host == "opencode.ai"
    assert conn.request_path == "/zen/go/v1/chat/completions"
    assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
    assert Plug.Conn.get_req_header(conn, "x-opencode-session") == ["s123"]

    assert Plug.Conn.get_req_header(conn, "user-agent") == [user_agent()]

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
             {:done, %{stop_reason: :end_turn, usage: %Helyx.Usage{}}}
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

    assert {:ok, stream} = Local.stream("gpt-5", context, session_id: "s")

    assert Enum.to_list(stream) == [
             {:text_delta, "Listing."},
             {:tool_call,
              %Helyx.Message.ToolCall{id: "call_1", name: "bash", arguments: %{"command" => "ls"}}},
             {:done, %{stop_reason: :tool_use, usage: %Helyx.Usage{}}}
           ]

    # No key: no Authorization header. The engine's user agent still goes.
    assert_received {:request, conn, body}
    assert conn.host == "localhost" and conn.port == 11_434
    assert conn.request_path == "/v1/chat/completions"
    assert Plug.Conn.get_req_header(conn, "authorization") == []

    assert Plug.Conn.get_req_header(conn, "user-agent") == [user_agent()]

    assert Plug.Conn.get_req_header(conn, "x-opencode-session") == []

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
      Helyx.Session.Hands.start_link(
        core: core,
        cwd: File.cwd!(),
        background_dir: Path.join(System.tmp_dir!(), "helyx-unused"),
        session: self(),
        tools: tools
      )

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

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, session_id: "s")

    assert List.last(Enum.to_list(stream)) ==
             {:done, %{stop_reason: :end_turn, usage: %Helyx.Usage{}}}

    assert_received {:request, _conn, body}

    assert List.last(body["messages"]) ==
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "a�b"}
  end

  # Three backoff waits: 0.5, 1, and 2 s, less jitter.
  @tag :slow
  test "a transport error on every attempt is an error event after 3 retries" do
    sequence([&Req.Test.transport_error(&1, :econnrefused)])

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", %Helyx.Context{}, session_id: "s")
    assert [{:error, %Req.TransportError{reason: :econnrefused}}] = Enum.to_list(stream)
    assert attempts() == 4
  end

  # No retry after the first body chunk: the stream is a 200.
  test "a stream that drops before [DONE] yields no done event and is not retried" do
    stub([delta(%{content: "Hel"}), delta(%{}, "stop")])
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, session_id: "s")
    assert Enum.to_list(stream) == [{:text_delta, "Hel"}]
    assert_received {:request, _, _}
    refute_received {:request, _, _}
  end

  describe "retry before the stream starts" do
    @no_wait [{"retry-after-ms", "0"}]
    @streamed [{:text_delta, "ok"}, {:done, %{stop_reason: :end_turn, usage: %Helyx.Usage{}}}]
    # The shortest first backoff wait: 0.5 s less 25%.
    @min_backoff_ms 375

    for status <- [408, 409, 429, 500, 501, 503, 599] do
      test "a #{status} is retried and the stream after it reaches the session" do
        sequence([error_reply(unquote(status), @no_wait), ok()])

        assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
        assert Enum.to_list(stream) == @streamed
        assert attempts() == 2
      end
    end

    for status <- [400, 401, 404, 422] do
      test "a #{status} is not retried" do
        sequence([error_reply(unquote(status), @no_wait)])

        assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
        assert Enum.to_list(stream) == [http_error(unquote(status), "busy")]
        assert attempts() == 1
      end
    end

    test "a 307 is not followed: one request, and the status is the error" do
      sequence([error_reply(307, [{"location", "/again"}]), ok()])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == [http_error(307, "busy")]
      assert attempts() == 1
    end

    test "at most 3 retries, then the last status is the error" do
      sequence([error_reply(429, @no_wait)])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == [http_error(429, "busy")]
      assert attempts() == 4
    end

    test "retry-after-ms wins over retry-after, and retry-after takes seconds" do
      sequence([
        error_reply(503, [{"retry-after-ms", "0"}, {"retry-after", "120"}]),
        error_reply(503, [{"retry-after", "0"}]),
        ok()
      ])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == @streamed
      assert attempts() == 3
    end

    test "3 failures and then a stream: the stream reaches the session" do
      sequence([
        error_reply(429, @no_wait),
        error_reply(500, @no_wait),
        error_reply(503, @no_wait),
        ok()
      ])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == @streamed
      assert attempts() == 4
    end

    test "a server delay over 60 s ends the turn with the status and the delay" do
      sequence([error_reply(429, [{"retry-after-ms", "60001"}])])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == [{:error, {:retry_after_over_limit, 429, 60_001}}]
      assert attempts() == 1
    end

    test "an invalid retry-after-ms leaves retry-after in force" do
      for ms <- ["-1", "1e306", "1.5", "soon", String.duplicate("9", 13)] do
        sequence([error_reply(429, [{"retry-after-ms", ms}, {"retry-after", "120"}])])

        assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
        assert Enum.to_list(stream) == [{:error, {:retry_after_over_limit, 429, 120_000}}]
      end
    end

    test "a 12-digit delay parses and goes over the limit" do
      sequence([error_reply(429, [{"retry-after", String.duplicate("9", 12)}])])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")

      assert Enum.to_list(stream) == [
               {:error, {:retry_after_over_limit, 429, 999_999_999_999_000}}
             ]
    end

    test "after the last retry, a delay over the limit still names the delay" do
      sequence([
        error_reply(429, @no_wait),
        error_reply(429, @no_wait),
        error_reply(429, @no_wait),
        error_reply(429, [{"retry-after", "120"}])
      ])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == [{:error, {:retry_after_over_limit, 429, 120_000}}]
      assert attempts() == 4
    end

    test "Req's default options cannot turn on its own retry or raise on a status" do
      Application.put_env(:req, :default_options,
        retry: :transient,
        retry_log_level: false,
        http_errors: :raise
      )

      on_exit(fn -> Application.delete_env(:req, :default_options) end)
      sequence([error_reply(429, @no_wait)])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == [http_error(429, "busy")]
      assert attempts() == 4
    end

    # The date has whole seconds; the margin covers a loaded machine.
    @load_ms 20_000

    test "retry-after as an HTTP date is a delay from now" do
      date =
        DateTime.utc_now()
        |> DateTime.add(120)
        |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

      sequence([error_reply(503, [{"retry-after", date}])])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert [{:error, {:retry_after_over_limit, 503, ms}}] = Enum.to_list(stream)
      assert ms in (120_000 - @load_ms)..120_000
    end

    test "with no usable server delay, the wait is the backoff" do
      sequence([error_reply(503, [{"retry-after", "soon"}]), ok()])
      started = System.monotonic_time(:millisecond)

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == @streamed
      assert System.monotonic_time(:millisecond) - started >= @min_backoff_ms
      assert attempts() == 2
    end

    test "a transport error before the response is retried" do
      sequence([&Req.Test.transport_error(&1, :closed), ok()])

      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == @streamed
      assert attempts() == 2
    end

    # A wait of exactly 60 s is taken; the interrupt ends it.
    test "an interrupt during a wait ends the turn at once" do
      sequence([error_reply(429, [{"retry-after", "60"}]), ok()])

      {:ok, state} = OpenAI.Go.init("m", [], session_id: "s")
      {:ok, _, state} = OpenAI.Go.request({:turn, "t1", %Helyx.Context{}}, :from, state)
      assert_receive {:attempt, 1}, Helyx.Test.Events.wait_ms()
      task = state.task
      ref = task.ref
      # The Task is still in its wait: it sent no result.
      refute_receive {^ref, _}, 100

      assert {:ok, [{:reply, :r, :ok}], _} = OpenAI.Go.request({:interrupt, "t1"}, :r, state)
      refute Process.alive?(task.pid)
      refute_received {:attempt, 2}
    end
  end

  # Answers attempt n with the nth handler, and later attempts with the last.
  defp sequence(handlers) do
    test = self()
    count = :counters.new(1, [])

    plug(fn conn ->
      :counters.add(count, 1, 1)
      n = :counters.get(count, 1)
      send(test, {:attempt, n})
      Enum.at(handlers, n - 1, List.last(handlers)).(conn)
    end)
  end

  defp attempts,
    do: Enum.count(Process.info(self(), :messages) |> elem(1), &match?({:attempt, _}, &1))

  defp error_reply(status, headers) do
    &(&1 |> Plug.Conn.merge_resp_headers(headers) |> Plug.Conn.send_resp(status, "busy"))
  end

  defp ok, do: &reply(&1, [delta(%{content: "ok"}, "stop"), "[DONE]"])

  # The provider callbacks come from `Helyx.Provider.Loop`; the test
  # process stands in for the provider process.
  test "through the helper, every call goes to Core at once and the results join in call order" do
    stub([
      delta(%{
        tool_calls: [%{index: 0, id: "c1", function: %{name: "read", arguments: ~s({"a": 1})}}]
      }),
      delta(%{
        tool_calls: [%{index: 1, id: "c2", function: %{name: "read", arguments: ~s({"c": 1})}}]
      }),
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
             {:message_end, :tool_use, %Helyx.Usage{}},
             {:tool_request, "c1", "read", %{"a" => 1}},
             {:tool_request, "c2", "read", %{"c" => 1}},
             {:tool_request, "c3", "bash", %{"b" => 1}}
           ] = events

    {:ok, [{:reply, :r3, :ok}], state} =
      OpenAI.Go.request({:tool_result, "t1", "c3", {:ok, "three"}}, :r3, state)

    {:ok, [{:reply, :r2, :ok}], state} =
      OpenAI.Go.request({:tool_result, "t1", "c2", {:error, "two"}}, :r2, state)

    {:ok, [{:reply, :r1, :ok} | actions], _state} =
      OpenAI.Go.request({:tool_result, "t1", "c1", {:ok, "one"}}, :r1, state)

    assert actions == [
             {:event, "t1", {:tool_result, "c1", {:ok, "one"}}},
             {:event, "t1", {:tool_result, "c2", {:error, "two"}}},
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

  defp models(config) do
    Application.put_env(:helyx_plugins, :models, config)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :models) end)
  end

  # `docs/features/usage-and-limits.md`, "Config": the gateways report no
  # price and no window.
  test "config gives the window and the prices of the ref; a bad entry fails the call with its key" do
    usage = %{prompt_tokens: 1_000_000, completion_tokens: 1_000_000}
    stub([delta(%{content: "Hi"}, "stop"), %{choices: [], usage: usage}, "[DONE]"])
    entry = [context_window: 262_144, prices: [input: 0.6, output: 2.5]]
    models(%{"opencode-go/no-catalog-model" => entry})

    assert {:ok, stream} = OpenAI.Go.stream("no-catalog-model", %Helyx.Context{}, session_id: "s")
    assert {:done, %{usage: priced}} = List.last(Enum.to_list(stream))
    assert %Helyx.Usage{context_window: 262_144, cost_kind: :list} = priced
    assert_in_delta priced.cost, 3.1, 1.0e-9

    # With no config entry, the `catalog:` of the endpoint gives the window
    # and the prices: the bundled snapshot (`test_helper.exs`).
    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2.7-code", %Helyx.Context{}, session_id: "s")
    assert {:done, %{usage: priced}} = List.last(Enum.to_list(stream))
    assert %Helyx.Usage{context_window: 262_144, cost_kind: :list} = priced
    assert_in_delta priced.cost, 4.95, 1.0e-9

    # The other endpoint has no config entry and no catalog: no window, no
    # cost, and the call does not fail.
    assert {:ok, stream} = Local.stream("no-catalog-model", %Helyx.Context{}, session_id: "s")

    assert {:done, %{usage: %Helyx.Usage{context_window: nil, cost: nil}}} =
             List.last(Enum.to_list(stream))

    models(%{"opencode-go/no-catalog-model" => [context_window: 0]})

    assert OpenAI.Go.stream("no-catalog-model", %Helyx.Context{}, session_id: "s") ==
             {:error, {:bad_config, [:models, "opencode-go/no-catalog-model", :context_window]}}
  end

  test "an :openai_req_options value that is not a keyword list fails the call with its key before any request" do
    on_exit(fn -> Application.delete_env(:helyx_plugins, :openai_req_options) end)

    for value <- [:plug, %{plug: nil}, [1], [{"plug", nil}], [{:plug, nil} | :tail]] do
      Application.put_env(:helyx_plugins, :openai_req_options, value)

      assert OpenAI.Go.stream("kimi-k2", %Helyx.Context{}, session_id: "s") ==
               {:error, {:bad_config, [:openai_req_options]}}
    end
  end

  test "a keyword list in :openai_req_options goes to Req as it is, and a later option wins" do
    on_exit(fn -> Application.delete_env(:helyx_plugins, :openai_req_options) end)
    test = self()
    fail = &Plug.Conn.send_resp(&1, 400, "first plug")

    pass = fn conn ->
      send(test, {:header, Plug.Conn.get_req_header(conn, "x-a")})
      send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      reply(conn, [delta(%{content: "Hi"}, "stop"), "[DONE]"])
    end

    Application.put_env(:helyx_plugins, :openai_req_options,
      plug: fail,
      headers: [{"x-a", "1"}],
      auth: {:bearer, "other"},
      plug: pass
    )

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", %Helyx.Context{}, session_id: "s")
    assert {:text_delta, "Hi"} in Enum.to_list(stream)
    assert_received {:header, ["1"]}
    # The env comes after the options of the provider, so it replaces the key.
    assert_received {:auth, ["Bearer other"]}
  end

  # The seam is for tests only (`docs/features/coding-agent.md`); it comes
  # after the options of the engine, so it can replace the user agent too.
  test "the :openai_req_options seam can replace the user agent" do
    test = self()

    Application.put_env(:helyx_plugins, :openai_req_options,
      user_agent: "other",
      plug: fn conn ->
        send(test, {:user_agent, Plug.Conn.get_req_header(conn, "user-agent")})
        reply(conn, [delta(%{content: "Hi"}, "stop"), "[DONE]"])
      end
    )

    on_exit(fn -> Application.delete_env(:helyx_plugins, :openai_req_options) end)

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert {:text_delta, "Hi"} in Enum.to_list(stream)
    assert_received {:user_agent, ["other"]}
  end

  test "a missing or empty api key is an error before any request" do
    plug(fn _conn -> flunk("no request") end)
    context = %Helyx.Context{messages: [Helyx.Message.user("hi")]}
    System.delete_env("OPENCODE_API_KEY")

    assert {:error, {:missing_env, "OPENCODE_API_KEY"}} =
             OpenAI.Go.stream("kimi-k2", context, session_id: "s")

    System.put_env("OPENCODE_API_KEY", "")

    assert {:error, {:missing_env, "OPENCODE_API_KEY"}} =
             OpenAI.Go.stream("kimi-k2", context, session_id: "s")
  end

  @max_key_bytes 4_096

  test "a bearer token of #{@max_key_bytes} bytes is sent; any other key is :bad_env" do
    test = self()

    plug(fn conn ->
      send(test, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      reply(conn, [delta(%{content: "Hi"}, "stop"), "[DONE]"])
    end)

    key = String.duplicate("k", @max_key_bytes - 8) <> "-._~+/=="
    System.put_env("OPENCODE_API_KEY", key)
    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert {:text_delta, "Hi"} in Enum.to_list(stream)
    assert_received {:auth, ["Bearer " <> ^key]}

    for bad <- [
          String.duplicate("k", @max_key_bytes + 1),
          "a b",
          "a\tb",
          "a\rb",
          "a\nb",
          "a" <> <<0x7F>>,
          "clé",
          ~s(a"b),
          "a\\b",
          "a*",
          "a=b",
          "=",
          "a!"
        ] do
      System.put_env("OPENCODE_API_KEY", bad)

      assert OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s") ==
               {:error, {:bad_env, "OPENCODE_API_KEY"}}
    end

    refute_received {:auth, _}
  end

  test "a key that the server echoes in an error body is masked" do
    plug(&Plug.Conn.send_resp(&1, 401, "bad key test-key, test-key"))

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")

    assert Enum.to_list(stream) ==
             [http_error(401, "bad key ********, ********")]

    # With no key, nothing is masked.
    assert {:ok, stream} = Local.stream("m", %Helyx.Context{}, session_id: "s")
    assert Enum.to_list(stream) == [http_error(401, "bad key test-key, test-key", "local")]
  end

  test "an error with a text shows the provider id and the text; one with none keeps its term" do
    plug(&Plug.Conn.send_resp(&1, 401, "bad key"))
    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, reason}] = Enum.to_list(stream)
    assert Helyx.Reason.text(reason) == "opencode-go: bad key"

    plug(&Plug.Conn.send_resp(&1, 401, ""))
    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert Enum.to_list(stream) == [{:error, {:http_status, 401, ""}}]

    for error <- [%{code: 1}, %{message: ""}, %{message: 1}, "rate limited"] do
      stub([%{error: error}])
      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert [{:error, {:api_error, _}}] = Enum.to_list(stream)
    end
  end

  # Dropped after the mask, the invalid byte would join the key again.
  test "an invalid byte in a key in an error body does not join it" do
    plug(&Plug.Conn.send_resp(&1, 401, "bad test" <> <<255>> <> "-key"))
    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert Enum.to_list(stream) == [http_error(401, "bad test\uFFFD-key")]
  end

  # Dropped, the invalid bytes would move the part of the key at the end
  # of the read to a place under the cut.
  test "invalid bytes before a part of the key at the end of the read move nothing back" do
    key = "sk-" <> String.duplicate("S", 96) <> "Z"
    System.put_env("OPENCODE_API_KEY", key)

    plug(fn conn ->
      conn = Plug.Conn.send_chunked(conn, 401)
      head = String.duplicate(<<255>>, 1_200) <> String.duplicate("a", 1_002)
      {:ok, conn} = Plug.Conn.chunk(conn, head <> binary_part(key, 0, 99))
      {:ok, conn} = Plug.Conn.chunk(conn, "Z")
      conn
    end)

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, %ProviderError{text: text}}] = Enum.to_list(stream)
    refute text =~ "sk-"
    assert text == binary_part(String.duplicate("\uFFFD", 1_200), 0, 1_998)
  end

  test "an api_error message is cut at 2,000 bytes, after the mask" do
    stub([%{error: %{message: String.duplicate("a", 1_998) <> "test-key"}}])
    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, %ProviderError{text: text}}] = Enum.to_list(stream)
    assert text == String.duplicate("a", 1_998) <> "**"
  end

  test "an api_error with a large object keeps its message" do
    stub([%{error: %{message: "slow", details: List.duplicate(0, 10_001)}}])
    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, reason}] = Enum.to_list(stream)
    assert Helyx.Reason.text(reason) == "opencode-go: slow"
  end

  test "a key in an error of the stream after a 200 is masked" do
    for {events, error} <- [
          {[%{error: %{message: "bad test-key", "test-key": ["test-key"]}}],
           %ProviderError{
             provider: "opencode-go",
             kind: :api_error,
             text: "bad ********"
           }},
          {["not json test-key"], {:bad_chunk, "not json ********"}}
        ] do
      stub(events)
      assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
      assert Enum.to_list(stream) == [{:error, error}]
    end
  end

  # Core rejects a delta that is not a string, and its error holds the event.
  test "a key in any event is masked, also in a delta that Core rejects" do
    stub([
      delta(%{content: %{x: "test-key"}}),
      delta(%{content: "say test-key"}, "stop"),
      "[DONE]"
    ])

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")

    assert [{:text_delta, %{"x" => "********"}}, {:text_delta, "say ********"}, {:done, _}] =
             Enum.to_list(stream)
  end

  # A tool call event is a struct: the mask walks its fields.
  test "a key in the fields of a tool call is masked" do
    stub([
      delta(%{
        tool_calls: [
          %{
            index: 0,
            id: "call_test-key",
            type: "function",
            function: %{name: "bash", arguments: ~s({"command": "echo test-key"})}
          }
        ]
      }),
      delta(%{}, "tool_calls"),
      "[DONE]"
    ])

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")

    assert [{:tool_call, call}, {:done, _}] = Enum.to_list(stream)

    assert call == %Helyx.Message.ToolCall{
             id: "call_********",
             name: "bash",
             arguments: %{"command" => "echo ********"}
           }
  end

  # A common JSON encoder escapes no character of a bearer token but `/`.
  # The `\uXXXX` forms are accepted holes (`docs/features/openai-compatible.md`).
  test "a key that the server echoes in JSON with an escaped slash is masked" do
    System.put_env("OPENCODE_API_KEY", "sk-ab/cd")
    plug(&Plug.Conn.send_resp(&1, 401, ~S({"error":"bad sk-ab\/cd or sk-ab/cd"})))

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")

    assert Enum.to_list(stream) ==
             [http_error(401, ~S({"error":"bad ********* or ********"}))]
  end

  test "with no key_env, no auth of Req's default options is sent" do
    Application.put_env(:req, :default_options, auth: {:bearer, "other"})
    on_exit(fn -> Application.delete_env(:req, :default_options) end)
    stub([delta(%{content: "Hi"}, "stop"), "[DONE]"])

    assert {:ok, stream} = Local.stream("m", %Helyx.Context{}, session_id: "s")
    assert {:text_delta, "Hi"} in Enum.to_list(stream)
    assert_received {:request, conn, _body}
    assert Plug.Conn.get_req_header(conn, "authorization") == []
  end

  @max_text_bytes 2_000

  test "an error body of #{@max_text_bytes} bytes arrives whole" do
    body = String.duplicate("a", @max_text_bytes)
    plug(&Plug.Conn.send_resp(&1, 400, body))

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert Enum.to_list(stream) == [http_error(400, body)]
  end

  test "an error body over the limit is cut" do
    body = String.duplicate("a", @max_text_bytes + 1)
    plug(&Plug.Conn.send_resp(&1, 400, body))

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, %ProviderError{kind: 400, text: cut}}] = Enum.to_list(stream)

    assert cut == binary_part(body, 0, @max_text_bytes)
  end

  # The first chunk ends at the limit with a part of the key; the read goes
  # on until the key is whole, then the cut comes after the mask.
  test "a key across the limit and across chunks is masked before the cut" do
    head = String.duplicate("a", @max_text_bytes - 3)

    plug(fn conn ->
      conn = Plug.Conn.send_chunked(conn, 401)
      {:ok, conn} = Plug.Conn.chunk(conn, head <> "tes")
      {:ok, conn} = Plug.Conn.chunk(conn, "t")
      {:ok, conn} = Plug.Conn.chunk(conn, "-key" <> String.duplicate("b", 100))
      conn
    end)

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, %ProviderError{kind: 401, text: cut}}] = Enum.to_list(stream)

    assert cut == head <> "***"
  end

  # The escaped form is longer than the key: 8 bytes for a key of 5. With a
  # read of only the key size past the limit, the first chunk would end it.
  test "an escaped key across the limit is whole when it is masked" do
    System.put_env("OPENCODE_API_KEY", "a///b")
    head = String.duplicate("x", @max_text_bytes - 1)

    plug(fn conn ->
      conn = Plug.Conn.send_chunked(conn, 401)
      {:ok, conn} = Plug.Conn.chunk(conn, head <> ~S(a\/\/\/))
      {:ok, conn} = Plug.Conn.chunk(conn, "b" <> String.duplicate("y", 20))
      conn
    end)

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, %ProviderError{kind: 401, text: cut}}] = Enum.to_list(stream)
    assert cut == head <> "*"
  end

  # Many copies of a long key, and a part of one more at the end of the
  # read: the mask keeps every position, so the part is past the cut.
  test "a part of the key at the end of the read stays past the cut" do
    key = "sk-" <> String.duplicate("S", 97)
    System.put_env("OPENCODE_API_KEY", key)
    copies = String.duplicate(key, div(@max_text_bytes, 100) + 1)

    plug(fn conn ->
      conn = Plug.Conn.send_chunked(conn, 401)
      {:ok, conn} = Plug.Conn.chunk(conn, copies <> binary_part(key, 0, 90))
      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(key, 90, 10))
      conn
    end)

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, %ProviderError{kind: 401, text: cut}}] = Enum.to_list(stream)

    assert cut == String.duplicate("*", @max_text_bytes)
  end

  test "an endpoint option outside its bound fails with its name" do
    good = [id: "x", base_url: "http://h/v1"]
    long = &String.duplicate("a", &1)

    bad = [
      id: "a/b",
      id: "",
      id: "a b",
      id: :x,
      base_url: "ftp://h/v1",
      base_url: "h/v1",
      base_url: "https://",
      base_url: "http://h/" <> <<255>>,
      base_url: "http://h/v1?api-version=1",
      base_url: "http://h/v1#x",
      key_env: "",
      key_env: "1X",
      key_env: "A-B",
      key_env: "_" <> long.(256),
      key_env: :x,
      headers: {"x", "y"},
      headers: [{"authorization", "x"}],
      headers: [{"User-Agent", "x"}],
      headers: [{"a b", "x"}],
      headers: [{"", "x"}],
      headers: [{long.(257), "x"}],
      headers: [{"x", long.(4097)}],
      headers: [{"x", "a\nb"}],
      headers: [{"x", "é"}],
      headers: [{"x", :turn_id}],
      headers: [{:x, "y"}],
      headers: List.duplicate({"x", "y"}, 17),
      catalog: "",
      catalog: "opencode",
      catalog: :x
    ]

    for {key, value} <- bad do
      assert_raise ArgumentError, ~r/option #{key}:/, fn ->
        Endpoint.new!(Keyword.put(good, key, value))
      end
    end

    # At the limits.
    header = {long.(256), long.(4096)}
    max = [headers: List.duplicate(header, 16), key_env: "_" <> long.(255), catalog: "openai"]
    assert %Endpoint{} = Endpoint.new!(good ++ max)

    assert_raise KeyError, fn -> Endpoint.new!(good ++ [base: "x"]) end
    assert_raise ArgumentError, fn -> Endpoint.new!(base_url: "http://h") end
    assert_raise ArgumentError, fn -> Endpoint.new!(%{id: "x"}) end

    # Through `use`, the compile of the endpoint module fails.
    assert_raise ArgumentError, ~r/option headers:/, fn ->
      Code.compile_quoted(
        quote do
          defmodule Helyx.Provider.OpenAITest.Bad do
            use Helyx.Provider.OpenAI,
              id: "bad",
              base_url: "http://h",
              headers: [{"User-Agent", "x"}]
          end
        end
      )
    end
  end

  test "an error body cut inside a multibyte character retreats to a boundary" do
    body = String.duplicate("a", @max_text_bytes - 2) <> "😀😀"
    plug(&Plug.Conn.send_resp(&1, 400, body))

    assert {:ok, stream} = OpenAI.Go.stream("m", %Helyx.Context{}, session_id: "s")
    assert [{:error, %ProviderError{kind: 400, text: cut}}] = Enum.to_list(stream)

    assert cut == String.duplicate("a", @max_text_bytes - 2)

    assert String.valid?(cut)
  end
end
