defmodule Helyx.Session.Server.Records do
  @moduledoc false
  # The records of a session: the only writer of `transcript`, `save`, `model`,
  # `provider`, `resume_ids`, `summary`, and `compacted` in
  # `Helyx.Session.Server.State`. Each operation changes the open assistant
  # message, the transcript, and the session file, and emits its events
  # together. The rule: no message goes between a call and its result
  # (docs/features/session-lifecycle.md).

  require Logger

  import Helyx.Session.Server.Events, only: [emit: 3, emit: 4]

  alias Helyx.{Message, ModelRef, Session}
  alias Helyx.Session.{HookEntry, Id, Transcript, Turn}
  alias Helyx.Session.Server.{Approvals, Asks, Settle, State, UIBlocks}

  def append_user(state, %Message{role: :user} = user) do
    append_message(state, user)
    |> emit(:message_start, %{message: user})
    |> emit(:message_end, %{message: user})
  end

  # Adds one stream event to the open assistant message and emits its
  # message_update; the first event opens the message. An event over the
  # bound of `Turn.add_block/3` adds nothing: `{:error, reason, state}`, with
  # the message open.
  def delta(state, {:tool_call, call, bytes}), do: add(state, {:tool_call, call}, bytes)
  def delta(state, {_kind, text} = event), do: add(state, event, byte_size(text))

  defp add(state, event, bytes) do
    state = start_assistant_message(state)
    turn = state.phase.turn

    case Turn.add_block(turn, event, bytes) do
      {:ok, turn} ->
        {:ok,
         emit(%{state | phase: %{state.phase | turn: turn}}, :message_update, Map.new([event]))}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # Closes the open assistant message at its `message_end`
  # (`close_assistant/3`).
  def end_assistant(state, stop_reason, usage) do
    state = close_assistant(state, stop_reason, usage)
    %{state | phase: %{state.phase | turn: Turn.close_partial(state.phase.turn)}}
  end

  # The first result of a call in the open message closes the message
  # (docs/features/session-lifecycle.md, "Message close"). A result goes to
  # the first open call with its id, so the transcript, the file, and the
  # replay agree; one for no open call is dropped.
  def tool_result(state, call_id, result) do
    state = close_if(state, &match?(%Message.ToolCall{id: ^call_id}, &1))

    case Enum.find(Transcript.open_calls(state.transcript), &(&1.id == call_id)) do
      nil -> state
      call -> record_result(call, result, state, UIBlocks.result_blocks(state, call_id))
    end
  end

  # The provider took a steer. The open assistant message closes first, as at
  # a `message_end`, and each call still open gets its `aborted` result.
  def take_steer(%State{phase: %{turn: %Turn{partial: nil}}} = state, user),
    do: state |> abort_open_calls() |> append_user(user)

  def take_steer(%State{phase: %{turn: %Turn{partial: partial}}} = state, user) do
    stop = if Enum.any?(partial, &match?(%Message.ToolCall{}, &1)), do: :tool_use, else: :end_turn
    take_steer(end_assistant(state, stop, nil), user)
  end

  # The close at the end of a turn, at `outcome`: `{:done, stop_reason,
  # usage}`, `:aborted`, or `{:error, text}`. Each open call gets its
  # `aborted` result afterwards. An open message with no block gets its
  # message_end and is not stored.
  def finish(state, outcome), do: state |> close_last(outcome) |> abort_open_calls()

  # A compaction turn has no message of its own: after its compaction, or
  # after the session's notice that the provider has nothing to compact.
  defp close_last(
         %State{phase: %{turn: %Turn{compact: compact, partial: nil}}} = state,
         {:done, _, _}
       )
       when compact != nil,
       do: state

  defp close_last(state, {:done, stop_reason, usage}),
    do: close_assistant(state, stop_reason, usage)

  defp close_last(state, :aborted), do: close_cut(state, :aborted, :aborted)
  defp close_last(state, {:error, text}), do: close_cut(state, :error, text)

  defp close_cut(state, stop, reason) do
    case close_if(state, &match?(%Message.ToolCall{}, &1)) do
      %State{phase: %{turn: %Turn{partial: nil}}} = state ->
        state

      # Opened by an event over the bound, with no block: it ends for the
      # clients and is not stored.
      %State{phase: %{turn: %Turn{partial: []} = turn}} = state ->
        message = Turn.assistant_message(turn, stop_reason: stop)
        emit(state, :message_end, %{message: message, error: reason})

      state ->
        close_assistant(state, stop, nil, %{error: reason})
    end
  end

  # A model switch records on disk and emits `model_change`. It has no turn.
  def set_model(%State{} = state, %ModelRef{} = ref, provider) do
    model = ModelRef.to_string(ref)
    state = persist(state, &Helyx.Session.File.append_model_change(&1, model))
    emit(%{state | model: ref, provider: provider}, nil, :model_change, %{model: model})
  end

  # A change of the activated tool names, with the turn of the call that
  # activated, or nil for the cap after a put (docs/features/mcp-client.md).
  def tools_change(%State{} = state, turn_id, activated) do
    state = persist(state, &Helyx.Session.File.append_tools_change(&1, activated))
    emit(state, turn_id, :tools_change, %{activated: activated})
  end

  # A resume id of the provider process, with the number of assistant
  # messages now. The provider id is the prefix of the process's model ref,
  # so the session runs no plugin code for it. Only the first resume id
  # after the start of the process can say that it lost the id of its start,
  # so this clears it.
  def resume_id(
        %State{phase: %{provider: %{model: model, resumed: resumed}} = phase} = state,
        turn_id,
        id,
        cut
      ) do
    provider = model.provider
    state = persist(state, &Helyx.Session.File.append_resume_id(&1, provider, id))

    ids =
      Map.put(state.resume_ids, provider, {id, Transcript.assistant_count(state.transcript), nil})

    data = %{provider: provider, resume_id: id, lost: resumed != nil, cut: cut}

    state = %{
      state
      | resume_ids: ids,
        phase: %{phase | provider: %{phase.provider | resumed: nil}}
    }

    emit(state, turn_id, :resume_id, data)
  end

  # A compaction of the provider's own history. One in a compaction turn is
  # the one it asked for (`manual`) and marks the turn as compacted; any
  # other is `auto`. The label of the provider's resume id gets the
  # assistant count of this compaction (`Transcript.resumable/3`).
  def compaction(%State{phase: %{turn: %Turn{compact: compact} = turn}} = state, before, after_) do
    trigger = if compact, do: :manual, else: :auto
    provider = turn.model.provider
    append = &Helyx.Session.File.append_compaction(&1, provider, trigger, before, after_, &2)
    state = persist_compaction(state, append, after_)
    count = Transcript.assistant_count(state.transcript)
    state = %{state | resume_ids: Transcript.compacted(state.resume_ids, provider, count)}
    state = if compact, do: put_in(state.phase.turn.compact, :reported), else: state
    emit(state, :compaction, %{trigger: trigger, tokens_before: before, tokens_after: after_})
  end

  # A Helyx summary (docs/features/summary-compaction.md): the record on
  # disk, the stored summary, and `:compaction`. A failed write leaves it in
  # memory only. One in a compaction turn marks the turn as compacted.
  def summary(%State{phase: %{turn: %Turn{compact: compact}}} = state, summary) do
    state = persist_compaction(state, &Helyx.Session.File.append_summary(&1, summary, &2), nil)
    state = if compact, do: put_in(state.phase.turn.compact, :reported), else: state
    trigger = if compact, do: :manual, else: :auto
    data = %{trigger: trigger, tokens_before: summary.tokens_before, tokens_after: nil}
    emit(%{state | summary: summary}, :compaction, data)
  end

  # The system prompt of the provider call that the session sends now: an
  # entry when it is not the last one that the file holds
  # (docs/features/turn-record.md).
  def system_prompt(state, system),
    do: persist(state, &Helyx.Session.File.append_system_prompt(&1, system))

  # The record on disk of a compaction or a summary with the id of the last
  # message, and the anchor of the estimate (`Helyx.Session.Totals.of/2`).
  # With no message there is no anchor: the compaction changes no estimate.
  defp persist_compaction(state, append, tokens_after) do
    last_id = with %Message{id: id} <- List.last(state.transcript), do: id
    state = persist(state, &append.(&1, last_id))
    %{state | compacted: last_id && {last_id, tokens_after}}
  end

  # An answer of a hook (docs/features/hooks.md): a `hook` entry of the file,
  # whatever the turn, and a notice for a failed `after_tool` hook of the
  # current turn, and for a failed `before_settle` hook of the current chain,
  # with no turn id: its turn ended. `Helyx.Session.HookEntry` owns the shape
  # of the entry, so it goes through the plain append of the file.
  def hook(state, turn_id, record) do
    entry = HookEntry.entry(turn_id, record)
    state = persist(state, &Helyx.Session.File.append(&1, entry))

    case {entry, state.phase} do
      {%{"point" => "after_tool", "answer" => "failed", "reason" => reason},
       %{turn: %Turn{id: ^turn_id}}} ->
        text =
          "the hook #{inspect(record.hook)} failed after the call #{record.call_id}: #{reason}"

        emit(state, :notice, %{text: text})

      {%{"point" => "before_settle", "answer" => "failed", "reason" => reason}, _phase} ->
        if Settle.current?(state, turn_id) do
          text = "the hook #{inspect(record.hook)} failed before the session settled: #{reason}"
          emit(state, nil, :notice, %{text: text})
        else
          state
        end

      _recorded ->
        state
    end
  end

  # The message gets its id here, so its message_start carries it.
  defp start_assistant_message(%State{phase: %{turn: %Turn{partial: nil} = turn} = phase} = state) do
    state = %{state | phase: %{phase | turn: %{turn | partial: [], message_id: Id.new()}}}
    emit(state, :message_start, %{message: Turn.assistant_message(state.phase.turn, [])})
  end

  defp start_assistant_message(state), do: state

  # The calls still open get their aborted results before the message joins,
  # and a later result is dropped.
  defp close_assistant(state, stop_reason, usage, data \\ %{}) do
    state = state |> abort_open_calls() |> start_assistant_message()
    assistant = Turn.assistant_message(state.phase.turn, stop_reason: stop_reason, usage: usage)
    data = Map.put(data, :message, assistant)
    emit(append_message(state, assistant), :message_end, data)
  end

  defp close_if(%State{phase: %{turn: %Turn{partial: [_ | _] = partial}}} = state, block?) do
    if Enum.any?(partial, block?), do: end_assistant(state, :tool_use, nil), else: state
  end

  defp close_if(state, _block?), do: state

  # No block or ask of the call comes after its result: the UI blocks leave
  # the turn (`UIBlocks.call_end/2`), the records of its Tasks end with their
  # asks (`Asks.result_joined/2`), and its owner can go
  # (`Approvals.drop/2`).
  defp record_result(call, result, state, blocks \\ []) do
    message = %{Message.tool_result(call, result) | id: Id.new(), ui_blocks: blocks}

    state
    |> UIBlocks.call_end(call.id)
    |> Asks.result_joined(call.id)
    |> append_message(message)
    |> Approvals.drop(call.id)
    |> emit(:tool_execution_end, %{message: message})
  end

  # Each open call gets an `aborted` error result, so the next provider call
  # sees a complete pair.
  defp abort_open_calls(%State{} = state) do
    Enum.reduce(
      Transcript.open_calls(state.transcript),
      state,
      &record_result(&1, Session.aborted_result(), &2)
    )
  end

  # A streamed partial message comes here only when it closes.
  defp append_message(%State{} = state, %Message{} = message) do
    state = persist(state, &Helyx.Session.File.append_message(&1, message))
    %{state | transcript: state.transcript ++ [message]}
  end

  defp persist(%State{save: {:saving, file, lock}} = state, append) do
    %{state | save: {:saving, append.(file), lock}}
  rescue
    # A disk failure must not take the session down: the turn goes on in
    # memory, and persistence stays off. Only the disk write is caught, so an
    # encode error here is a bug and crashes loudly.
    error in File.Error ->
      stop_saving(state, "the session file could not be written", Exception.message(error))
  end

  defp persist(state, _append), do: state

  # Persistence goes off for the rest of the session: after a disk failure,
  # and after the loss of the writer lock. One notice tells the clients, the
  # snapshot says `persisting: false`, and the log has the detail.
  def stop_saving(%State{save: :never} = state, _cause, _detail), do: state
  def stop_saving(%State{save: {:stopped, _from, _lock}} = state, _cause, _detail), do: state

  def stop_saving(%State{save: {:saving, _file, lock}} = state, cause, detail) do
    Logger.warning("#{cause}, persistence off: #{detail}")
    text = cause <> "; the rest of this session is not saved"
    state = %{state | save: {:stopped, length(state.transcript), lock}}
    emit(state, turn_id(state.phase), :notice, %{text: text})
  end

  # The messages that joined the transcript in the turn, each with whether
  # the file holds it, for the sync of the Memory plugin. A session that
  # never had a file holds none; one that stopped saving holds those before
  # `unsaved_from`.
  def turn_entries(%State{phase: %{turn: %Turn{start: start}}} = state) do
    unsaved =
      case state.save do
        {:saving, _file, _lock} -> nil
        {:stopped, from, _lock} -> from
        :never -> 0
      end

    state.transcript
    |> Enum.drop(start)
    |> Enum.with_index(start)
    |> Enum.map(fn {message, i} ->
      %{message: message, persisted: unsaved == nil or i < unsaved}
    end)
  end

  defp turn_id(%{turn: %Turn{id: id}}), do: id
  defp turn_id(_phase), do: nil
end
