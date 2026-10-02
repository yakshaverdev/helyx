defmodule Helyx.Provider.OpenAI.Events do
  # The SSE parser of `Helyx.Provider.OpenAI`: body chunks in, provider
  # stream events out.
  @moduledoc false

  # No gateway sends an SSE line near 1 MiB; a line past this is a broken or
  # hostile peer, and the buffer must not grow without bound.
  @max_line_bytes 1_048_576

  # Room for a Write of a large file; past this the model is looping or the
  # peer is hostile, and `calls` must not grow without bound. The budget
  # charges everything `calls` retains: argument fragments plus the list
  # cells that hold them, ids, names, and a flat cost per entry, so a peer
  # spraying indexes or one-byte fragments is bounded like one spraying
  # bytes. It is the read limit of the file tools (`Helyx.Text`). The
  # charges and the JSON escapes count too, so the largest file a Write
  # call can carry is somewhat smaller.
  @max_tool_call_bytes Helyx.Text.max_file_bytes()
  @call_entry_bytes 100
  # Measured retention of a kept fragment: the cons pair plus the heap
  # binary that holds the copy.
  @call_fragment_bytes 64

  # The accumulator: `buffer` holds a partial SSE line across chunks, `calls`
  # assembles tool calls by index with `tool_bytes` their charged size,
  # `ids` maps each call id to its index, `indexed?` tells if the deltas of
  # this stream carry an index (nil before the first one), `finish` and
  # `usage` wait for `[DONE]`. `finish` and
  # `usage` are normalized to an atom and an integer map at ingest, so they
  # retain no wire bytes.
  @acc %{buffer: "", calls: %{}, ids: %{}, tool_bytes: 0, indexed?: nil, finish: nil, usage: %{}}

  @doc """
  Transforms a stream of SSE body chunks into provider stream events.

  `Helyx.Provider.OpenAI` calls it on the response body. Tests call it
  directly to feed chunks split at arbitrary boundaries; the test adapter
  delivers each recorded body as one chunk.
  """
  @spec events(Enumerable.t()) :: Enumerable.t()
  def events(chunks) do
    Stream.transform(chunks, @acc, &handle/2)
  end

  # A bad chunk ended the stream; drop the rest and cancel the request.
  defp handle(_chunk, :halted), do: {:halt, :halted}

  defp handle({:error, reason}, acc), do: {[{:error, reason}], acc}

  # ponytail: buffer <> chunk re-copies the carried partial line per chunk;
  # make the buffer iodata if one huge data line ever shows up in profiles.
  defp handle(chunk, acc) when is_binary(chunk) do
    {lines, buffer} = split_lines(acc.buffer <> chunk)

    Enum.flat_map_reduce(lines, %{acc | buffer: buffer}, &line/2)
  end

  # Complete lines and the trailing partial one. SSE delimits with \n or
  # \r\n. A partial past the limit is promoted to a complete line so the one
  # guard in `line/2` errors now, before any terminator, and the buffer never
  # grows past the limit by more than one chunk. One trailing \r does not
  # count: it can be a CRLF terminator split across chunks, and the split
  # consumes it when the \n arrives.
  defp split_lines(data) do
    {partial, complete} = data |> :binary.split(["\r\n", "\n"], [:global]) |> List.pop_at(-1)

    if byte_size(partial) - pending_cr(partial) > @max_line_bytes,
      do: {complete ++ [partial], ""},
      else: {complete, partial}
  end

  defp pending_cr(partial), do: if(String.ends_with?(partial, "\r"), do: 1, else: 0)

  defp line(_line, :halted), do: {:halt, :halted}

  defp line(line, _acc) when byte_size(line) > @max_line_bytes,
    do: {[{:error, {:line_over_limit, @max_line_bytes}}], :halted}

  defp line("data:" <> payload, acc), do: data(String.trim_leading(payload, " "), acc)
  defp line(_line, acc), do: {[], acc}

  defp data("[DONE]", acc), do: flush(acc)
  defp data("", acc), do: {[], acc}

  # A chunk that does not parse, has the wrong shape, or has a call delta
  # that conflicts (`add_call_delta/2`) ends the stream with one error
  # event; nothing after it is processed, so no `done` follows.
  defp data(payload, acc) do
    with {:ok, chunk} <- JSON.decode(payload),
         true <- valid_chunk?(chunk),
         result when result != :conflict <- chunk_events(chunk, acc) do
      result
    else
      _ -> {[{:error, {:bad_chunk, payload}}], :halted}
    end
  end

  # The one shape gate where a decoded chunk enters the parser. It rejects
  # every shape that could raise in the field walks below it or in the
  # iodata at flush, and a few degenerate ones that would not. A missing or
  # null field is fine, except a null call index (`valid_call?`), and so is
  # a wrong-typed leaf the parser only copies or drops, such as `content: 42`.
  defp valid_chunk?(%{} = chunk) do
    case chunk["choices"] do
      nil -> true
      choices when is_list(choices) -> valid_choice?(List.first(choices))
      _choices -> false
    end
  end

  defp valid_chunk?(_chunk), do: false

  defp valid_choice?(nil), do: true
  defp valid_choice?(%{} = choice), do: valid_delta?(choice["delta"])
  defp valid_choice?(_choice), do: false

  defp valid_delta?(nil), do: true

  defp valid_delta?(%{} = delta) do
    case delta["tool_calls"] do
      nil -> true
      calls when is_list(calls) -> Enum.all?(calls, &valid_call?/1)
      _calls -> false
    end
  end

  defp valid_delta?(_delta), do: false

  # Everything the call accumulator retains must be typed and bounded here,
  # or a peer could retain terms the byte budget cannot charge. An index is
  # a map key: a string "0" and an integer 0 would make two entries for one
  # call, so only an integer passes, and a null index is malformed too.
  # Only a missing index gets the implied one. The cap keeps a bignum from
  # smuggling megabytes past the budget, and no wire sends indexes near it.
  @max_call_index 10_000

  defp valid_call?(%{} = call) do
    valid_index?(Map.get(call, "index", 0)) and valid_leaf?(call["id"]) and
      valid_function?(call["function"])
  end

  defp valid_call?(_call), do: false

  defp valid_index?(index), do: is_integer(index) and index in 0..@max_call_index

  defp valid_function?(nil), do: true

  # Non-binary argument fragments can raise later, at flush.
  defp valid_function?(%{} = function),
    do: valid_leaf?(function["name"]) and valid_leaf?(function["arguments"])

  defp valid_function?(_function), do: false

  defp valid_leaf?(leaf), do: leaf == nil or is_binary(leaf)

  # A gateway reports a mid-stream failure as an error object in the data.
  defp chunk_events(%{"error" => error}, acc), do: {[{:error, {:api_error, error}}], acc}

  defp chunk_events(chunk, acc) do
    choice = List.first(chunk["choices"] || []) || %{}
    delta = choice["delta"] || %{}

    case Enum.reduce_while(delta["tool_calls"] || [], acc, &add_call_delta/2) do
      :conflict -> :conflict
      acc -> finish_chunk(chunk, choice, delta, acc)
    end
  end

  defp finish_chunk(chunk, choice, delta, acc) do
    # Normalizing here, not at flush, releases the decoded chunk: a raw
    # `finish_reason` or `usage` is a sub-binary that pins its whole parent.
    finish = choice["finish_reason"]
    usage = chunk["usage"]

    acc = %{
      acc
      | finish: if(finish, do: stop_reason(finish), else: acc.finish),
        usage: if(usage, do: usage(usage), else: acc.usage)
    }

    if acc.tool_bytes > @max_tool_call_bytes do
      {[{:error, {:tool_call_bytes_over_limit, @max_tool_call_bytes}}], :halted}
    else
      {delta_events(delta), acc}
    end
  end

  # Thinking arrives as `reasoning_content` (DeepSeek style) or `reasoning`
  # (OpenRouter style); text as `content`. Empty and missing ones emit nothing.
  defp delta_events(delta) do
    for {kind, text} <- [
          thinking_delta: delta["reasoning_content"] || delta["reasoning"],
          text_delta: delta["content"]
        ],
        is_binary(text) and text != "",
        do: {kind, text}
  end

  # The first delta of a call usually carries the id and name; later ones
  # append argument fragments. Fragments of one call share an index. A delta
  # without an index extends the last call when it has no id or the id of
  # that call, and starts the next call when its id is new; an empty id
  # counts as none. The id and name are taken from the first delta that has
  # them. Each id names one call and each call has one id, so a delta
  # conflicts when it names a second id for an index, or an id that another
  # index holds. Without an index, the id of an earlier call is such an id:
  # a later delta with no id could not tell which call it extends. A delta
  # also conflicts when its stream mixes deltas with and without an index:
  # the implied index can then fall on the call of another delta, and one
  # call would take the fragments of two.
  defp add_call_delta(delta, acc) do
    id = if delta["id"] != "", do: delta["id"]
    index = Map.get_lazy(delta, "index", fn -> implied_index(id, acc) end)
    indexed? = Map.has_key?(delta, "index")
    known = get_in(acc.calls, [index, :id])
    open? = known in [nil, ""]
    new_id = if open?, do: id

    if acc.indexed? in [nil, indexed?] and Map.get(acc.ids, id, index) == index and
         (open? or id in [nil, known]),
       # A repeated id is not copied, charged, or stored again.
       do: {:cont, put_call_delta(delta, new_id, index, %{acc | indexed?: indexed?})},
       else: {:halt, :conflict}
  end

  defp put_call_delta(delta, id, index, acc) do
    function = delta["function"] || %{}
    # A decoded field is a sub-binary that keeps the whole coalesced chunk
    # it was split from alive, and chunk size has no bound of its own; the
    # copies release the chunk, so the charge tells the truth about what
    # the accumulator retains.
    arguments = :binary.copy(function["arguments"] || "")
    id = :binary.copy(id || "")
    name = :binary.copy(function["name"] || "")

    fragment = if arguments == "", do: 0, else: @call_fragment_bytes + byte_size(arguments)

    tool_bytes =
      acc.tool_bytes + fragment + byte_size(id) + byte_size(name) + entry_bytes(acc.calls, index)

    calls =
      Map.update(
        acc.calls,
        index,
        %{id: id, name: name, arguments: [arguments]},
        fn call ->
          %{
            call
            | id: if(call.id == "", do: id, else: call.id),
              name: if(call.name == "", do: name, else: call.name),
              # An empty fragment appends nothing, so a delta that charges
              # zero bytes also retains zero bytes.
              arguments:
                if(arguments == "", do: call.arguments, else: [call.arguments, arguments])
          }
        end
      )

    %{acc | calls: calls, ids: put_id(acc.ids, id, index), tool_bytes: tool_bytes}
  end

  # The flat entry charge covers the one `ids` entry of a call.
  defp put_id(ids, "", _index), do: ids
  defp put_id(ids, id, index), do: Map.put(ids, id, index)

  # A new entry costs a flat charge.
  defp entry_bytes(calls, index) do
    if Map.has_key?(calls, index), do: 0, else: @call_entry_bytes
  end

  # An id of an earlier call gets a new index, which the `ids` check in
  # `add_call_delta/2` rejects.
  defp implied_index(id, acc) do
    last = max(map_size(acc.calls) - 1, 0)
    if id == nil or Map.get(acc.ids, id) == last, do: last, else: map_size(acc.calls)
  end

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

    case IO.iodata_to_binary(arguments) do
      "" -> {:tool_call, call}
      json -> decode_arguments(call, json)
    end
  end

  # A call with bad arguments gets an error result, so the model can
  # correct it; it does not hold the raw JSON. A call with no id fails the
  # turn at the Core stream boundary, with good arguments or bad.
  defp decode_arguments(call, json) do
    case JSON.decode(json) do
      {:ok, arguments} when is_map(arguments) -> {:tool_call, %{call | arguments: arguments}}
      _ -> {:rejected_tool_call, call, "the arguments are not a valid JSON object"}
    end
  end

  defp stop_reason("tool_calls"), do: :tool_use
  defp stop_reason("length"), do: :max_tokens
  defp stop_reason(_finish), do: :end_turn

  defp usage(%{} = usage) do
    for {wire, key} <- [{"prompt_tokens", :input}, {"completion_tokens", :output}],
        is_integer(usage[wire]),
        into: %{},
        do: {key, usage[wire]}
  end

  defp usage(_usage), do: %{}
end
