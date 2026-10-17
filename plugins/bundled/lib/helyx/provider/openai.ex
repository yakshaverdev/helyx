defmodule Helyx.Provider.OpenAI do
  @moduledoc """
  The engine of a model provider that speaks the OpenAI chat completions
  wire format with server-sent event streaming. It names no vendor: each
  endpoint is a module that gives its constants with `use`, and that module
  is the plugin.

      defmodule Acme.Provider.Local do
        use Helyx.Provider.OpenAI, id: "local", base_url: "http://localhost:11434/v1"
      end

  The options: `id` (the ref prefix), `base_url` (with any `/v1` prefix;
  the engine appends `/chat/completions`), `key_env` (the variable of the
  API key, or nil for no `Authorization` header), `headers` (`{name,
  value}`, a value a string or `:session_id`), and `catalog` (the catalog
  id for the window and the prices, or nil). A bad option fails the compile
  of the endpoint module. Every request sends `User-Agent: helyx/<version>`.
  A key that is not set or empty fails the call with `{:missing_env,
  name}`, and a key that is not an RFC 6750 bearer token with `{:bad_env,
  name}`. In each event of the engine, each byte of each copy of the key,
  and of its JSON form with `\\/`, becomes `*`. Accepted holes: a key in
  `\\uXXXX` escapes, with only some of its slashes escaped, as a list of
  character codes, or in a copy that overlaps an earlier copy is not
  masked. `docs/features/openai-compatible.md`.

  A request that fails before the stream starts runs again, at most 3
  times: on a 408, 409, 429, or 5xx, and on a transport error. A server
  delay over 60 s fails the call at once with `{:retry_after_over_limit,
  status, delay_ms}`. An abort ends a wait at once. The waits and bounds:
  `docs/features/coding-agent.md` (#479).
  """

  alias Helyx.Provider.OpenAI.{Endpoint, Events}

  defmacro __using__(opts) do
    quote do
      use Helyx.Provider.Loop

      @helyx_endpoint Helyx.Provider.OpenAI.Endpoint.new!(unquote(opts))

      @impl Helyx.Provider
      def id, do: @helyx_endpoint.id

      @impl Helyx.Provider.Loop
      def stream(model, context, opts),
        do: Helyx.Provider.OpenAI.stream(@helyx_endpoint, model, context, opts)
    end
  end

  # The longest wait for the next body chunk (Req's `receive_timeout`).
  @chunk_idle_ms 120_000
  @max_key_bytes 4_096

  @doc false
  # The `stream/3` of an endpoint module. The window and the prices of the
  # model come from `Helyx.ModelInfo`; a bad config entry fails the call
  # with its key.
  @spec stream(Endpoint.t(), String.t(), Helyx.Context.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def stream(endpoint, model, context, opts) do
    with {:ok, info} <- Helyx.ModelInfo.lookup(endpoint.id, endpoint.catalog, model),
         {:ok, req_options} <- req_options(),
         {:ok, key} <- key(endpoint.key_env) do
      request = request(endpoint, model, context, opts, key, req_options)
      {:ok, request |> chunks(key) |> Events.events(info) |> redact_events(key)}
    end
  end

  # The environment is a boundary. The key is a bearer token (RFC 6750,
  # `b64token`). Many JSON encoders escape none of its characters but `/`,
  # so the mask covers the key as it is and with `\/`. JSON also allows
  # `\uXXXX` for any character, and some encoders write `+` or `=` that
  # way; that form is not masked.
  defp key(nil), do: {:ok, nil}

  defp key(name) do
    case System.fetch_env(name) do
      {:ok, ""} -> {:error, {:missing_env, name}}
      :error -> {:error, {:missing_env, name}}
      {:ok, key} -> if key?(key), do: {:ok, key}, else: {:error, {:bad_env, name}}
    end
  end

  defp key?(key),
    do: byte_size(key) <= @max_key_bytes and key =~ ~r/\A[A-Za-z0-9\-._~+\/]+=*\z/

  # Config is a boundary: a keyword list. The names and the values are
  # Req's to check.
  defp req_options do
    options = Application.get_env(:helyx_plugins, :openai_req_options, [])

    if Keyword.keyword?(options),
      do: {:ok, options},
      else: {:error, {:bad_config, [:openai_req_options]}}
  end

  # Request

  defp request(endpoint, model, context, opts, key, req_options) do
    Req.new(
      [
        base_url: endpoint.base_url,
        url: "/chat/completions",
        headers: headers(endpoint.headers, opts),
        user_agent: "helyx/#{Application.spec(:helyx, :vsn)}",
        json: body(model, context),
        into: :self,
        receive_timeout: @chunk_idle_ms,
        # `post/2` owns the retries and the error responses, a 3xx too;
        # these override Req's `:default_options`.
        retry: false,
        redirect: false,
        http_errors: :return
      ] ++ auth(key) ++ req_options
    )
  end

  # Nil also replaces an `auth` of Req's `:default_options`.
  defp auth(nil), do: [auth: nil]
  defp auth(key), do: [auth: {:bearer, key}]

  defp headers(headers, opts), do: for({name, value} <- headers, do: {name, value(value, opts)})

  defp value(:session_id, opts), do: Keyword.fetch!(opts, :session_id)
  defp value(value, _opts), do: value

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
  defp chunks(req, key), do: Stream.flat_map([req], &post(&1, key, 0))

  # Only a 200 yields body chunks, so no chunk reaches the session before a
  # retry. The wait runs in the model Task, so an abort kills it at once.
  @max_retries 3
  @max_server_delay_ms 60_000

  defp post(req, key, retries) do
    case Req.post(req) do
      {:ok, %Req.Response{status: 200, body: body}} -> body
      result -> fail_or_retry(req, key, result, retries)
    end
  end

  defp fail_or_retry(req, key, result, retries) do
    case delay(result, retries) do
      {:wait, ms} when retries < @max_retries ->
        cancel(result)
        Process.sleep(ms)
        post(req, key, retries + 1)

      # Fails at once: the body is not read, so it cannot stall the error.
      {:too_long, status, ms} ->
        cancel(result)
        [{:error, {:retry_after_over_limit, status, ms}}]

      # The retries are used up.
      {:wait, _} ->
        [{:error, reason(result, key)}]

      :none ->
        [{:error, reason(result, key)}]
    end
  end

  defp cancel({:ok, resp}), do: Req.cancel_async_response(resp)
  defp cancel({:error, _}), do: :ok

  defp reason({:ok, resp}, key), do: {:http_status, resp.status, drain(resp, key)}
  defp reason({:error, reason}, _key), do: reason

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

  # A server can echo the key, so the key is masked before the cut. The
  # read goes twice the key size past the limit, the size of its longest
  # form, so a key that starts inside the limit is whole when it is masked.
  defp drain(resp, key) do
    read = @max_error_body_bytes + 2 * byte_size(key || "")

    body =
      resp.body
      |> Enum.reduce_while("", fn chunk, body ->
        body = body <> chunk
        if byte_size(body) > read, do: {:halt, body}, else: {:cont, body}
      end)
      |> redact(mask(key))

    if byte_size(body) > @max_error_body_bytes,
      do:
        Helyx.Text.cap(body, @max_error_body_bytes, :head) <>
          "\n[truncated at the #{@max_error_body_bytes}-byte limit]",
      else: body
  end

  # In every string of every event, so in every error that Core builds
  # from one, each copy of the key and of its `\/` form becomes `*` of the
  # same length, so no bound on a text changes. A key has no `*`, so a mask
  # cannot make a new copy. A copy that overlaps one before it is masked
  # only where the earlier one ends; the moduledoc names the other holes.
  defp redact_events(events, nil), do: events

  defp redact_events(events, key) do
    mask = mask(key)
    Stream.map(events, &redact(&1, mask))
  end

  # The key and its JSON form with `\/`.
  defp mask(nil), do: nil
  defp mask(key), do: :binary.compile_pattern(Enum.uniq([key, String.replace(key, "/", "\\/")]))

  defp redact(term, nil), do: term

  defp redact(binary, mask) when is_binary(binary),
    do: :binary.replace(binary, mask, &String.duplicate("*", byte_size(&1)), [:global])

  defp redact(list, mask) when is_list(list), do: Enum.map(list, &redact(&1, mask))

  # A struct too: `__struct__` is an atom, so it stays.
  defp redact(map, mask) when is_map(map),
    do: map |> Map.to_list() |> redact(mask) |> Map.new()

  defp redact(tuple, mask) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact(mask) |> List.to_tuple()

  defp redact(term, _mask), do: term
end
