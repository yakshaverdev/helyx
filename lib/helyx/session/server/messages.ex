defmodule Helyx.Session.Server.Messages do
  @moduledoc false
  # The records of a session: the only writer of `transcript`, `file`,
  # `model`, `provider`, and `resume_ids` in `Helyx.Session.Server.State`. Each
  # operation changes the open assistant message, the transcript, the
  # session file, and emits its events together. The rule: no message goes
  # between a call and its result. A call still open gets its `aborted`
  # result before the next message joins (docs/features/long-lived-harness.md).

  require Logger

  import Helyx.Session.Server.Record, only: [emit: 3, emit: 4]

  alias Helyx.{Message, ModelRef}
  alias Helyx.Session.Server.State
  alias Helyx.Session.{Transcript, Turn}

  def append_user(state, text) do
    user = Message.user(text)

    append_message(state, user)
    |> emit(:message_start, %{message: user})
    |> emit(:message_end, %{message: user})
  end

  # Adds one stream event to the open assistant message and emits its
  # message_update; the first event opens the message. A delta over the
  # bound of `Turn.add_block/2` adds nothing: `{:error, reason, state}`,
  # with the message open.
  def delta(state, event) do
    %State{activity: turn} = state = start_assistant_message(state)

    case Turn.add_block(turn, event) do
      {:ok, turn} -> {:ok, emit(%{state | activity: turn}, :message_update, Map.new([event]))}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Closes the open assistant message at its `message_end`
  # (`close_assistant/3`); each of its calls starts.
  def end_assistant(state, stop_reason, usage) do
    {state, assistant} = close_assistant(state, stop_reason, usage)
    calls = for %Message.ToolCall{} = call <- assistant.content, do: call
    state = Enum.reduce(calls, state, &emit(&2, :tool_execution_start, %{tool_call: &1}))
    %{state | activity: Turn.close_partial(state.activity)}
  end

  # The first result of a call in the open message closes the message
  # (`docs/features/long-lived-harness.md`, "Built in #385"). The message has
  # no usage: the terminal keeps the turn usage. A result goes to the first
  # open call with its id (`Transcript.open_calls/1`), so the transcript,
  # the file, and the replay agree. A result for no open call is dropped.
  def tool_result(state, call_id, result) do
    state = close_if(state, &match?(%Message.ToolCall{id: ^call_id}, &1))

    case Enum.find(Transcript.open_calls(state.transcript), &(&1.id == call_id)) do
      nil -> state
      call -> record_result(call, result, state)
    end
  end

  # The provider took a steer. The open assistant message closes first and
  # its calls start, as at a `message_end`. Then every call still open gets
  # its `aborted` result: no message goes between a call and its result.
  def take_steer(%State{activity: %Turn{partial: nil}} = state, text),
    do: state |> abort_open_calls() |> append_user(text)

  def take_steer(%State{activity: %Turn{partial: partial}} = state, text) do
    stop = if Enum.any?(partial, &match?(%Message.ToolCall{}, &1)), do: :tool_use, else: :end_turn
    take_steer(end_assistant(state, stop, %{}), text)
  end

  # The close at the `done` of the turn: the open message joins, and each
  # open call gets its `aborted` result with no `tool_execution_start`.
  # Returns the state and the closed message.
  def end_turn(state, stop_reason, usage) do
    {state, assistant} = close_assistant(state, stop_reason, usage)
    {abort_open_calls(state), assistant}
  end

  # At an abort or a failure, an open message with a tool call joins the
  # transcript as at the other closes (stop `:tool_use`, its calls start),
  # and each open call gets its `aborted` result. An open message with text
  # only does not join: it gets a message_end with the stop reason, so
  # clients do not keep it open.
  def close_turn(state, stop_reason, reason) do
    state
    |> close_if(&match?(%Message.ToolCall{}, &1))
    |> abort_open_calls()
    |> close_partial_message(stop_reason, reason)
  end

  # A model switch: the record on disk and `model_change`. It has no turn.
  def set_model(%State{} = state, %ModelRef{} = ref, provider) do
    model = ModelRef.to_string(ref)
    state = persist(state, &Helyx.Session.File.append_model_change(&1, model))
    emit(%{state | model: ref, provider: provider}, nil, :model_change, %{model: model})
  end

  # A resume id of the turn's provider, with the transcript length now.
  # The provider id is the prefix of the turn's model ref: `find/2` matched
  # it, so the session runs no plugin code for it.
  def resume(%State{activity: %Turn{} = turn} = state, id, cut) do
    provider = turn.model.provider
    state = persist(state, &Helyx.Session.File.append_resume_id(&1, provider, id))
    ids = Map.put(state.resume_ids, provider, {id, length(state.transcript)})
    data = %{provider: provider, resume_id: id, lost: turn.resumed != nil, cut: cut}
    emit(%{state | resume_ids: ids}, :provider_session, data)
  end

  # Emits message_start for the assistant message on the first stream event.
  defp start_assistant_message(%State{activity: %Turn{partial: nil} = turn} = state) do
    state = %{state | activity: %{turn | partial: []}}
    emit(state, :message_start, %{message: Turn.assistant_message(state.activity, [])})
  end

  defp start_assistant_message(state), do: state

  # Appends the assistant message of the stream so far and emits its
  # message_end. Returns it. No message goes between a
  # call and its result: the calls still open get their aborted results
  # first, and a later result is dropped.
  defp close_assistant(state, stop_reason, usage) do
    state = state |> abort_open_calls() |> start_assistant_message()
    assistant = Turn.assistant_message(state.activity, stop_reason: stop_reason, usage: usage)
    {emit(append_message(state, assistant), :message_end, %{message: assistant}), assistant}
  end

  defp close_if(%State{activity: %Turn{partial: [_ | _] = partial}} = state, block?) do
    if Enum.any?(partial, block?), do: end_assistant(state, :tool_use, %{}), else: state
  end

  defp close_if(state, _block?), do: state

  # Appends the tool result message to the transcript and emits
  # tool_execution_end.
  defp record_result(call, result, state) do
    message = Message.tool_result(call, result)
    emit(append_message(state, message), :tool_execution_end, %{message: message})
  end

  # Each open call (`Transcript.open_calls/1`) gets an `aborted` error
  # result: no message goes between a call and its result, and the next
  # provider call sees a complete pair.
  defp abort_open_calls(%State{} = state) do
    Enum.reduce(
      Transcript.open_calls(state.transcript),
      state,
      &record_result(&1, {:error, "aborted"}, &2)
    )
  end

  defp close_partial_message(%State{activity: %Turn{partial: nil}} = state, _stop, _reason),
    do: state

  defp close_partial_message(state, stop_reason, reason) do
    emit(state, :message_end, %{
      message: Turn.assistant_message(state.activity, stop_reason: stop_reason),
      error: reason
    })
  end

  # Appends a completed message to the transcript and, when the session has
  # a file, to disk. Streamed partial messages never come through here.
  defp append_message(%State{} = state, %Message{} = message) do
    state = persist(state, &Helyx.Session.File.append_message(&1, message))
    %{state | transcript: state.transcript ++ [message]}
  end

  defp persist(%State{file: nil} = state, _append), do: state

  defp persist(%State{file: file} = state, append) do
    %{state | file: append.(file)}
  rescue
    # A disk failure must not take the session down. The turn, or the model
    # switch, goes on in memory; persistence stays off for this session. Only
    # the disk write is caught: a value the file cannot encode is rejected
    # at the stream boundary (see `Helyx.Session.Stream`), and a model ref by
    # `ModelRef.parse/1`, so an encode error here is a
    # bug and crashes loudly rather than silently losing the rest of the
    # session. One notice with a fixed text tells the clients, and the
    # log has the error.
    error in File.Error ->
      Logger.warning("session file append failed, persistence off: " <> Exception.message(error))
      text = "the session file could not be written; the rest of this session is not saved"
      emit(%{state | file: nil}, turn_id(state.activity), :notice, %{text: text})
  end

  defp turn_id(%Turn{id: id}), do: id
  defp turn_id(_idle_or_wait), do: nil
end
