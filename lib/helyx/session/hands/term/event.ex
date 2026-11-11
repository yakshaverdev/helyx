defmodule Helyx.Session.Hands.Term.Event do
  @moduledoc false
  # The events of a provider process as the data of a hands term: a stream
  # event, a terminal, a tool request, an approval, and a resume id. A check
  # builds the tuple of `Helyx.Session.Stream` and runs its rule, then returns
  # the checked shape: a cut tool result text and a cut UI block are the values
  # the check returns. A tool request carries its rejection reason, because the
  # session cannot make it again from a call whose arguments were replaced.

  alias Helyx.Message
  alias Helyx.Session.Hands.Term.Data
  alias Helyx.Session.Stream

  @doc false
  # A turn that the provider started by itself: a stream event with no payload,
  # whose turn id the term checks as a resume id.
  def check(%{kind: :stream, event: %{kind: :turn_start} = event} = shape)
      when map_size(shape) == 2 and map_size(event) == 1,
      do: {:ok, shape}

  def check(%{kind: :tool_request, call: call, rejection: rejection} = shape) do
    with 3 <- map_size(shape),
         true <- Data.call?(call),
         true <- is_nil(rejection) or Data.reason?(rejection) do
      checked(shape, Stream.check({:tool_request, call.id, call.name, call.arguments}))
    else
      _ -> :error
    end
  end

  def check(%{kind: kind} = shape)
      when kind in [:stream, :end, :approval, :resume_id] do
    with {:ok, tuple} <- event_tuple(shape) do
      checked(shape, Stream.check(tuple))
    end
  end

  def check(_shape), do: :error

  @doc false
  def event?(shape), do: match?({:ok, _}, check(shape))

  # The checked shape of a `Helyx.Session.Stream.check/1` answer.
  defp checked(%{kind: :stream} = shape, {:send, event, _rejection}) do
    with {:ok, event} <- event_shape(event), do: {:ok, %{shape | event: event}}
  end

  defp checked(%{kind: :end} = shape, {:terminal, terminal}) do
    with {:ok, terminal} <- terminal_shape(terminal), do: {:ok, %{shape | terminal: terminal}}
  end

  defp checked(%{kind: :tool_request} = shape, {:send, {:tool_request, call, _bytes}, _}),
    do: {:ok, %{shape | call: call}}

  defp checked(%{kind: kind} = shape, {:send, _event, _rejection})
       when kind in [:approval, :resume_id],
       do: {:ok, shape}

  defp checked(_shape, _result), do: :error

  defp event_shape({:text_delta, text}), do: {:ok, %{kind: :text_delta, text: text}}
  defp event_shape({:thinking_delta, text}), do: {:ok, %{kind: :thinking_delta, text: text}}
  defp event_shape({:tool_call, call, _bytes}), do: {:ok, %{kind: :tool_call, call: call}}

  defp event_shape({:message_end, stop, usage}),
    do: {:ok, %{kind: :message_end, stop: stop, usage: usage}}

  defp event_shape({:tool_result, call, {status, text}}),
    do: {:ok, %{kind: :tool_result, call: call, result: {status, text}}}

  defp event_shape({:resume_id, resume, cut}),
    do: {:ok, %{kind: :resume_id, resume: resume, cut: cut}}

  defp event_shape({:user_message, steer}), do: {:ok, %{kind: :user_message, steer: steer}}

  defp event_shape({:compaction, before, after_}),
    do: {:ok, %{kind: :compaction, before: before, after: after_}}

  defp event_shape({:ui_block, call, key, block}),
    do: {:ok, %{kind: :ui_block, call: call, key: key, block: block}}

  defp event_shape(_event), do: :error

  defp terminal_shape({:done, %{stop_reason: stop, usage: usage}}),
    do: {:ok, %{kind: :done, stop: stop, usage: usage}}

  defp terminal_shape({:error, reason}), do: {:ok, %{kind: :error, reason: reason}}
  defp terminal_shape(_terminal), do: :error

  @doc false
  # The tuple of `Helyx.Session.Stream.check/1` that the shape names.
  @spec event_tuple(term()) :: {:ok, term()} | :error
  def event_tuple(%{kind: :stream, event: %{kind: :turn_start} = event} = shape)
      when map_size(shape) == 2 and map_size(event) == 1,
      do: {:ok, :turn_start}

  def event_tuple(%{kind: :stream, event: event} = shape)
      when is_map(event) and map_size(shape) == 2,
      do: stream_tuple(event)

  def event_tuple(%{kind: :end, terminal: %{kind: :done, stop: stop, usage: usage}} = shape)
      when map_size(shape) == 2,
      do: {:ok, {:done, %{stop_reason: stop, usage: usage}}}

  def event_tuple(%{kind: :end, terminal: %{kind: :error, reason: reason}} = shape)
      when map_size(shape) == 2,
      do: {:ok, {:error, reason}}

  def event_tuple(%{kind: :tool_request, call: call} = shape) do
    if map_size(shape) == 3 and Data.call?(call),
      do: {:ok, {:tool_request, call.id, call.name, call.arguments}},
      else: :error
  end

  def event_tuple(%{kind: :approval, approval: approval, call: call} = shape)
      when map_size(shape) == 3,
      do: {:ok, {:approval, approval, call}}

  def event_tuple(%{kind: :resume_id, resume: resume, cut: cut} = shape)
      when map_size(shape) == 3,
      do: {:ok, {:resume_id, resume, cut}}

  def event_tuple(_shape), do: :error

  defp stream_tuple(%{kind: :text_delta, text: text} = shape) when map_size(shape) == 2,
    do: {:ok, {:text_delta, text}}

  defp stream_tuple(%{kind: :thinking_delta, text: text} = shape) when map_size(shape) == 2,
    do: {:ok, {:thinking_delta, text}}

  defp stream_tuple(%{kind: :tool_call, call: call} = shape) do
    if map_size(shape) == 2 and Data.call?(call), do: {:ok, {:tool_call, call}}, else: :error
  end

  defp stream_tuple(%{kind: :message_end, stop: stop, usage: usage} = shape)
       when map_size(shape) == 3,
       do: {:ok, {:message_end, stop, usage}}

  defp stream_tuple(%{kind: :tool_result, call: call, result: {status, text}} = shape)
       when map_size(shape) == 3,
       do: {:ok, {:tool_result, call, {status, text}}}

  defp stream_tuple(%{kind: :resume_id, resume: resume, cut: cut} = shape)
       when map_size(shape) == 3,
       do: {:ok, {:resume_id, resume, cut}}

  defp stream_tuple(%{kind: :user_message, steer: steer} = shape) when map_size(shape) == 2,
    do: {:ok, {:user_message, steer}}

  defp stream_tuple(%{kind: :compaction, before: before, after: after_} = shape)
       when map_size(shape) == 3,
       do: {:ok, {:compaction, before, after_}}

  defp stream_tuple(%{kind: :ui_block, call: call, key: key, block: block} = shape)
       when map_size(shape) == 4,
       do: {:ok, {:ui_block, call, key, block}}

  defp stream_tuple(_shape), do: :error

  @doc false
  @spec event_to_map(term()) :: map()
  def event_to_map(%{kind: :stream, event: %{kind: :turn_start}}),
    do: %{"kind" => "stream", "event" => %{"kind" => "turn_start"}}

  def event_to_map(%{kind: :stream, event: event}),
    do: %{"kind" => "stream", "event" => stream_to_map(event)}

  def event_to_map(%{kind: :end, terminal: %{kind: :done, stop: stop, usage: usage}}),
    do: %{
      "kind" => "end",
      "terminal" => %{
        "kind" => "done",
        "stop" => Atom.to_string(stop),
        "usage" => usage_map(usage)
      }
    }

  def event_to_map(%{kind: :end, terminal: %{kind: :error, reason: reason}}),
    do: %{"kind" => "end", "terminal" => %{"kind" => "error", "reason" => reason}}

  def event_to_map(%{kind: :tool_request, call: call} = shape) do
    %{
      "kind" => "tool_request",
      "call" => Data.call_to_map(call),
      "rejection" => shape.rejection
    }
  end

  def event_to_map(%{kind: :approval, approval: approval, call: call}),
    do: %{"kind" => "approval", "approval" => approval, "call" => call}

  def event_to_map(%{kind: :resume_id, resume: resume, cut: cut}),
    do: %{"kind" => "resume_id", "resume" => resume, "cut" => cut}

  defp stream_to_map(%{kind: :text_delta, text: text}),
    do: %{"kind" => "text_delta", "text" => text}

  defp stream_to_map(%{kind: :thinking_delta, text: text}),
    do: %{"kind" => "thinking_delta", "text" => text}

  defp stream_to_map(%{kind: :tool_call, call: call}),
    do: %{"kind" => "tool_call", "call" => Data.call_to_map(call)}

  defp stream_to_map(%{kind: :message_end, stop: stop, usage: usage}),
    do: %{"kind" => "message_end", "stop" => Atom.to_string(stop), "usage" => usage_map(usage)}

  defp stream_to_map(%{kind: :tool_result, call: call, result: {status, text}}),
    do: %{
      "kind" => "tool_result",
      "call" => call,
      "status" => Atom.to_string(status),
      "text" => text
    }

  defp stream_to_map(%{kind: :resume_id, resume: resume, cut: cut}),
    do: %{"kind" => "resume_id", "resume" => resume, "cut" => cut}

  defp stream_to_map(%{kind: :user_message, steer: steer}),
    do: %{"kind" => "user_message", "steer" => steer}

  defp stream_to_map(%{kind: :compaction, before: before, after: after_}),
    do: %{"kind" => "compaction", "before" => before, "after" => after_}

  defp stream_to_map(%{kind: :ui_block, call: call, key: key, block: block}),
    do: %{"kind" => "ui_block", "call" => call, "key" => key, "block" => block}

  defp usage_map(nil), do: nil
  defp usage_map(usage), do: Data.usage_to_map(usage)

  @doc false
  @spec to_event(term()) :: {:ok, map()} | :error
  def to_event(%{"kind" => "stream"} = map) do
    Data.pairs(map, ~w(kind event), fn ["stream", event] ->
      with {:ok, event} <- to_stream(event) do
        check(%{kind: :stream, event: event})
      end
    end)
  end

  def to_event(%{"kind" => "end"} = map) do
    Data.pairs(map, ~w(kind terminal), fn ["end", terminal] ->
      with {:ok, terminal} <- to_terminal(terminal) do
        check(%{kind: :end, terminal: terminal})
      end
    end)
  end

  def to_event(%{"kind" => "tool_request"} = map) do
    Data.pairs(map, ~w(kind call rejection), fn ["tool_request", call, rejection] ->
      with {:ok, call} <- Data.to_call(call) do
        check(%{kind: :tool_request, call: call, rejection: rejection})
      end
    end)
  end

  def to_event(%{"kind" => "approval"} = map) do
    Data.pairs(map, ~w(kind approval call), fn ["approval", approval, call] ->
      check(%{kind: :approval, approval: approval, call: call})
    end)
  end

  def to_event(%{"kind" => "resume_id"} = map) do
    Data.pairs(map, ~w(kind resume cut), fn ["resume_id", resume, cut] ->
      check(%{kind: :resume_id, resume: resume, cut: cut})
    end)
  end

  def to_event(_map), do: :error

  defp to_terminal(map) do
    Data.pairs(map, ~w(kind stop usage), fn ["done", stop, usage] ->
      with {:ok, stop} <- stop(stop),
           {:ok, usage} <- Data.to_usage(usage) do
        terminal(%{kind: :done, stop: stop, usage: usage})
      end
    end)
    |> case do
      :error ->
        Data.pairs(map, ~w(kind reason), fn ["error", reason] ->
          terminal(%{kind: :error, reason: reason})
        end)

      terminal ->
        terminal
    end
  end

  defp terminal(terminal) do
    if accepted?(Stream.check(end_tuple(terminal))), do: {:ok, terminal}, else: :error
  end

  defp end_tuple(%{kind: :done, stop: stop, usage: usage}),
    do: {:done, %{stop_reason: stop, usage: usage}}

  defp end_tuple(%{kind: :error, reason: reason}), do: {:error, reason}

  defp accepted?({:send, _event, _rejection}), do: true
  defp accepted?({:terminal, _terminal}), do: true
  defp accepted?({:bad, _error}), do: false

  defp to_stream(%{"kind" => "turn_start"} = map) when map_size(map) == 1,
    do: {:ok, %{kind: :turn_start}}

  defp to_stream(map) do
    with :error <- text_stream(map),
         :error <- tool_call_stream(map),
         :error <- message_end_stream(map),
         :error <- tool_result_stream(map),
         :error <- resume_stream(map),
         :error <- user_message_stream(map),
         :error <- compaction_stream(map) do
      ui_block_stream(map)
    end
  end

  defp text_stream(map) do
    case Data.values(map, ~w(kind text)) do
      {:ok, ["text_delta", text]} ->
        {:ok, %{kind: :text_delta, text: text}}

      {:ok, ["thinking_delta", text]} ->
        {:ok, %{kind: :thinking_delta, text: text}}

      _values ->
        :error
    end
  end

  defp tool_call_stream(map) do
    case Data.values(map, ~w(kind call)) do
      {:ok, ["tool_call", call]} ->
        with {:ok, call} <- Data.to_call(call), do: {:ok, %{kind: :tool_call, call: call}}

      _values ->
        :error
    end
  end

  defp message_end_stream(map) do
    case Data.values(map, ~w(kind stop usage)) do
      {:ok, ["message_end", stop, usage]} ->
        with {:ok, stop} <- stop(stop),
             {:ok, usage} <- Data.to_usage(usage) do
          {:ok, %{kind: :message_end, stop: stop, usage: usage}}
        end

      _values ->
        :error
    end
  end

  defp tool_result_stream(map) do
    case Data.values(map, ~w(kind call status text)) do
      {:ok, ["tool_result", call, status, text]} ->
        with {:ok, status} <- status(status) do
          {:ok, %{kind: :tool_result, call: call, result: {status, text}}}
        end

      _values ->
        :error
    end
  end

  defp resume_stream(map) do
    case Data.values(map, ~w(kind resume cut)) do
      {:ok, ["resume_id", resume, cut]} ->
        {:ok, %{kind: :resume_id, resume: resume, cut: cut}}

      _values ->
        :error
    end
  end

  defp user_message_stream(map) do
    case Data.values(map, ~w(kind steer)) do
      {:ok, ["user_message", steer]} ->
        {:ok, %{kind: :user_message, steer: steer}}

      _values ->
        :error
    end
  end

  defp compaction_stream(map) do
    case Data.values(map, ~w(kind before after)) do
      {:ok, ["compaction", before, after_]} ->
        {:ok, %{kind: :compaction, before: before, after: after_}}

      _values ->
        :error
    end
  end

  defp ui_block_stream(map) do
    case Data.values(map, ~w(kind call key block)) do
      {:ok, ["ui_block", call, key, block]} ->
        {:ok, %{kind: :ui_block, call: call, key: key, block: block}}

      _values ->
        :error
    end
  end

  defp status("ok"), do: {:ok, :ok}
  defp status("error"), do: {:ok, :error}
  defp status(_status), do: :error

  for stop <- Message.stop_reasons() do
    defp stop(unquote(Atom.to_string(stop))), do: {:ok, unquote(stop)}
  end

  defp stop(_stop), do: :error
end
