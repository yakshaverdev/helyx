defmodule Helyx.Session.Stream do
  @moduledoc false
  # The work of one provider call. `run/1` runs in the provider Task: it
  # builds the context, compacts it, calls the provider, checks each stream
  # event, and sends each event that passes to the session. It returns the
  # first terminal. It holds no resource and makes no decision of the turn.

  alias Helyx.Message

  @stop_reasons Message.stop_reasons()

  # The connected providers cut each tool result (`Helyx.Provider`). Every
  # output of that cut is at most 51,201 bytes of lines and a notice of less
  # than 200 bytes, so only a result that was not cut is over this limit.
  @max_tool_result_bytes 65_536

  # The reason of a rejected call (`Helyx.Provider`), and the reason Core
  # gives a call with an integer over the digit limit.
  @max_reason_bytes 1_024
  @max_notice_bytes Helyx.Provider.max_notice_bytes()
  # The most messages that may wait in the session mailbox before a send.
  # A count, not bytes: every event is already capped.
  @max_session_queue 10_000

  @integer_reason "an integer in the arguments has more than " <>
                    "#{Message.max_integer_digits()} digits"

  # A call the provider rejected, with the reason, or nil.
  @type rejection :: {Message.ToolCall.t(), String.t()} | nil

  @type terminal ::
          {:done, %{stop_reason: atom(), usage: map()}} | {:error, term()} | :stream_ended

  @type args :: %{
          model_context: module() | nil,
          compaction: module() | nil,
          provider: module(),
          model: String.t(),
          context: Helyx.Context.t(),
          opts: keyword(),
          session: pid(),
          turn_id: String.t()
        }

  @doc """
  Runs one provider call. Sends the session `{:stream_event, turn_id, event}`
  for each event that passes the checks, and `{:rejected_call, turn_id, call,
  reason}` before the stream event of a call that the provider rejected or
  that has an integer over the digit limit. Before each send it reads the
  length of the session's message queue; over #{@max_session_queue} the
  call ends with `{:error, {:session_behind, length, #{@max_session_queue}}}`.
  """
  @spec run(args()) :: terminal()
  def run(%{
        model_context: model_context,
        compaction: compaction,
        provider: provider,
        model: model,
        context: context,
        opts: opts,
        session: session,
        turn_id: turn_id
      }) do
    # Context building runs inside the Task so plugin code never blocks the
    # session and a plugin that raises fails the turn, not the session.
    result =
      with {:ok, context} <- prepare(model_context, compaction, context, opts) do
        case provider.stream(model, context, opts) do
          {:ok, stream} -> consume(stream, session, turn_id)
          {:error, reason} -> {:error, reason}
        end
      end

    # Every terminal leaves the Task through this cap, so no error reason
    # and no malformed event in one brings an integer over the digit
    # limit to the session (see `Helyx.Message.cap_integers/1`). A raise
    # or an exit is not a terminal: the `:DOWN` handler of the session
    # reports it.
    Message.cap_integers(result)
  end

  @doc """
  Builds the context of one provider call with the ModelContext and the
  Compaction plugin, for every turn mode. The session resolved both at its
  start; nil means none, and the context goes on unchanged. The return of
  each plugin is checked at the boundary. Returns `{:error, {:bad_context,
  :model_context | :compaction}}` when a plugin returns anything but a
  `Helyx.Context` with its three fields: a system prompt that is nil or a
  string, and two lists. The reason names the plugin, not the value.
  """
  @spec prepare(module() | nil, module() | nil, Helyx.Context.t(), keyword()) ::
          {:ok, Helyx.Context.t()} | {:error, {:bad_context, :model_context | :compaction}}
  def prepare(model_context, compaction, context, opts) do
    context = if model_context, do: model_context.build(context, opts), else: context

    with {:ok, context} <- checked_context(context, :model_context) do
      context = if compaction, do: compaction.compact(context, opts), else: context
      checked_context(context, :compaction)
    end
  end

  # The size check rejects a struct that a plugin forged by removing or adding
  # keys. The elements of the lists are not checked here.
  defp checked_context(
         %Helyx.Context{system: system, messages: messages, tools: tools} = context,
         _plugin
       )
       when map_size(context) == 4 and (is_nil(system) or is_binary(system)) and
              is_list(messages) and is_list(tools),
       do: {:ok, context}

  defp checked_context(_other, plugin), do: {:error, {:bad_context, plugin}}

  # Forwards well-formed stream events of a local turn to the session and
  # returns the first terminal event. A malformed event is a terminal error.
  defp consume(stream, session, turn_id) do
    Enum.reduce_while(stream, :stream_ended, fn event, acc ->
      case check(event, false) do
        {:send, event, rejection} -> sent(send_event(session, turn_id, event, rejection), acc)
        {:terminal, terminal} -> {:halt, terminal}
        {:bad, error} -> {:halt, error}
      end
    end)
  end

  defp sent(:ok, acc), do: {:cont, acc}
  defp sent(error, _acc), do: {:halt, error}

  @doc """
  Checks one stream event from a provider. Returns `{:send, event,
  rejection}` for an event that passes, with the checked event and
  `{call, reason}` for a call that `send_event/4` sends as a
  `{:rejected_call, ...}` message before it, or nil;
  `{:terminal, terminal}` for a `done` or an `error` event; and `{:bad,
  error}` for a malformed event. `connected?` allows the events of a
  connected turn (`Helyx.Session.ProviderProcess`). Arguments or a usage that are
  a struct are malformed: `cap_integers/1` can turn a struct into a
  string, and the session file needs a plain map. A delta or a tool call that is not valid UTF-8 is
  malformed: transcript text is valid from the moment it exists, so the file
  and the providers never see raw bytes.
  """
  @spec check(term(), boolean()) ::
          {:send, term(), rejection()}
          | {:terminal, terminal()}
          | {:bad, {:error, term()}}
  def check({kind, payload} = event, _connected?)
      when kind in [:text_delta, :thinking_delta] and is_binary(payload) do
    if String.valid?(payload), do: {:send, event, nil}, else: {:bad, malformed(event)}
  end

  def check({:tool_call, call}, _connected?), do: tool_call(call, nil)

  # A call the provider rejected. Only a local turn answers it: a connected
  # provider sends its own error result. The reason is transcript text: the
  # bound keeps the result text small, and `tool_call/2` checks that it is
  # valid UTF-8.
  def check({:rejected_tool_call, call, reason}, false = _connected?)
      when is_binary(reason) and byte_size(reason) <= @max_reason_bytes,
      do: tool_call(call, reason)

  # A notice for the user, from any turn. It becomes a `:notice` event
  # only: it never joins the transcript.
  def check({:notice, text} = event, _connected?)
      when is_binary(text) and byte_size(text) <= @max_notice_bytes do
    if String.valid?(text), do: {:send, event, nil}, else: {:bad, malformed(event)}
  end

  # The stop reason set is closed (`Message.stop_reasons/0`), and the
  # session file holds only JSON. A terminal whose stop reason is outside
  # the set, or whose usage the file cannot encode, fails the turn here,
  # before the message exists, instead of raising in persist and silently
  # turning persistence off for the rest of the session. A new plain map:
  # the pattern also matches a struct and a map with more keys, and the
  # session needs this shape after the cap at the Task exit.
  def check({:done, %{stop_reason: reason, usage: usage}} = terminal, _connected?)
      when reason in @stop_reasons and is_non_struct_map(usage) do
    case capped_usage(usage) do
      {:ok, usage} -> {:terminal, {:done, %{stop_reason: reason, usage: usage}}}
      :error -> {:bad, malformed(terminal)}
    end
  end

  def check({:error, _} = terminal, _connected?), do: {:terminal, terminal}

  # Only a connected provider sends these; in a local turn they are
  # malformed.
  def check({tag, _, _} = event, true = _connected?)
      when tag in [:message_end, :tool_result, :resume, :user_message] do
    case connected_event(event) do
      {:ok, event} -> {:send, event, nil}
      {:error, _} = error -> {:bad, error}
    end
  end

  # A connected provider asks the session to run a Helyx tool. The
  # arguments get the checks of a tool call; a call with an integer over
  # the digit limit gets its rejection, and the session answers it with an
  # error result and does not run it.
  def check({:tool_request, id, name, args} = event, true = _connected?) do
    case tool_call(%Message.ToolCall{id: id, name: name, arguments: args}, nil) do
      {:send, {:tool_call, call}, rejection} ->
        {:send, {:tool_request, call.id, call.name, call.arguments}, rejection}

      {:bad, _error} ->
        {:bad, malformed(event)}
    end
  end

  def check(other, _connected?), do: {:bad, malformed(other)}

  # The one place where tool call arguments enter the session from a
  # provider (on resume, Session.File applies the same function). An
  # integer over the digit limit is replaced here, before the first JSON
  # encode, which is quadratic in the digits (#79). The transcript, the
  # events, the session file, the tool, and the next provider request thus
  # never hold it. A call with such an integer is rejected, as is a call the
  # provider rejected (`reason` not nil). The rejection goes to the session
  # only when the call passed every check, before its stream event.
  defp tool_call(%Message.ToolCall{id: id, name: name, arguments: args}, rejected)
       when is_binary(id) and is_binary(name) and is_non_struct_map(args) do
    capped = Message.cap_integers(args)
    # A new struct: the pattern also matches a call with one more key.
    call = %Message.ToolCall{id: id, name: name, arguments: capped}
    reason = rejected || if capped != args, do: @integer_reason

    # A reason that is not valid UTF-8 does not encode.
    if Message.encodable?([id, name, capped, rejected]),
      do: {:send, {:tool_call, call}, reason && {call, reason}},
      else: {:bad, malformed(call_event(call, rejected))}
  end

  defp tool_call(call, rejected), do: {:bad, malformed(call_event(call, rejected))}

  # The event of a call, for the error of a malformed one.
  defp call_event(call, nil), do: {:tool_call, call}
  defp call_event(call, reason), do: {:rejected_tool_call, call, reason}

  # The events of a connected turn. A message end is checked like the
  # `done` terminal. The provider cuts a result to the tool result limits;
  # a result over this limit was not cut, so it fails the turn. The check
  # measures the text as sent. Then the text is made valid UTF-8, which can
  # make it up to three times larger: this is the boundary of a provider
  # result, as the hands are for a tool of the session.
  defp connected_event({:message_end, reason, usage} = event)
       when reason in @stop_reasons and is_non_struct_map(usage) do
    case capped_usage(usage) do
      {:ok, usage} -> {:ok, {:message_end, reason, usage}}
      :error -> malformed(event)
    end
  end

  # The session uses the id only to find an open call, so an id that is
  # not valid UTF-8 is dropped there like an unknown id.
  defp connected_event({:tool_result, id, {status, text}})
       when is_binary(id) and status in [:ok, :error] and is_binary(text) do
    if byte_size(text) > @max_tool_result_bytes,
      do: {:error, too_large(text)},
      else: {:ok, {:tool_result, id, scrub({status, text})}}
  end

  defp connected_event({:resume, id, cut} = event) when is_integer(cut) and cut >= 0 do
    # No integer over the digit limit reaches the session (see
    # `Helyx.Message.cap_integers/1`).
    if Message.provider_id?(id) and Message.cap_integers(cut) == cut,
      do: {:ok, event},
      else: malformed(event)
  end

  # The session looks the steer up by its id and appends its own text, the
  # text that it checked at the client call; the text here is not used.
  defp connected_event({:user_message, steer_id, text} = event)
       when is_binary(steer_id) and is_binary(text),
       do: {:ok, event}

  defp connected_event(event), do: malformed(event)

  # The rule of `scrub/1` in `Helyx.Session.Hands`, the other boundary of
  # tool text. Valid text, the common case, is passed through without a copy.
  defp scrub({status, text}) do
    if String.valid?(text), do: {status, text}, else: {status, String.replace_invalid(text)}
  end

  defp malformed(event), do: {:error, {:bad_stream_event, event}}

  # The error holds the size, never the text.
  defp too_large(text), do: {:tool_result_too_large, byte_size(text), @max_tool_result_bytes}

  # The usage gets the same encodes as the arguments, so the same cap.
  defp capped_usage(usage) do
    usage = Message.cap_integers(usage)
    if Message.encodable?(usage), do: {:ok, usage}, else: :error
  end

  @doc """
  Sends one checked event to the session as `{:stream_event, turn_id,
  event}`, after the `{:rejected_call, turn_id, call, reason}` of a rejected
  call, with the check of `send_checked/2`.
  """
  @spec send_event(pid(), String.t(), term(), rejection()) ::
          :ok | {:error, {:session_behind, non_neg_integer(), pos_integer()}}
  def send_event(session, turn_id, event, nil),
    do: send_checked(session, {:stream_event, turn_id, event})

  def send_event(session, turn_id, event, {call, reason}) do
    with :ok <- send_checked(session, {:rejected_call, turn_id, call, reason}) do
      send(session, {:stream_event, turn_id, event})
      :ok
    end
  end

  @doc """
  Sends a message to the session. Every send of a provider event to the
  session goes through here. The check before it bounds the session
  mailbox: the sends have no ack, so a provider that is faster than the
  session would grow it with no limit (#197). Over #{@max_session_queue}
  waiting messages nothing is sent, and the result is `{:error,
  {:session_behind, length, #{@max_session_queue}}}`.
  """
  @spec send_checked(pid(), term()) ::
          :ok | {:error, {:session_behind, non_neg_integer(), pos_integer()}}
  def send_checked(session, message) do
    case Process.info(session, :message_queue_len) do
      {:message_queue_len, len} when len > @max_session_queue ->
        {:error, {:session_behind, len, @max_session_queue}}

      # A dead session (nil) gets the send like a live one: nothing reads it.
      _ ->
        send(session, message)
        :ok
    end
  end
end
