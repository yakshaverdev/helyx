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
        receive_timeout: @chunk_idle_ms
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
  defp chunks(req) do
    Stream.flat_map([req], fn req ->
      case Req.post(req) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          body

        {:ok, %Req.Response{status: status} = resp} ->
          [{:error, {:http_status, status, drain(resp)}}]

        {:error, reason} ->
          [{:error, reason}]
      end
    end)
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
