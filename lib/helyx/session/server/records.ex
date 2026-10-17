defmodule Helyx.Session.Server.Records do
  @moduledoc false
  # The records of a session: the only writer of `transcript`, `file`,
  # `model`, `provider`, `resume_ids`, `summary`, `compacted`, and
  # `unsaved_from` in `Helyx.Session.Server.State`. Each operation changes
  # the open assistant message, the transcript, the session file, and emits
  # its events together. The rule: no message goes between a call and its
  # result. A call still open gets its `aborted` result before the next
  # message joins (docs/features/session-lifecycle.md).

  require Logger

  import Helyx.Session.Server.Events, only: [emit: 3, emit: 4]

  alias Helyx.{Message, ModelRef, Session}
  alias Helyx.Session.{Id, Transcript, Turn}
  alias Helyx.Session.Server.{ProviderConn, State}

  # A user message that Core made at its admission, with its id and origin.
  def append_user(state, %Message{role: :user} = user) do
    append_message(state, user)
    |> emit(:message_start, %{message: user})
    |> emit(:message_end, %{message: user})
  end

  # Adds one stream event to the open assistant message and emits its
  # message_update; the first event opens the message. A text or thinking
  # delta counts its bytes, a tool call the bytes that the stream check
  # measured (`Helyx.Session.Stream`). An event over the bound of
  # `Turn.add_block/3` adds nothing: `{:error, reason, state}`, with the
  # message open.
  def delta(state, {:tool_call, call, bytes}), do: add(state, {:tool_call, call}, bytes)
  def delta(state, {_kind, text} = event), do: add(state, event, byte_size(text))

  defp add(state, event, bytes) do
    %State{activity: turn} = state = start_assistant_message(state)

    case Turn.add_block(turn, event, bytes) do
      {:ok, turn} -> {:ok, emit(%{state | activity: turn}, :message_update, Map.new([event]))}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Closes the open assistant message at its `message_end`
  # (`close_assistant/3`).
  def end_assistant(state, stop_reason, usage) do
    state = close_assistant(state, stop_reason, usage)
    %{state | activity: Turn.close_partial(state.activity)}
  end

  # The first result of a call in the open message closes the message
  # (`docs/features/session-lifecycle.md`, "Message close"). The message has
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

  # The provider took a steer. The open assistant message closes first,
  # as at a `message_end`. Then every call still open gets
  # its `aborted` result: no message goes between a call and its result.
  def take_steer(%State{activity: %Turn{partial: nil}} = state, user),
    do: state |> abort_open_calls() |> append_user(user)

  def take_steer(%State{activity: %Turn{partial: partial}} = state, user) do
    stop = if Enum.any?(partial, &match?(%Message.ToolCall{}, &1)), do: :tool_use, else: :end_turn
    take_steer(end_assistant(state, stop, nil), user)
  end

  # The close at the end of a turn, at `outcome`: `{:done, stop_reason,
  # usage}`, `:aborted`, or `{:error, text}`. At `done` the open message
  # joins, an empty one too. At an abort or a failure an open message with
  # a tool call closes as at the other closes (stop `:tool_use`); one with
  # text only joins with the stop reason `:aborted` or `:error`, and its
  # message_end has the error text or `:aborted` in `error`. No open
  # message, no message; an open message with no block gets its
  # message_end and is not stored. Then each open call gets its `aborted`
  # result.
  def finish(state, outcome), do: state |> close_last(outcome) |> abort_open_calls()

  # A compaction turn has no message of its own: after its compaction, or
  # after the session's notice that the provider has nothing to compact.
  defp close_last(%State{activity: %Turn{compact: compact, partial: nil}} = state, {:done, _, _})
       when compact != nil,
       do: state

  defp close_last(state, {:done, stop_reason, usage}),
    do: close_assistant(state, stop_reason, usage)

  defp close_last(state, :aborted), do: close_cut(state, :aborted, :aborted)
  defp close_last(state, {:error, text}), do: close_cut(state, :error, text)

  defp close_cut(state, stop, reason) do
    case close_if(state, &match?(%Message.ToolCall{}, &1)) do
      %State{activity: %Turn{partial: nil}} = state ->
        state

      # Opened by an event over the bound, with no block: it ends for the
      # clients and is not stored.
      %State{activity: %Turn{partial: []} = turn} = state ->
        message = Turn.assistant_message(turn, stop_reason: stop)
        emit(state, :message_end, %{message: message, error: reason})

      state ->
        close_assistant(state, stop, nil, %{error: reason})
    end
  end

  # A model switch: the record on disk and `model_change`. It has no turn.
  def set_model(%State{} = state, %ModelRef{} = ref, provider) do
    model = ModelRef.to_string(ref)
    state = persist(state, &Helyx.Session.File.append_model_change(&1, model))
    emit(%{state | model: ref, provider: provider}, nil, :model_change, %{model: model})
  end

  # A resume id of the provider process, with the number of assistant
  # messages now; its event has the turn id that the provider process
  # sent. The provider id is the prefix of the process's model ref:
  # `find/2` matched it, so the session runs no plugin code for it. Only the
  # first resume id after the start of the provider process can say that it
  # lost the resume id of its start, so this clears it.
  def resume_id(%State{conn: %ProviderConn{} = conn} = state, turn_id, id, cut) do
    provider = conn.model.provider
    state = persist(state, &Helyx.Session.File.append_resume_id(&1, provider, id))

    ids =
      Map.put(state.resume_ids, provider, {id, Transcript.assistant_count(state.transcript), nil})

    data = %{provider: provider, resume_id: id, lost: conn.resumed != nil, cut: cut}
    state = %{state | resume_ids: ids, conn: %{conn | resumed: nil}}
    emit(state, turn_id, :resume_id, data)
  end

  # A compaction of the provider's own history: the record on disk and
  # `:compaction`. One in a compaction turn is the one it asked for
  # (`manual`), and marks the turn as compacted; any other is `auto`. The
  # label of the provider's resume id gets the assistant count of this
  # compaction (`Transcript.resumable/3`).
  def compaction(%State{activity: %Turn{compact: compact} = turn} = state, before, after_) do
    trigger = if compact, do: :manual, else: :auto
    provider = turn.model.provider
    append = &Helyx.Session.File.append_compaction(&1, provider, trigger, before, after_, &2)
    state = persist_compaction(state, append, after_)
    count = Transcript.assistant_count(state.transcript)
    state = %{state | resume_ids: Transcript.compacted(state.resume_ids, provider, count)}
    state = if compact, do: put_in(state.activity.compact, :reported), else: state
    emit(state, :compaction, %{trigger: trigger, tokens_before: before, tokens_after: after_})
  end

  # A Helyx summary (docs/features/summary-compaction.md): the record on
  # disk, the stored summary, and `:compaction`. A failed write leaves it
  # in memory only (`persist/2`). One in a compaction turn marks the turn
  # as compacted; an overflow summary is `auto`.
  def summary(%State{activity: %Turn{compact: compact}} = state, summary) do
    state = persist_compaction(state, &Helyx.Session.File.append_summary(&1, summary, &2), nil)
    state = if compact, do: put_in(state.activity.compact, :reported), else: state
    trigger = if compact, do: :manual, else: :auto
    data = %{trigger: trigger, tokens_before: summary.tokens_before, tokens_after: nil}
    emit(%{state | summary: summary}, :compaction, data)
  end

  # The record on disk of a compaction or a summary with the id of the last
  # message, and the anchor of the estimate (`Helyx.Session.Totals.of/2`).
  # With no message there is no anchor: the compaction changes no estimate.
  defp persist_compaction(state, append, tokens_after) do
    last_id = with %Message{id: id} <- List.last(state.transcript), do: id
    state = persist(state, &append.(&1, last_id))
    %{state | compacted: last_id && {last_id, tokens_after}}
  end

  # Emits message_start for the assistant message on the first stream event.
  # The message gets its id here, so its message_start carries it.
  defp start_assistant_message(%State{activity: %Turn{partial: nil} = turn} = state) do
    state = %{state | activity: %{turn | partial: [], message_id: Id.new()}}
    emit(state, :message_start, %{message: Turn.assistant_message(state.activity, [])})
  end

  defp start_assistant_message(state), do: state

  # Appends the assistant message of the stream so far and emits its
  # message_end. No message goes between a
  # call and its result: the calls still open get their aborted results
  # first, and a later result is dropped.
  defp close_assistant(state, stop_reason, usage, data \\ %{}) do
    state = state |> abort_open_calls() |> start_assistant_message()
    assistant = Turn.assistant_message(state.activity, stop_reason: stop_reason, usage: usage)
    data = Map.put(data, :message, assistant)
    emit(append_message(state, assistant), :message_end, data)
  end

  defp close_if(%State{activity: %Turn{partial: [_ | _] = partial}} = state, block?) do
    if Enum.any?(partial, block?), do: end_assistant(state, :tool_use, nil), else: state
  end

  defp close_if(state, _block?), do: state

  # Appends the tool result message to the transcript and emits
  # tool_execution_end.
  defp record_result(call, result, state) do
    message = %{Message.tool_result(call, result) | id: Id.new()}
    emit(append_message(state, message), :tool_execution_end, %{message: message})
  end

  # Each open call (`Transcript.open_calls/1`) gets an `aborted` error
  # result: no message goes between a call and its result, and the next
  # provider call sees a complete pair.
  defp abort_open_calls(%State{} = state) do
    Enum.reduce(
      Transcript.open_calls(state.transcript),
      state,
      &record_result(&1, Session.aborted_result(), &2)
    )
  end

  # Appends a completed message to the transcript and, when the session has
  # a file, to disk. A streamed partial message comes here only when it closes.
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
    # session.
    error in File.Error ->
      stop_saving(state, "the session file could not be written", Exception.message(error))
  end

  # Persistence goes off for the rest of the session: after a disk failure,
  # and after the loss of the writer lock, when another process can append
  # to the file. The turn goes on in memory. One notice with a fixed text
  # tells the clients, the snapshot says `persisting: false`, and the log
  # has the detail. Persistence that is off already gets no second notice.
  def stop_saving(%State{file: nil} = state, _cause, _detail), do: state

  def stop_saving(state, cause, detail) do
    Logger.warning("#{cause}, persistence off: #{detail}")
    text = cause <> "; the rest of this session is not saved"
    state = %{state | file: nil, unsaved_from: length(state.transcript)}
    emit(state, turn_id(state.activity), :notice, %{text: text})
  end

  # The messages that joined the transcript in the turn, each with whether
  # the file holds it, for the sync of the Memory plugin. A session with no
  # file and no `unsaved_from` never had a file, so the file holds none.
  def turn_entries(%State{activity: %Turn{start: start}} = state) do
    unsaved = state.unsaved_from || if(state.file, do: nil, else: 0)

    state.transcript
    |> Enum.drop(start)
    |> Enum.with_index(start)
    |> Enum.map(fn {message, i} ->
      %{message: message, persisted: unsaved == nil or i < unsaved}
    end)
  end

  defp turn_id(%Turn{id: id}), do: id
  defp turn_id(_idle_or_wait), do: nil
end
