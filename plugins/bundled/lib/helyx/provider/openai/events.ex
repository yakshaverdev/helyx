defmodule Helyx.Provider.OpenAI.Events do
  # The SSE parser of `Helyx.Provider.OpenAI`: body chunks in, provider
  # stream events out.
  @moduledoc false

  # No gateway sends an SSE line near 1 MiB; a line past this is a broken or
  # hostile peer, and the buffer must not grow without bound.
  @max_line_bytes 1_048_576

  # The bytes the tool calls of one response hold: arguments, ids, and
  # names. Room for a Write of a large file; past this the model is looping
  # or the peer is hostile. The source is the bounds table of
  # docs/features/coding-agent.md.
  @max_tool_call_bytes 10_485_760
  # An index is a map key. The range bounds the number of calls, which the
  # byte count does not see, and keeps a bignum out of the keys.
  @max_call_index 10_000

  # `buffer` holds a partial SSE line across chunks, `calls` assembles tool
  # calls by index with `tool_bytes` their size, `finish` and `usage` wait
  # for `[DONE]`, and `info` prices the usage (`Helyx.ModelInfo`). A
  # stream with no usage chunk gives the unknown usage.
  @acc %{buffer: "", calls: %{}, tool_bytes: 0, finish: nil, usage: %Helyx.Usage{}}

  import Helyx.Usage, only: [wire_tokens?: 1]

  @doc """
  Transforms a stream of SSE body chunks into provider stream events.

  `Helyx.Provider.OpenAI` calls it on the response body. Tests call it
  directly to feed chunks split at arbitrary boundaries; the test adapter
  delivers each recorded body as one chunk.
  """
  @spec events(Enumerable.t(), Helyx.ModelInfo.t()) :: Enumerable.t()
  def events(chunks, info) do
    Stream.transform(chunks, Map.put(@acc, :info, info), &handle/2)
  end

  # A bad chunk ended the stream; drop the rest and cancel the request.
  defp handle(_chunk, :halted), do: {:halt, :halted}

  defp handle({:error, reason}, acc), do: {[{:error, reason}], acc}

  # buffer <> chunk re-copies the carried partial line per chunk; the line
  # cap bounds each copy.
  defp handle(chunk, acc) when is_binary(chunk) do
    {lines, buffer} = split_lines(acc.buffer <> chunk)

    Enum.flat_map_reduce(lines, %{acc | buffer: buffer}, &line/2)
  end

  # Complete lines and the trailing partial one. SSE delimits with \n or
  # \r\n. A partial past the limit is promoted to a complete line so the one
  # guard in `line/2` errors now, before any terminator, and the buffer never
  # grows past the limit by more than one chunk.
  defp split_lines(data) do
    {partial, complete} = data |> :binary.split(["\r\n", "\n"], [:global]) |> List.pop_at(-1)

    if byte_size(partial) > @max_line_bytes,
      do: {complete ++ [partial], ""},
      else: {complete, partial}
  end

  defp line(_line, :halted), do: {:halt, :halted}

  defp line(line, _acc) when byte_size(line) > @max_line_bytes,
    do: {[{:error, {:line_over_limit, @max_line_bytes}}], :halted}

  defp line("data:" <> payload, acc), do: data(String.trim_leading(payload, " "), acc)
  defp line(_line, acc), do: {[], acc}

  defp data("[DONE]", acc), do: flush(acc)
  defp data("", acc), do: {[], acc}

  # A chunk that does not parse or has the wrong shape ends the stream with
  # one error event; nothing after it is processed, so no `done` follows.
  defp data(payload, acc) do
    case JSON.decode(payload) do
      # A gateway reports a mid-stream failure as an error object in the data.
      {:ok, %{"error" => error}} when error != nil -> {[{:error, {:api_error, error}}], acc}
      {:ok, chunk} -> chunk |> fields(acc.info) |> chunk_events(payload, acc)
      {:error, _} -> {[{:error, {:bad_chunk, payload}}], :halted}
    end
  end

  # The one shape check, of the documented chunk (OpenAI chat completions
  # streaming): the first choice with a string `finish_reason` and its
  # delta, the delta's tool calls, each with an integer index, a string
  # `id`, and a `function` with a string `name` and `arguments`, and a
  # `usage` with token counts within the wire bound. Each of these can be
  # missing or null, except the index. Core checks the text and thinking
  # deltas. `info` prices the usage.
  defp fields(%{} = chunk, info) do
    with {:ok, choice} <- first_choice(chunk["choices"]),
         %{} = delta <- field(choice, "delta", %{}),
         calls when is_list(calls) <- field(delta, "tool_calls", []),
         true <- Enum.all?(calls, &call?/1),
         true <- string?(choice["finish_reason"]),
         {:ok, usage} <- usage(chunk["usage"], info) do
      {:ok, choice, delta, calls, usage}
    end
  end

  defp fields(_chunk, _info), do: :error

  defp first_choice([%{} = choice | _]), do: {:ok, choice}
  defp first_choice(none) when none in [nil, []], do: {:ok, %{}}
  defp first_choice(_choices), do: :error

  defp call?(%{"index" => index} = call) when index in 0..@max_call_index//1 do
    function = field(call, "function", %{})

    is_map(function) and
      Enum.all?([call["id"], function["name"], function["arguments"]], &string?/1)
  end

  defp call?(_call), do: false

  # The usage of one model call (`docs/features/usage-and-limits.md`, "Per
  # provider"). The prompt count includes the cached tokens, so a cached
  # count above it is outside the wire bound. A missing or null
  # `prompt_tokens` or `completion_tokens` counts 0, and the call has no
  # cost: a count is not known.
  defp usage(nil, _info), do: {:ok, nil}

  defp usage(%{} = usage, info) do
    prompt = field(usage, "prompt_tokens", 0)
    output = field(usage, "completion_tokens", 0)
    details = field(usage, "prompt_tokens_details", %{})
    cached = if is_map(details), do: field(details, "cached_tokens", 0)

    if wire_tokens?(prompt) and wire_tokens?(output) and wire_tokens?(cached) and cached <= prompt do
      call =
        Helyx.ModelInfo.price(
          %Helyx.Usage{
            input: prompt - cached,
            output: output,
            cache_read: cached,
            context_tokens: prompt + output
          },
          info
        )

      counted? = usage["prompt_tokens"] != nil and usage["completion_tokens"] != nil
      {:ok, if(counted?, do: call, else: Helyx.Usage.unpriced(call))}
    else
      :error
    end
  end

  defp usage(_usage, _info), do: :error

  # A missing or null field passes this.
  defp string?(value), do: value == nil or is_binary(value)

  # A missing or null field takes the default; `false` is a value and fails
  # the shape check.
  defp field(map, key, default) do
    case map[key] do
      nil -> default
      value -> value
    end
  end

  defp chunk_events({:ok, choice, delta, calls, usage}, _payload, acc) do
    acc = Enum.reduce(calls, acc, &put_call/2)
    # Normalizing here, not at flush, releases the decoded chunk: a raw
    # `finish_reason` is a sub-binary that pins its whole parent.
    finish = choice["finish_reason"]

    acc = %{
      acc
      | finish: if(finish, do: stop_reason(finish), else: acc.finish),
        usage: usage || acc.usage
    }

    if acc.tool_bytes > @max_tool_call_bytes,
      do: {[{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}], :halted},
      else: {delta_events(delta), acc}
  end

  defp chunk_events(_bad, payload, _acc), do: {[{:error, {:bad_chunk, payload}}], :halted}

  # Thinking arrives as `reasoning_content`, text as `content`. Empty and
  # missing ones emit nothing.
  defp delta_events(delta) do
    for {kind, text} <- [
          thinking_delta: delta["reasoning_content"],
          text_delta: delta["content"]
        ],
        text not in [nil, ""],
        do: {kind, text}
  end

  # The first delta of a call carries its id and name; later ones append
  # argument fragments to the call of their index.
  defp put_call(delta, acc) do
    function = field(delta, "function", %{})
    call = Map.get(acc.calls, delta["index"], %{id: "", name: "", arguments: ""})

    # The copies release the decoded chunk, which a sub-binary would pin;
    # the append copies the fragment.
    new = %{
      id: keep_first(call.id, delta["id"]),
      name: keep_first(call.name, function["name"]),
      arguments: call.arguments <> field(function, "arguments", "")
    }

    %{
      acc
      | calls: Map.put(acc.calls, delta["index"], new),
        tool_bytes: acc.tool_bytes + call_bytes(new) - call_bytes(call)
    }
  end

  defp keep_first("", value) when is_binary(value), do: :binary.copy(value)
  defp keep_first(kept, _value), do: kept

  defp call_bytes(call), do: byte_size(call.id) + byte_size(call.name) + byte_size(call.arguments)

  # Emits the assembled tool calls and the terminal `done` at `[DONE]`. A
  # stream that dropped before `[DONE]` emits nothing here, so the session
  # fails the turn with `:stream_ended` and keeps no partial message.
  defp flush(%{finish: nil} = acc), do: {[], acc}

  defp flush(acc) do
    events = acc.calls |> Enum.sort() |> Enum.map(fn {_index, call} -> tool_call(call) end)
    {events ++ [{:done, %{stop_reason: acc.finish, usage: acc.usage}}], acc}
  end

  defp tool_call(%{id: id, name: name, arguments: arguments}) do
    call = %Helyx.Message.ToolCall{id: id, name: name, arguments: %{}}

    case arguments do
      "" -> {:tool_call, call}
      json -> decode_arguments(call, json)
    end
  end

  # Arguments that are not a JSON object go on as their raw text. Core
  # fails the turn at the call and drops the text (`Helyx.Provider`).
  defp decode_arguments(call, json) do
    case decode(json) do
      {:ok, arguments} when is_map(arguments) -> {:tool_call, %{call | arguments: arguments}}
      _ -> {:tool_call, %{call | arguments: json}}
    end
  end

  # The decode raises, not returns, for an integer over the BEAM limit. An
  # SSE line is too short to hold one; joined arguments are not.
  defp decode(json) do
    JSON.decode(json)
  rescue
    SystemLimitError -> :error
  end

  # The wire values: docs/research/stop-reasons.md.
  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason("content_filter"), do: :refused
  defp stop_reason(_finish), do: :end_turn
end
