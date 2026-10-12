defmodule Helyx.Session.Server.Events do
  @moduledoc false
  # The event stream of a session: the only writer of `seq` and
  # `subscribers` in `Helyx.Session.Server.State`. Each event gets the next
  # `seq` and goes to every subscriber; the snapshot gives the `seq` of the
  # last event (docs/features/session-snapshot.md). The records that the
  # events tell of are written in `Helyx.Session.Server.Records`.

  require Logger

  alias Helyx.{Event, Message, ModelRef}
  alias Helyx.Session.{Queue, Snapshot, Turn}
  alias Helyx.Session.Server.State

  def subscribe(%State{} = state, pid) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    %{state | subscribers: subscribers}
  end

  def unsubscribe(%State{} = state, pid) do
    {ref, subscribers} = Map.pop(state.subscribers, pid)
    _ = ref && Process.demonitor(ref, [:flush])
    %{state | subscribers: subscribers}
  end

  def subscriber_down(%State{subscribers: subscribers} = state, pid),
    do: %{state | subscribers: Map.delete(subscribers, pid)}

  # The state of the session in one value (`Helyx.Session.Snapshot`), with
  # the `seq` of its last event: a subscribe takes it in the same call.
  def snapshot(%State{} = state) do
    %Snapshot{
      instance_id: state.instance_id,
      seq: state.seq,
      messages: state.transcript,
      turn: if(match?(%Turn{}, state.activity), do: Turn.snapshot(state.activity)),
      model: ModelRef.to_string(state.model),
      queue: Queue.counts(state.queue)
    }
  end

  # A stacktrace is a list of stack frames: `{module, fun, arity_or_args,
  # location}` or `{fun, args, location}`. A frame has an arity or the
  # arguments of the call, so a list of other 4-tuples is not taken for a
  # stacktrace. The first frame decides, so the check is one step.
  defguardp is_frame(frame)
            when (tuple_size(frame) == 4 and is_atom(elem(frame, 0)) and
                    is_atom(elem(frame, 1)) and
                    (is_integer(elem(frame, 2)) or is_list(elem(frame, 2))) and
                    is_list(elem(frame, 3))) or
                   (tuple_size(frame) == 3 and is_function(elem(frame, 0)) and
                      is_list(elem(frame, 1)) and is_list(elem(frame, 2)))

  defguardp is_stacktrace(list) when is_list(list) and is_tuple(hd(list)) and is_frame(hd(list))

  # The bound of the error text of a failed turn (ADR 0006 §2).
  @max_error_bytes 4000

  # The walk that cleans the reason visits at most this many terms, so its
  # work and the work of the text after it have a bound whatever the size
  # of the reason (docs/features/session-lifecycle.md, step 5).
  @max_nodes 10_000

  # The limits bound the text before the cut: the item limit holds over
  # the whole term, and `binaries: :as_strings` escapes an invalid byte.
  @text_opts [binaries: :as_strings, limit: 50, printable_limit: @max_error_bytes]

  # The Logger formatter cuts a line at `truncate`, so the log term is
  # built to about that size (docs/features/session-lifecycle.md, step 5).
  @log_opts [limit: 50, printable_limit: 160]

  # The one place where the reason of a failed turn becomes the text of
  # `turn_end` and `message_end`, so no term reaches a client and no
  # stacktrace of the reason gets into the text (ADR 0006 §2). The log
  # gets the reason as it is, with a bound.
  def error_text(reason) do
    Logger.warning(fn -> "turn failed: " <> contained(reason, @log_opts) end)

    {clean, _left} = clean(reason, @max_nodes)
    text = describe(clean)
    # A character cut in half and an invalid byte are dropped.
    text |> binary_part(0, min(@max_error_bytes, byte_size(text))) |> String.replace_invalid("")
  end

  # Every stacktrace in the reason, inside any tuple, list, map, or struct,
  # or as the rest of a list, becomes `:stacktrace`. Past the bound of
  # visited terms, the rest of a term becomes `:cut`, so no part that the
  # walk did not see reaches the text. An integer gets the digit cap of a
  # provider error, because `inspect` of a huge one takes seconds.
  defp clean(_term, 0), do: {:cut, 0}
  defp clean(list, left) when is_stacktrace(list), do: {:stacktrace, left - 1}
  defp clean(list, left) when is_list(list), do: clean_list(list, left - 1, [])
  defp clean(tuple, left) when is_tuple(tuple), do: clean_tuple(tuple, 0, left - 1, [])
  # A struct keeps its name and its exception mark even when the walk cuts
  # it, so a cut exception still writes its message.
  defp clean(map, left) when is_map(map) do
    # `Map.take/2` of a struct is a struct, which is not enumerable.
    kept = map |> Map.take([:__struct__, :__exception__]) |> Map.to_list()
    kept = for {key, value} <- kept, is_atom(value), do: {key, value}

    clean_map(:maps.iterator(map), left - 1, kept)
  end

  defp clean(integer, left) when is_integer(integer),
    do: {Message.cap_integers(integer), left - 1}

  defp clean(term, left), do: {term, left - 1}

  # A list can be improper: its tail is cleaned as a term, and
  # `:lists.reverse/2` keeps it.
  defp clean_list([], left, acc), do: {Enum.reverse(acc), left}
  defp clean_list(_rest, 0, acc), do: {Enum.reverse(acc, [:cut]), 0}

  defp clean_list(rest, left, acc) when is_stacktrace(rest),
    do: {Enum.reverse(acc, [:stacktrace]), left - 1}

  defp clean_list([head | tail], left, acc) do
    {head, left} = clean(head, left)
    clean_list(tail, left, [head | acc])
  end

  defp clean_list(tail, left, acc) do
    {tail, left} = clean(tail, left)
    {:lists.reverse(acc, tail), left}
  end

  defp clean_tuple(tuple, index, left, acc) when index == tuple_size(tuple),
    do: {acc |> Enum.reverse() |> List.to_tuple(), left}

  defp clean_tuple(_tuple, _index, 0, acc),
    do: {acc |> Enum.reverse([:cut]) |> List.to_tuple(), 0}

  defp clean_tuple(tuple, index, left, acc) do
    {element, left} = clean(elem(tuple, index), left)
    clean_tuple(tuple, index + 1, left, [element | acc])
  end

  # The keys are cleaned too: a key can hold a stacktrace. The kept pairs
  # are skipped, so they cost no visit.
  defp clean_map(iterator, left, acc) do
    case :maps.next(iterator) do
      :none ->
        {Map.new(acc), left}

      {key, value, iterator} when key in [:__struct__, :__exception__] and is_atom(value) ->
        clean_map(iterator, left, acc)

      _next when left == 0 ->
        {Map.new([{:cut, :cut} | acc]), 0}

      {key, value, iterator} ->
        {key, left} = clean(key, left)
        {value, left} = clean(value, left)
        clean_map(iterator, left, [{key, value} | acc])
    end
  end

  # The `Inspect` of a plugin struct runs here. With `safe: false` its
  # raise is not turned into text with a stacktrace: a raise, throw, or
  # exit gives the term with no struct implementation, and the session
  # lives.
  defp contained(term, opts) do
    inspect(term, [safe: false] ++ opts)
  catch
    _class, _value -> inspect(term, [structs: false] ++ opts)
  end

  # The text of a cleaned reason. A crash shows as the message of its
  # error, which is shorter than the term; the cleaning, not this step,
  # keeps the stacktrace out.
  defp describe(text) when is_binary(text), do: text
  defp describe(%_{__exception__: true} = exception), do: message(exception)

  defp describe(reason) do
    case crash(reason) do
      {:ok, error} -> message(error)
      :error -> contained(reason, @text_opts)
    end
  end

  # The `message/1` of a plugin exception runs here, called directly:
  # `Exception.message/1` turns its raise into text with a stacktrace. A
  # raise, throw, or exit of it or of the normalization, or a message that
  # is not a string, gives the name of the exception.
  defp message(error) do
    %module{} = exception = Exception.normalize(:error, error, [])

    # A message that is not a string raises here and takes the catch.
    case module.message(exception) do
      text when is_binary(text) -> text
    end
  catch
    _class, _value -> no_message(error)
  end

  defp no_message(%module{}) when is_atom(module), do: inspect(module)
  defp no_message(error), do: contained(error, @text_opts)

  # A crash is an error with its stacktrace, now `{error, :stacktrace}`:
  # bare, under an atom tag, as an exit signal, or as the exit of a call
  # (`{reason, {GenServer, :call, args}}`).
  defp crash({error, :stacktrace}), do: {:ok, error}
  defp crash({tag, reason}) when is_atom(tag), do: crash(reason)
  defp crash({:EXIT, _from, reason}), do: crash(reason)

  defp crash({reason, {module, fun, args}})
       when is_atom(module) and is_atom(fun) and is_list(args),
       do: crash(reason)

  defp crash(_reason), do: :error

  # Only the queue events fire between turns: the drain at a normal turn
  # end, and an abort in a wait. Every other `emit/3` with no turn is a bug
  # and crashes here. An event with no turn by intent gives its turn id to
  # `emit/4`.
  def emit(%State{activity: %Turn{id: turn_id}} = state, type, data),
    do: emit(state, turn_id, type, data)

  def emit(%State{} = state, type, data) when type in [:queue_update, :queue_dropped],
    do: emit(state, nil, type, data)

  def emit(state, turn_id, type, data) do
    seq = state.seq + 1

    event = %Event{
      type: type,
      session_id: state.id,
      instance_id: state.instance_id,
      turn_id: turn_id,
      seq: seq,
      data: data
    }

    for {pid, _ref} <- state.subscribers, do: send(pid, {:helyx_event, event})

    %{state | seq: seq}
  end
end
