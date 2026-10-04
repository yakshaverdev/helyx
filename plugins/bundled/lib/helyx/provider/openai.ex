defmodule Helyx.Provider.OpenAI do
  @moduledoc """
  A model provider that speaks the OpenAI chat completions wire format with
  server-sent event streaming, against the OpenCode gateways.

  The engine lives here, with the SSE parser in an internal module. The
  plugins are the nested modules, one per model ref prefix, each bound to
  one base URL:

    * `Helyx.Provider.OpenAI.Go`: `opencode-go/<model>`, OpenCode Go
    * `Helyx.Provider.OpenAI.Zen`: `opencode/<model>`, OpenCode Zen

  The API key comes from `OPENCODE_API_KEY`. Every request carries the
  session id in the `x-opencode-session` header so the gateway can track the
  session.

  A request that fails before the stream starts runs again, at most 3
  times: on a 408, 409, 429, or 5xx, and on a transport error. A server
  delay over 60 s fails the call at once with `{:retry_after_over_limit,
  status, delay_ms}`. An abort ends a wait at once. The waits and bounds:
  `docs/features/coding-agent.md` (#479).
  """

  defmodule Go do
    @moduledoc "The OpenCode Go endpoint. See `Helyx.Provider.OpenAI`."
    use Helyx.Provider.Loop

    @impl true
    def id, do: "opencode-go"

    @impl true
    def stream(model, context, opts),
      do: Helyx.Provider.OpenAI.stream(model, context, opts, "https://opencode.ai/zen/go/v1")
  end

  defmodule Zen do
    @moduledoc "The OpenCode Zen endpoint. See `Helyx.Provider.OpenAI`."
    use Helyx.Provider.Loop

    @impl true
    def id, do: "opencode"

    @impl true
    def stream(model, context, opts),
      do: Helyx.Provider.OpenAI.stream(model, context, opts, "https://opencode.ai/zen/v1")
  end

  alias Helyx.Provider.OpenAI.Events

  @env_var "OPENCODE_API_KEY"
  # The longest wait for the next body chunk (Req's `receive_timeout`).
  @chunk_idle_ms 120_000

  @doc "The shared `stream/3` of the endpoint plugins. `base_url` selects the endpoint."
  @spec stream(String.t(), Helyx.Context.t(), keyword(), String.t()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(model, context, opts, base_url) do
    case System.fetch_env(@env_var) do
      {:ok, key} -> {:ok, Events.events(chunks(request(model, context, opts, base_url, key)))}
      :error -> {:error, {:missing_env, @env_var}}
    end
  end

  # Request

  defp request(model, context, opts, base_url, key) do
    Req.new(
      [
        base_url: base_url,
        url: "/chat/completions",
        auth: {:bearer, key},
        headers: session_header(opts),
        json: body(model, context),
        into: :self,
        receive_timeout: @chunk_idle_ms,
        # `post/2` owns the retries and the error responses; these override
        # Req's `:default_options`.
        retry: false,
        http_errors: :return
      ] ++ Application.get_env(:helyx_plugins, :openai_req_options, [])
    )
  end

  defp session_header(opts) do
    case Keyword.get(opts, :session_id) do
      nil -> []
      id -> [{"x-opencode-session", id}]
    end
  end

  defp body(model, context) do
    body = %{
      model: model,
      stream: true,
      stream_options: %{include_usage: true},
      messages: messages(context)
    }

    case context.tools do
      [] -> body
      tools -> Map.put(body, :tools, Enum.map(tools, &tool/1))
    end
  end

  defp tool(spec) do
    %{
      type: "function",
      function: %{name: spec.name, description: spec.description, parameters: spec.parameters}
    }
  end

  defp messages(%Helyx.Context{system: system, messages: messages}) do
    system_message = if system, do: [%{role: "system", content: system}], else: []
    system_message ++ Enum.map(messages, &message/1)
  end

  defp message(%Helyx.Message{role: :user} = message),
    do: %{role: "user", content: Helyx.Message.text(message)}

  defp message(%Helyx.Message{role: :tool_result} = message) do
    %{role: "tool", tool_call_id: message.tool_call_id, content: Helyx.Message.text(message)}
  end

  # Thinking goes back as `reasoning_content`: Kimi's thinking models need
  # the reasoning of the tool-call loop replayed to keep their chain, and
  # models that do not think produce no thinking blocks to send.
  defp message(%Helyx.Message{role: :assistant} = message) do
    %{role: "assistant", content: Helyx.Message.text(message)}
    |> put_reasoning(message)
    |> put_tool_calls(message)
  end

  defp put_reasoning(wire, message) do
    case for %Helyx.Message.Thinking{thinking: thinking} <- message.content,
             into: "",
             do: thinking do
      "" -> wire
      reasoning -> Map.put(wire, :reasoning_content, reasoning)
    end
  end

  defp put_tool_calls(wire, message) do
    case for %Helyx.Message.ToolCall{} = call <- message.content, do: wire_call(call) do
      [] -> wire
      calls -> Map.put(wire, :tool_calls, calls)
    end
  end

  defp wire_call(call) do
    %{
      id: call.id,
      type: "function",
      function: %{name: call.name, arguments: JSON.encode!(call.arguments)}
    }
  end

  # Transport: one lazy stream of body chunks. The request runs when the
  # session's turn Task consumes the stream, so the async body lands in that
  # Task's mailbox. `Req.Response.Async` is enumerable, applies
  # `receive_timeout` between chunks, and cancels the request when the
  # consumer halts. A transport error while streaming raises, which fails the
  # turn as `{:task_exit, reason}`. Elements are binaries or one
  # `{:error, reason}` tuple.
  defp chunks(req), do: Stream.flat_map([req], &post(&1, 0))

  # Only a 200 yields body chunks, so no chunk reaches the session before a
  # retry. The wait runs in the model Task, so an abort kills it at once.
  @max_retries 3
  @max_server_delay_ms 60_000

  defp post(req, retries) do
    case Req.post(req) do
      {:ok, %Req.Response{status: 200, body: body}} -> body
      result -> fail_or_retry(req, result, retries)
    end
  end

  defp fail_or_retry(req, result, retries) do
    case delay(result, retries) do
      {:wait, ms} when retries < @max_retries ->
        cancel(result)
        Process.sleep(ms)
        post(req, retries + 1)

      # Fails at once: the body is not read, so it cannot stall the error.
      {:too_long, status, ms} ->
        cancel(result)
        [{:error, {:retry_after_over_limit, status, ms}}]

      # The retries are used up.
      {:wait, _} ->
        [{:error, reason(result)}]

      :none ->
        [{:error, reason(result)}]
    end
  end

  defp cancel({:ok, resp}), do: Req.cancel_async_response(resp)
  defp cancel({:error, _}), do: :ok

  defp reason({:ok, resp}), do: {:http_status, resp.status, drain(resp)}
  defp reason({:error, reason}), do: reason

  defp delay({:ok, %Req.Response{status: status} = resp}, retries)
       when status in [408, 409, 429] or status in 500..599 do
    case server_delay(resp) do
      nil -> {:wait, backoff(retries)}
      ms when ms > @max_server_delay_ms -> {:too_long, status, ms}
      ms -> {:wait, ms}
    end
  end

  # `Req.post/1` returns at the response headers, so a transport error here
  # comes before any body chunk.
  defp delay({:error, %Req.TransportError{}}, retries), do: {:wait, backoff(retries)}
  defp delay(_result, _retries), do: :none

  defp backoff(retries),
    do: round(min(500 * 2 ** retries, 8_000) * (1 - 0.25 * :rand.uniform()))

  # The server's delay in ms: the first valid `retry-after-ms`, else the
  # first valid `retry-after` in whole seconds or as an HTTP date. A value
  # that does not parse, is negative, or is longer than `@max_delay_bytes`
  # bytes is skipped, so the delay in an error term stays small.
  @max_delay_bytes 12

  defp server_delay(resp) do
    Enum.find_value(Req.Response.get_header(resp, "retry-after-ms"), &integer_ms(&1, 1)) ||
      Enum.find_value(
        Req.Response.get_header(resp, "retry-after"),
        &(integer_ms(&1, 1_000) || date_ms(&1))
      )
  end

  defp integer_ms(value, _unit_ms) when byte_size(value) > @max_delay_bytes, do: nil

  defp integer_ms(value, unit_ms) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number * unit_ms
      _ -> nil
    end
  end

  # `Req.Utils` is internal to Req: if an update removes the function, the
  # compile in precommit fails on the warning.
  defp date_ms(value) do
    with {:ok, date} <- Req.Utils.parse_http_date(value),
         ms when ms >= 0 <- DateTime.diff(date, DateTime.utc_now(), :millisecond) do
      ms
    else
      _ -> nil
    end
  end

  # The error body names the reason for a 401 or 429; without it the turn
  # error is just a number. A diagnostic, so the limit is small; halting the
  # reduce cancels the rest of the response.
  @max_error_body_bytes 16_384

  defp drain(resp) do
    body =
      Enum.reduce_while(resp.body, "", fn chunk, body ->
        body = body <> chunk
        if byte_size(body) > @max_error_body_bytes, do: {:halt, body}, else: {:cont, body}
      end)

    if byte_size(body) > @max_error_body_bytes,
      do:
        Helyx.Text.cap(body, @max_error_body_bytes, :head) <>
          "\n[truncated at the #{@max_error_body_bytes}-byte limit]",
      else: body
  end
end
