defmodule Helyx.Session.Server.Messages do
  @moduledoc false
  # The messages of a turn in the transcript, in order. The rule: no
  # message goes between a call and its result. A call still open gets its
  # `aborted` result before the next message joins
  # (docs/features/long-lived-harness.md).

  import Helyx.Session.Server.Record, only: [append_message: 2, emit: 3]

  alias Helyx.Message
  alias Helyx.Session.Server.State
  alias Helyx.Session.{Transcript, Turn}

  def append_user(state, text) do
    user = Message.user(text)

    append_message(state, user)
    |> emit(:message_start, %{message: user})
    |> emit(:message_end, %{message: user})
  end

  # Emits message_start for the assistant message on the first stream event.
  def start_assistant_message(%State{activity: %Turn{partial: nil} = turn} = state) do
    state = %{state | activity: %{turn | partial: []}}
    emit(state, :message_start, %{message: Turn.assistant_message(state.activity, [])})
  end

  def start_assistant_message(state), do: state

  # Appends the assistant message of the stream so far and emits its
  # message_end. Returns it and its tool calls. No message goes between a
  # call and its result: the calls still open get their aborted results
  # first, and a later result is dropped.
  def close_assistant(state, stop_reason, usage) do
    state = state |> abort_open_calls() |> start_assistant_message()
    assistant = Turn.assistant_message(state.activity, stop_reason: stop_reason, usage: usage)
    state = emit(append_message(state, assistant), :message_end, %{message: assistant})
    {state, assistant, for(%Message.ToolCall{} = call <- assistant.content, do: call)}
  end

  # Closes the open assistant message (`close_assistant/3`); each of its
  # calls starts.
  def end_assistant(state, stop_reason, usage) do
    {state, _assistant, calls} = close_assistant(state, stop_reason, usage)
    state = Enum.reduce(calls, state, &emit(&2, :tool_execution_start, %{tool_call: &1}))
    put_in(state.activity.partial, nil)
  end

  # The first result of a call in the open message closes the message
  # (`docs/features/long-lived-harness.md`, "Built in #385"). The message has
  # no usage: the terminal keeps the turn usage.
  def close_for_result(state, call_id),
    do: close_if(state, &match?(%Message.ToolCall{id: ^call_id}, &1))

  # At an abort or a failure, an open message with a tool call joins the
  # transcript as at the other closes (stop `:tool_use`, its calls start),
  # so its calls can get their `aborted` results. An open message with text
  # only does not join (`close_partial_message/3`).
  def close_with_calls(state), do: close_if(state, &match?(%Message.ToolCall{}, &1))

  defp close_if(%State{activity: %Turn{partial: [_ | _] = partial}} = state, block?) do
    if Enum.any?(partial, block?), do: end_assistant(state, :tool_use, %{}), else: state
  end

  defp close_if(state, _block?), do: state

  # Appends the tool result message to the transcript and emits
  # tool_execution_end.
  def record_result(call, result, state) do
    message = Message.tool_result(call, result)
    emit(append_message(state, message), :tool_execution_end, %{message: message})
  end

  # Each open call (`Transcript.open_calls/1`) gets an `aborted` error
  # result: no message goes between a call and its result, and the next
  # provider call sees a complete pair.
  def abort_open_calls(%State{} = state) do
    Enum.reduce(
      Transcript.open_calls(state.transcript),
      state,
      &record_result(&1, {:error, "aborted"}, &2)
    )
  end

  def close_partial_message(%State{activity: %Turn{partial: nil}} = state, _stop, _reason),
    do: state

  def close_partial_message(state, stop_reason, reason) do
    emit(state, :message_end, %{
      message: Turn.assistant_message(state.activity, stop_reason: stop_reason),
      error: reason
    })
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
end
