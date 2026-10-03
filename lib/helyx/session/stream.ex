defmodule Helyx.Session.Stream do
  @moduledoc false
  # The boundary of provider output: the context build of the prepare Task,
  # the check of each provider event, and the bounded send to the session.
  # It holds no resource and makes no decision of the turn.

  alias Helyx.Message

  @stop_reasons Message.stop_reasons()

  # A provider cuts each tool result (`Helyx.Provider`), as a tool does. Every
  # output of that cut is at most 51,201 bytes of lines and a notice of less
  # than 200 bytes, so only a result that was not cut is over this limit.
  @max_tool_result_bytes 65_536
  # The most messages that may wait in the session mailbox before a send.
  # A count, not bytes. Core caps a tool result before the send (above)
  # and the open message that the session keeps (`Helyx.Session.Turn`),
  # not the size of one waiting delta or tool call.
  @max_session_queue 10_000

  @integer_reason "an integer in the arguments has more than " <>
                    "#{Message.max_integer_digits()} digits"
  @not_object_reason "the arguments are not a valid JSON object"

  @doc """
  Builds the context of one provider call with the ModelContext and the
  Compaction plugin. The session resolved both at its
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

  @doc """
  Checks one event from a provider. Returns `{:send, event, rejection}`
  for an event that passes, with the checked event and, for a call with
  an integer over the digit limit or with raw argument text (arguments
  that are not a JSON object), the reason that it must not run, or nil.
  A checked tool call is `{:tool_call, call, bytes}`, with the bytes of
  the JSON encode of its id, name, and arguments;
  `{:terminal, terminal}` for a `done` or an `error` event, with the
  integer cap and ready to send; and `{:bad, error}` for a malformed
  event. Arguments or a usage that are a struct are malformed:
  `cap_integers/1` can turn a struct into a string, and the session file
  needs a plain map. A delta or a tool call that is not valid UTF-8 is
  malformed: transcript text is valid from the moment it exists, so the
  file and the providers never see raw bytes. A tool call or a tool request with an
  empty id is malformed: a result names its call by the id.
  """
  @spec check(term()) ::
          {:send, term(), String.t() | nil}
          | {:terminal, {:done, map()} | {:error, term()}}
          | {:bad, {:error, term()}}
  def check({kind, payload} = event)
      when kind in [:text_delta, :thinking_delta] and is_binary(payload) do
    if String.valid?(payload), do: {:send, event, nil}, else: {:bad, malformed(event)}
  end

  def check({:tool_call, call}), do: tool_call(call)

  # The stop reason set is closed (`Message.stop_reasons/0`), and the
  # session file holds only JSON. A terminal whose stop reason is outside
  # the set, or whose usage the file cannot encode, fails the turn here,
  # before the message exists, instead of raising in persist and silently
  # turning persistence off for the rest of the session. A new plain map:
  # the pattern also matches a struct and a map with more keys, and the
  # session needs this shape.
  def check({:done, %{stop_reason: reason, usage: usage}} = terminal)
      when reason in @stop_reasons and is_non_struct_map(usage) do
    case capped_usage(usage) do
      {:ok, usage} -> {:terminal, {:done, %{stop_reason: reason, usage: usage}}}
      :error -> {:bad, malformed(terminal)}
    end
  end

  # The reason goes to the session, its events, and its log as it is, so it
  # gets the integer cap here, as every other value from a provider does.
  def check({:error, reason}), do: {:terminal, {:error, Message.cap_integers(reason)}}

  def check({tag, _, _} = event) when tag in [:message_end, :tool_result, :resume] do
    case provider_event(event) do
      {:ok, event} -> {:send, event, nil}
      {:error, _} = error -> {:bad, error}
    end
  end

  # The session looks the steer up by its id and appends its own text, the
  # text that it checked at the client call.
  def check({:user_message, steer_id} = event) when is_binary(steer_id), do: {:send, event, nil}

  # A provider asks the session to run a Helyx tool. The arguments get the
  # checks of a tool call, and the checked call goes on as
  # `{:tool_request, call, bytes}`, with the bytes of a tool call; a call
  # with a rejection reason gets it, and the session answers it with an
  # error result (`Helyx.Session.Server.ToolRuns`).
  def check({:tool_request, id, name, args}) do
    case tool_call(%Message.ToolCall{id: id, name: name, arguments: args}) do
      {:send, {:tool_call, call, bytes}, rejection} ->
        {:send, {:tool_request, call, bytes}, rejection}

      # The call of the error, so no raw argument text is in it.
      {:bad, {:error, {:bad_stream_event, {:tool_call, call}}}} ->
        {:bad, malformed({:tool_request, call.id, call.name, call.arguments})}
    end
  end

  def check(other), do: {:bad, malformed(other)}

  # The one place where tool call arguments enter the session from a
  # provider (on resume, Session.File applies the same function). An
  # integer over the digit limit is replaced here, before the first JSON
  # encode, which is quadratic in the digits (#79). The transcript, the
  # events, the session file, the tool, and the next provider request thus
  # never hold it. A call with such an integer gets its rejection reason.
  # An empty id is malformed: the next request names a result by the id of
  # its call.
  defp tool_call(%Message.ToolCall{id: id, name: name, arguments: args})
       when is_binary(id) and id != "" and is_binary(name) and is_non_struct_map(args) do
    capped = Message.cap_integers(args)
    # A new struct: the pattern also matches a call with one more key.
    call = %Message.ToolCall{id: id, name: name, arguments: capped}
    reason = if capped != args, do: @integer_reason

    # The size of the encode goes with the call: the session counts it in
    # the bound of the open message (`Helyx.Session.Turn`), with no encode.
    case Message.encoded_size([id, name, capped]) do
      {:ok, bytes} -> {:send, {:tool_call, call, bytes}, reason}
      :error -> {:bad, malformed({:tool_call, call})}
    end
  end

  # Arguments that did not decode to a JSON object come as their raw text.
  # The text is dropped here, so the transcript, the file, and the error
  # result never hold it: the call goes on with `%{}` and its rejection.
  defp tool_call(%Message.ToolCall{arguments: args} = call) when is_binary(args) do
    with {:send, event, nil} <- tool_call(%{call | arguments: %{}}),
         do: {:send, event, @not_object_reason}
  end

  defp tool_call(call), do: {:bad, malformed({:tool_call, call})}

  # The events that close a message, carry a result, a resume id, or a
  # taken steer. A message end is checked like the
  # `done` terminal. The provider cuts a result to the tool result limits;
  # a result over this limit was not cut, so it fails the turn. The check
  # measures the text as sent. Then the text is made valid UTF-8, which can
  # make it up to three times larger: this is the boundary of a provider
  # result, as the hands are for a tool of the session.
  defp provider_event({:message_end, reason, usage} = event)
       when reason in @stop_reasons and is_non_struct_map(usage) do
    case capped_usage(usage) do
      {:ok, usage} -> {:ok, {:message_end, reason, usage}}
      :error -> malformed(event)
    end
  end

  # The session uses the id only to find an open call, so an id that is
  # not valid UTF-8 is dropped there like an unknown id.
  defp provider_event({:tool_result, id, {status, text}})
       when is_binary(id) and status in [:ok, :error] and is_binary(text) do
    if byte_size(text) > @max_tool_result_bytes,
      do: {:error, too_large(text)},
      else: {:ok, {:tool_result, id, Message.scrub({status, text})}}
  end

  defp provider_event({:resume, id, cut} = event) when is_integer(cut) and cut >= 0 do
    # No integer over the digit limit reaches the session (see
    # `Helyx.Message.cap_integers/1`).
    if Message.resume_id?(id) and Message.cap_integers(cut) == cut,
      do: {:ok, event},
      else: malformed(event)
  end

  defp provider_event(event), do: malformed(event)

  defp malformed(event), do: {:error, {:bad_stream_event, event}}

  # The error holds the size, never the text.
  defp too_large(text), do: {:tool_result_too_large, byte_size(text), @max_tool_result_bytes}

  # The usage gets the same encodes as the arguments, so the same cap.
  defp capped_usage(usage) do
    usage = Message.cap_integers(usage)
    if Message.encodable?(usage), do: {:ok, usage}, else: :error
  end

  @doc "The error text of a tool call that does not run, from its rejection reason."
  @spec not_run(String.t()) :: String.t()
  def not_run(reason), do: "tool call not run: " <> reason

  @doc """
  Sends a message to the session, or to a provider process. Every send of
  a provider event to the session goes through here. The check before it
  bounds the receiver's mailbox: the sends have no ack, so a provider that
  is faster than the session would grow it with no limit (#197). Over #{@max_session_queue}
  waiting messages nothing is sent, and the result is `{:error,
  {behind, length, #{@max_session_queue}}}`. `behind` names the receiver:
  `:session_behind`, or `:provider_behind` for the provider process that
  a model Task of `Helyx.Provider.Loop` sends to.
  """
  @spec send_checked(pid(), term(), :session_behind | :provider_behind) ::
          :ok | {:error, {:session_behind | :provider_behind, non_neg_integer(), pos_integer()}}
  def send_checked(pid, message, behind \\ :session_behind) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} when len > @max_session_queue ->
        {:error, {behind, len, @max_session_queue}}

      # A dead session (nil) gets the send like a live one: nothing reads it.
      _ ->
        send(pid, message)
        :ok
    end
  end
end
