defmodule Helyx.Session.Stream do
  @moduledoc false
  # The boundary of provider output: the context build of the prepare Task,
  # the check of each provider event, and the bounded send to the session.
  # It holds no resource and makes no decision of the turn.

  alias Helyx.Message

  # `:aborted` and `:error` are the stop reasons of a turn that the session
  # cut; a provider does not send them.
  @stop_reasons Message.stop_reasons() -- [:aborted, :error]

  # The most messages that may wait in the session mailbox before a send.
  # A count, not bytes. Core cuts a tool result before the send
  # (`Helyx.Message.cut_result/1`) and caps the open message that the
  # session keeps (`Helyx.Session.Turn`), not the size of one waiting delta
  # or tool call.
  @max_session_queue 10_000

  # A token count of a compaction: the wire bound of a token count
  # (`docs/features/usage-and-limits.md`), or nil.
  defguardp is_token_count(n) when is_nil(n) or (is_integer(n) and n >= 0 and n <= 1_000_000_000)

  @integer_reason "an integer in the arguments has more than " <>
                    "#{Message.max_integer_digits()} digits"

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
  an integer over the digit limit, the reason that it must not run, or nil.
  A checked tool call is `{:tool_call, call, bytes}`, with the bytes of
  the JSON encode of its id, name, and arguments;
  `{:terminal, terminal}` for a `done` or an `error` event, ready to
  send, with the integer cap on an error reason; and `{:bad, error}` for
  a malformed event. Arguments that are not a plain map are malformed: the
  session file needs a plain map. The error of a call whose arguments are
  raw text holds `%{}` in place of the text. The usage of a `done` or a
  `message_end` is nil or a `Helyx.Usage` within the struct bound
  (`Helyx.Usage.valid?/1`); anything else is malformed. A delta or a tool call that is not valid UTF-8 is
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

  # The stop reason set is closed (`@stop_reasons`), and the session file
  # holds only JSON. A terminal whose stop reason is outside
  # the set, or whose usage is not within the struct bound, fails the turn
  # here, before the message exists, instead of raising in persist and
  # silently turning persistence off for the rest of the session. A new
  # plain map: the pattern also matches a struct and a map with more keys,
  # and the session needs this shape.
  def check({:done, %{stop_reason: reason, usage: usage}} = terminal)
      when reason in @stop_reasons do
    if valid_usage?(usage),
      do: {:terminal, {:done, %{stop_reason: reason, usage: usage}}},
      else: {:bad, malformed(terminal)}
  end

  # The reason goes to the session, its events, and its log as it is, so it
  # gets the integer cap here, as every other value from a provider does.
  def check({:error, reason}), do: {:terminal, {:error, Message.cap_integers(reason)}}

  def check({tag, _, _} = event) when tag in [:message_end, :tool_result, :resume_id] do
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

  # A compaction of the provider's own history, with its token counts
  # before and after, each nil when the provider does not know it.
  def check({:compaction, before, after_} = event)
      when is_token_count(before) and is_token_count(after_),
      do: {:send, event, nil}

  def check(other), do: {:bad, malformed(other)}

  # The one place where tool call arguments enter the session from a
  # provider (on resume, Session.File caps them). Arguments with an integer
  # over the digit limit are found here, before the first JSON encode,
  # which is quadratic in the digits (#79): the call goes on with `%{}` and
  # its rejection. An empty id is malformed: the next request names a
  # result by the id of its call.
  defp tool_call(%Message.ToolCall{id: id, name: name, arguments: args} = call)
       when is_binary(id) and id != "" and is_binary(name) and is_non_struct_map(args) do
    if Message.big_integer?(args) do
      rejected(call, @integer_reason)
    else
      # A new struct: the pattern also matches a call with one more key.
      checked = %Message.ToolCall{id: id, name: name, arguments: args}

      # The size of the encode goes with the call: the session counts it in
      # the bound of the open message (`Helyx.Session.Turn`), with no encode.
      case Message.encoded_size([id, name, args]) do
        {:ok, bytes} -> {:send, {:tool_call, checked, bytes}, nil}
        :error -> {:bad, malformed({:tool_call, checked})}
      end
    end
  end

  # Arguments that did not decode to a JSON object can come as their raw
  # text. The error drops the text, so the log and the client never get it.
  defp tool_call(%Message.ToolCall{arguments: args} = call) when is_binary(args),
    do: {:bad, malformed({:tool_call, %{call | arguments: %{}}})}

  defp tool_call(call), do: {:bad, malformed({:tool_call, call})}

  # A call that must not run goes on with `%{}` and its rejection reason.
  defp rejected(call, reason) do
    with {:send, event, nil} <- tool_call(%{call | arguments: %{}}),
         do: {:send, event, reason}
  end

  # The events that close a message, carry a result, a resume id, or a
  # taken steer. A message end is checked like the
  # `done` terminal. A result text is made valid UTF-8 and cut to the tool
  # result limit, so a large result never fails the turn: this is the
  # boundary of a provider result, as the hands are for a tool of the
  # session.
  defp provider_event({:message_end, reason, usage} = event) when reason in @stop_reasons do
    if valid_usage?(usage), do: {:ok, {:message_end, reason, usage}}, else: malformed(event)
  end

  # The session uses the id only to find an open call, so an id that is
  # not valid UTF-8 is dropped there like an unknown id.
  defp provider_event({:tool_result, id, {status, text}})
       when is_binary(id) and status in [:ok, :error] and is_binary(text),
       do: {:ok, {:tool_result, id, {status, Message.cut_result(text)}}}

  defp provider_event({:resume_id, id, cut} = event) when is_integer(cut) and cut >= 0 do
    # No integer over the digit limit reaches the session.
    if Message.resume_id?(id) and not Message.big_integer?(cut),
      do: {:ok, event},
      else: malformed(event)
  end

  defp provider_event(event), do: malformed(event)

  defp malformed(event), do: {:error, {:bad_stream_event, event}}

  # Range checks only, with no encode: they also keep every integer under
  # the digit limit of `Helyx.Message`.
  defp valid_usage?(usage), do: usage == nil or Helyx.Usage.valid?(usage)

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
