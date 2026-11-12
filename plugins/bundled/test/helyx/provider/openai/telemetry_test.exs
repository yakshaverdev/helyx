defmodule Helyx.Provider.OpenAI.TelemetryTest do
  # The seam of the attempt event: `stream/3` on the plugin module with Req's
  # test adapter, so nothing touches the network. Not async: the tests
  # mutate OPENCODE_API_KEY and the :openai_req_options app env, and a
  # telemetry handler is global.
  use ExUnit.Case, async: false

  alias Helyx.Provider.OpenAI

  @event [:helyx, :provider, :attempt]
  @keys [:attempt, :decision, :error, :model, :provider, :status, :wait_ms]

  setup do
    System.put_env("OPENCODE_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("OPENCODE_API_KEY") end)
    on_exit(fn -> Application.delete_env(:helyx_plugins, :openai_req_options) end)

    test = self()
    id = {__MODULE__, System.unique_integer([:positive])}

    :ok = :telemetry.attach(id, @event, &__MODULE__.send_attempt/4, %{test: test})

    on_exit(fn -> :telemetry.detach(id) end)
    :ok
  end

  @doc false
  def send_attempt(event, measurements, metadata, %{test: test}),
    do: send(test, {:attempt, event, measurements, metadata})

  defp context, do: %Helyx.Context{messages: [Helyx.Message.user("hi")]}

  defp sse(chunks) do
    Enum.map_join(chunks, fn
      chunk when is_binary(chunk) -> "data: #{chunk}\n\n"
      chunk -> "data: #{JSON.encode!(chunk)}\n\n"
    end)
  end

  defp ok do
    events = [
      %{choices: [%{delta: %{content: "ok"}, finish_reason: "stop"}]},
      "[DONE]"
    ]

    &(&1
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse(events)))
  end

  defp error_reply(status, headers) do
    &(&1 |> Plug.Conn.merge_resp_headers(headers) |> Plug.Conn.send_resp(status, "busy"))
  end

  # Answers attempt n with the nth handler, and later attempts with the last.
  defp sequence(handlers) do
    count = :counters.new(1, [])

    Application.put_env(:helyx_plugins, :openai_req_options,
      plug: fn conn ->
        :counters.add(count, 1, 1)
        Enum.at(handlers, :counters.get(count, 1) - 1, List.last(handlers)).(conn)
      end
    )
  end

  # The events of a stream, in order: the measurement and the metadata of
  # each.
  defp attempt do
    assert_receive {:attempt, @event, measurements, metadata}
    {measurements, metadata}
  end

  test "a 200 emits one event: the first attempt, the status, the decision, and the time" do
    sequence([ok()])

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context(), session_id: "s")
    assert [{:text_delta, "ok"}, {:done, _}] = Enum.to_list(stream)

    assert {%{duration: duration}, metadata} = attempt()
    assert is_integer(duration) and duration >= 0

    assert metadata == %{
             provider: "opencode-go",
             model: "kimi-k2",
             attempt: 0,
             status: 200,
             error: nil,
             decision: :ok,
             wait_ms: nil
           }
  end

  test "a 429 with a server wait, then a 200: a wait event and then the attempt after it" do
    sequence([error_reply(429, [{"retry-after-ms", "1"}]), ok()])

    assert {:ok, stream} = OpenAI.Go.stream("m", context(), session_id: "s")
    assert [{:text_delta, "ok"}, {:done, _}] = Enum.to_list(stream)

    assert {_measurements, first} = attempt()
    assert first.attempt == 0
    assert first.status == 429
    assert first.error == nil
    assert first.decision == :wait
    assert first.wait_ms == 1

    assert {_measurements, second} = attempt()
    assert second.attempt == 1
    assert second.status == 200
    assert second.decision == :ok
    assert second.wait_ms == nil
  end

  test "a server wait over the limit ends the turn, and the event says too_long" do
    sequence([error_reply(429, [{"retry-after-ms", "60001"}])])

    assert {:ok, stream} = OpenAI.Go.stream("m", context(), session_id: "s")
    assert Enum.to_list(stream) == [{:error, {:retry_after_over_limit, 429, 60_001}}]

    assert {_measurements, metadata} = attempt()
    assert metadata.attempt == 0
    assert metadata.status == 429
    assert metadata.decision == :too_long
    assert metadata.wait_ms == 60_001
  end

  test "four 503 answers: four events, and the last one gives up on attempt 3" do
    sequence([error_reply(503, [{"retry-after-ms", "0"}])])

    assert {:ok, stream} = OpenAI.Go.stream("m", context(), session_id: "s")
    assert [{:error, _reason}] = Enum.to_list(stream)

    events = for _ <- 1..4, do: attempt()

    assert Enum.map(events, fn {_measurements, metadata} ->
             {metadata.attempt, metadata.status}
           end) ==
             [{0, 503}, {1, 503}, {2, 503}, {3, 503}]

    assert for({_measurements, metadata} <- events, do: metadata.decision) ==
             [:wait, :wait, :wait, :give_up]

    assert List.last(events) |> elem(1) |> Map.fetch!(:wait_ms) == nil
  end

  test "a 400 is not retried, and the event says fail" do
    sequence([error_reply(400, [])])

    assert {:ok, stream} = OpenAI.Go.stream("m", context(), session_id: "s")
    assert [{:error, _reason}] = Enum.to_list(stream)

    assert {_measurements, metadata} = attempt()
    assert metadata.status == 400
    assert metadata.error == nil
    assert metadata.decision == :fail
    assert metadata.wait_ms == nil
  end

  test "a transport error, then a 200: no status, the reason, and a wait" do
    sequence([&Req.Test.transport_error(&1, :econnrefused), ok()])

    assert {:ok, stream} = OpenAI.Go.stream("m", context(), session_id: "s")
    assert [{:text_delta, "ok"}, {:done, _}] = Enum.to_list(stream)

    assert {_measurements, first} = attempt()
    assert first.attempt == 0
    assert first.status == nil
    assert first.error == :econnrefused
    assert first.decision == :wait

    assert {_measurements, second} = attempt()
    assert second.attempt == 1
    assert second.decision == :ok
  end

  test "the metadata holds the seven keys of the contract and no content of the call" do
    marker = "marker-#{System.unique_integer([:positive])}"
    context = %Helyx.Context{system: marker, messages: [Helyx.Message.user(marker)]}
    sequence([ok()])

    assert {:ok, stream} = OpenAI.Go.stream("kimi-k2", context, session_id: "s")
    assert [{:text_delta, "ok"}, {:done, _}] = Enum.to_list(stream)

    assert {_measurements, metadata} = attempt()
    assert metadata |> Map.keys() |> Enum.sort() == @keys
    refute metadata |> inspect() |> String.contains?(marker)
  end
end
