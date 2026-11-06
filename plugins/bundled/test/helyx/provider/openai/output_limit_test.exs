defmodule Helyx.Provider.OpenAI.OutputLimitTest do
  # The session's `:max_output_tokens` in the body of the OpenAI wire
  # format, in the field that the endpoint names
  # (docs/features/output-limit.md). Req's plug adapter stands in for the
  # server; nothing here touches the network. Not async: the tests set the
  # :openai_req_options app env.
  use ExUnit.Case, async: false

  import Helyx.Test.Events, only: [collect_until: 1, messages: 1, of_type: 2]

  alias Helyx.Provider.OpenAI.Endpoint
  alias Helyx.Session

  @moduletag :tmp_dir

  # A server of the older field, with no key.
  defmodule Old do
    @moduledoc false
    use Helyx.Provider.OpenAI,
      id: "old",
      base_url: "http://localhost:11434/v1",
      max_tokens_field: :max_tokens
  end

  # A server of the default field, with no key.
  defmodule New do
    @moduledoc false
    use Helyx.Provider.OpenAI, id: "new", base_url: "http://localhost:11434/v1"
  end

  setup do
    on_exit(fn -> Application.delete_env(:helyx_plugins, :openai_req_options) end)
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Old,
      New,
      Helyx.Provider.Fake,
      Helyx.Provider.ClaudeCode,
      Helyx.Provider.Codex
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    %{core: core}
  end

  defp delta(delta, finish \\ nil), do: %{choices: [%{delta: delta, finish_reason: finish}]}

  # Each request body goes to the test; the replies are the lists of
  # `replies` as SSE, one for each request, the last one again.
  defp stub(replies) do
    test = self()
    {:ok, left} = Agent.start_link(fn -> replies end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:body, JSON.decode!(body)})

      chunks =
        Agent.get_and_update(left, fn
          [one] -> {one, [one]}
          [one | rest] -> {one, rest}
        end)

      sse =
        Enum.map_join(chunks, &"data: #{if is_binary(&1), do: &1, else: JSON.encode!(&1)}\n\n")

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse)
    end

    Application.put_env(:helyx_plugins, :openai_req_options, plug: plug)
  end

  defp turn(core, dir, model, opts) do
    {:ok, session} = Session.start(core, [model: model, cwd: dir] ++ opts)
    {:ok, _snapshot, _ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "hi")
    events = collect_until(:turn_end)
    assert_received {:body, body}
    {events, body}
  end

  @ok [%{choices: [%{delta: %{content: "ok"}, finish_reason: "stop"}]}, "[DONE]"]

  test "the limit goes in the field that the endpoint names", %{core: core, tmp_dir: dir} do
    stub([@ok])

    {_events, body} = turn(core, dir, "new/m", max_output_tokens: 5)
    assert body["max_completion_tokens"] == 5
    refute Map.has_key?(body, "max_tokens")

    {_events, body} = turn(core, dir, "old/m", max_output_tokens: 2_147_483_647)
    assert body["max_tokens"] == 2_147_483_647
    refute Map.has_key?(body, "max_completion_tokens")
  end

  test "without the limit the body is as before", %{core: core, tmp_dir: dir} do
    stub([@ok])

    for model <- ["new/m", "old/m"], opts <- [[], [max_output_tokens: nil]] do
      {_events, body} = turn(core, dir, model, opts)
      assert Map.keys(body) |> Enum.sort() == ~w(messages model stream stream_options)
    end
  end

  test "a reply cut at the limit stops with :max_tokens and runs no tool call", %{
    core: core,
    tmp_dir: dir
  } do
    stub([
      [
        delta(%{content: "Reading"}),
        delta(%{tool_calls: [%{index: 0, id: "c1", function: %{name: "read", arguments: "{}"}}]}),
        delta(%{}, "length"),
        "[DONE]"
      ],
      @ok
    ])

    {events, body} = turn(core, dir, "new/m", max_output_tokens: 3)
    assert body["max_completion_tokens"] == 3
    # The next model call of the turn carries the limit too.
    assert_received {:body, %{"max_completion_tokens" => 3}}

    assert [%{role: :user}, cut, last] = messages(events)
    assert cut.stop_reason == :max_tokens
    assert [%{message: result}] = of_type(events, :tool_execution_end)
    assert %{role: :tool_result, tool_call_id: "c1", is_error: true} = result
    assert Helyx.Message.text(result) == "tool call not run: the reply was cut at the token limit"
    assert last.stop_reason == :end_turn
  end

  test "a provider that cannot apply the limit refuses it at the start", %{
    core: core,
    tmp_dir: dir
  } do
    for {model, id} <- [
          {"fake/echo", "fake"},
          {"claude-code/sonnet", "claude-code"},
          {"codex/gpt-5", "codex"}
        ] do
      assert Session.start(core, model: model, cwd: dir, max_output_tokens: 5) ==
               {:error, {:max_output_tokens_unsupported, id}}
    end
  end

  test "an endpoint option outside the two fields fails the compile" do
    for bad <- [:foo, "max_tokens", nil] do
      assert_raise ArgumentError, ~r/max_tokens_field/, fn ->
        Endpoint.new!(id: "x", base_url: "http://localhost", max_tokens_field: bad)
      end
    end
  end
end
