defmodule Helyx.Provider.OpenAI do
  @moduledoc """
  The engine of a model provider that speaks the OpenAI chat completions
  wire format with server-sent event streaming. It names no vendor: each
  endpoint is a module that gives its constants with `use`, and that module
  is the plugin.

      defmodule Acme.Provider.Local do
        use Helyx.Provider.OpenAI, id: "local", base_url: "http://localhost:11434/v1"
      end

  The options of `use`, the key, the mask, and the retries are in
  `docs/features/openai-compatible.md`. A bad option fails the compile of
  the endpoint module, and every request sends `User-Agent: helyx/<version>`.
  """

  alias Helyx.Provider.OpenAI.{Endpoint, ErrorText, Events}
  alias Helyx.ProviderError

  defmacro __using__(opts) do
    quote do
      use Helyx.Provider.Loop

      @helyx_endpoint Helyx.Provider.OpenAI.Endpoint.new!(unquote(opts))

      @impl Helyx.Provider
      def id, do: @helyx_endpoint.id

      @impl Helyx.Provider
      def max_output_tokens?, do: true

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
      mask = mask(key)
      meta = %{provider: endpoint.id, model: model}
      events = request |> chunks(meta) |> Events.events(info)
      {:ok, Stream.map(events, &text_error(&1, endpoint.id, key, mask))}
    end
  end

  # An error text comes from the HTTP status and the `type` and `code` of an
  # error object. The message, the body, and the payload never reach it: a
  # gateway can echo the key there, also as a copy that overlaps another,
  # and a mask cannot prove it gone (`docs/adr/0014-hole-proofing-invariants.md`,
  # invariant 2). Every other event is masked, for an echo in the content.
  defp text_error({:error, {:http_status, status, body}}, id, key, _mask) do
    {:error,
     ProviderError.reason(
       id,
       status,
       ErrorText.http(status, body, key),
       {:http_status, status, ""}
     )}
  end

  defp text_error({:error, {:api_error, error}}, id, key, _mask),
    do:
      {:error, ProviderError.reason(id, :api_error, ErrorText.api(error, key), {:api_error, ""})}

  # The payload of a bad chunk is raw body text, so it does not reach the
  # text; the tag names the failure.
  defp text_error({:error, {:bad_chunk, _payload}}, _id, _key, _mask),
    do: {:error, {:bad_chunk, ""}}

  defp text_error(event, _id, _key, mask), do: redact(event, mask)

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
        json: body(endpoint, model, context, opts[:max_output_tokens]),
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

  defp body(endpoint, model, context, limit) do
    %{
      model: model,
      stream: true,
      stream_options: %{include_usage: true},
      messages: messages(context)
    }
    |> put_tools(context.tools)
    |> put_limit(endpoint.max_tokens_field, limit)
  end

  defp put_tools(body, []), do: body
  defp put_tools(body, tools), do: Map.put(body, :tools, Enum.map(tools, &tool/1))

  defp put_limit(body, _field, nil), do: body
  defp put_limit(body, field, limit), do: Map.put(body, field, limit)

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
  defp chunks(req, meta), do: Stream.flat_map([req], &post(&1, 0, meta))

  # Only a 200 yields body chunks, so no chunk reaches the session before a
  # retry. The wait runs in the model Task, so an abort kills it at once.
  @max_retries 3
  @max_server_delay_ms 60_000

  # One attempt event per call of `Req.post/1`: the attempt number, the
  # status or the transport error, the time to the headers, and the retry
  # decision. The event goes after the decision and before any wait.
  defp post(req, retries, meta) do
    started = System.monotonic_time()
    result = Req.post(req)
    duration = System.monotonic_time() - started

    case result do
      {:ok, %Req.Response{status: 200, body: body}} ->
        emit(meta, retries, result, duration, :ok, nil)
        body

      result ->
        delay = delay(result, retries)
        {decision, wait_ms} = decision(delay, retries)
        emit(meta, retries, result, duration, decision, wait_ms)
        fail_or_retry(req, result, retries, delay, meta)
    end
  end

  defp fail_or_retry(req, result, retries, delay, meta) do
    case delay do
      {:wait, ms} when retries < @max_retries ->
        cancel(result)
        Process.sleep(ms)
        post(req, retries + 1, meta)

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

  # The decision of a delay result, and the wait that it takes. A wait with
  # no retries left is the give-up: no wait follows it.
  defp decision({:wait, ms}, retries) when retries < @max_retries, do: {:wait, ms}
  defp decision({:wait, _ms}, _retries), do: {:give_up, nil}
  defp decision({:too_long, _status, ms}, _retries), do: {:too_long, ms}
  defp decision(:none, _retries), do: {:fail, nil}

  # No content: ids, counts, and codes only.
  defp emit(meta, attempt, result, duration, decision, wait_ms) do
    :telemetry.execute(
      [:helyx, :provider, :attempt],
      %{duration: duration},
      Map.merge(meta, %{
        attempt: attempt,
        status: status(result),
        error: error(result),
        decision: decision,
        wait_ms: wait_ms
      })
    )
  end

  defp status({:ok, %Req.Response{status: status}}), do: status
  defp status(_result), do: nil

  defp error({:error, %Req.TransportError{reason: reason}}) when is_atom(reason), do: reason
  defp error({:error, _reason}), do: :other
  defp error(_result), do: nil

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

  # The error body is read only for the structured fields of an error
  # object, never as text. The read stops past the text bound, so a body
  # that a server sends without end cannot grow; a body cut there does not
  # decode, and the text is the status alone. Halting the reduce cancels
  # the rest of the response.
  defp drain(resp) do
    resp.body
    |> Enum.reduce_while("", fn chunk, body ->
      body = body <> chunk

      if byte_size(body) > ProviderError.max_text_bytes(),
        do: {:halt, body},
        else: {:cont, body}
    end)
    |> String.replace_invalid()
  end

  # The key and its JSON form with `\/`.
  defp mask(nil), do: nil
  defp mask(key), do: :binary.compile_pattern(Enum.uniq([key, String.replace(key, "/", "\\/")]))

  # In every string of every event that is not an error, so in every error
  # that Core builds from one, each copy of the key and of its `\/` form
  # becomes `*` of the same length, so no bound on a text changes. A key has
  # no `*`, so a mask cannot make a new copy. A copy that overlaps one before
  # it is masked only where the earlier one ends; the moduledoc names the
  # other holes. An error text does not come through here: it is built from
  # the status and two structured fields.
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
