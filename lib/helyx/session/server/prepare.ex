defmodule Helyx.Session.Server.Prepare do
  @moduledoc false
  # The context build of a turn (docs/features/session-lifecycle.md and
  # docs/features/summary-compaction.md): the prepare Task, which runs the
  # ModelContext and the Compaction plugin, and what its result starts:
  # the submit of the turn, the answer to a context request, a summary
  # call (`Helyx.Session.Server.Summary`), or the end of a compaction turn.
  # `Helyx.Session.Server.TurnLoop` matches the messages and owns the turn.

  import Helyx.Session.Server.State, only: [ask: 4]

  import Helyx.Session.Server.Events, only: [emit: 3]

  alias Helyx.Context
  alias Helyx.Session.Recall
  alias Helyx.Session.Server.{Compaction, Records, State, Summary, TurnLoop, Wait}
  alias Helyx.Session.Server.Flow.{Live, Preparing}
  alias Helyx.Session.Turn

  @recall_failed "memory recall failed; the turn goes on without recall"

  # The prepare Task builds the context, at the turn start, at each
  # context request, after a summary (`trigger` nil), and in a compaction
  # turn that the provider did not run (`:manual`). The session owns it: a
  # child of the task supervisor, monitored before it runs, so a raise is
  # never `:noproc` (#562), its ref and pid in `Turn.prepare` with the
  # messages it got, killed at the turn end. Its kill at
  # `deadline_ms.prepare` is armed before any plugin code. A compaction
  # turn has no context at its start: it submits at once. Only a model
  # provider gets a summary (`summary-compaction.md`).
  def start(%State{phase: %Preparing{turn: %Turn{compact: text}}} = state, _trigger)
      when is_binary(text),
      do: TurnLoop.submit(state)

  def start(%State{phase: %{turn: %Turn{id: turn_id} = turn}} = state, trigger) do
    %State{plugins: plugins, deadline_ms: %{prepare: ms}} = state

    context = %Context{messages: state.transcript, tools: state.tool_specs}
    trigger = if Helyx.Provider.Loop.loop?(turn.provider), do: trigger

    opts =
      [turn_id: turn_id, model: turn.model, summary: state.summary, trigger: trigger] ++
        [session_dir: if(state.file, do: Path.dirname(state.file.path))] ++
        [instructions: if(is_binary(turn.compact), do: turn.compact, else: "")] ++
        State.base_opts(state)

    # A compaction turn sends no context, so it gets no recall.
    memory = if turn.compact == nil, do: plugins.memory
    recall_ms = Helyx.Core.recall_ms(state.core)
    recall_opts = [turn_id: turn_id, instance_id: state.instance_id, recall_ms: recall_ms]
    recall_opts = recall_opts ++ State.base_opts(state)

    prepare = fn ->
      # The plugins get `:deadline`. It is read before the kill is armed, and
      # the clock rounds down, so the kill comes at or after it.
      deadline = System.monotonic_time(:millisecond) + ms
      {:ok, tref} = :timer.kill_after(ms)
      opts = [{:deadline, deadline} | opts]

      result =
        Helyx.Session.Stream.prepare(plugins.model_context, plugins.compaction, context, opts)

      # Recall comes after the build and the compaction, with what is
      # left of the budget (docs/features/memory.md).
      result =
        with {:ok, built} <- result,
             left = deadline - System.monotonic_time(:millisecond),
             {:ok, recall} <- Recall.run(memory, context.messages, recall_opts, left),
             do: {:ok, built, recall}

      :timer.cancel(tref)
      {:prepared, base(result, context.messages)}
    end

    sup = Helyx.Core.task_supervisor(state.core)

    %Task{pid: pid, ref: ref} =
      Task.Supervisor.async_nolink(sup, Helyx.Reason, :task, ["prepare task crashed", prepare])

    put_in(state.phase.turn.prepare, {ref, pid, context.messages})
  end

  # Messages that the plugins kept go back as `:base`: the session has
  # them (`session-lifecycle.md`). A kept list is the same term, so its
  # match compares two pointers.
  defp base({:ok, %Context{messages: messages} = built, recall}, messages),
    do: {:ok, %{built | messages: :base}, recall}

  defp base(result, _messages), do: result

  # The checked context (`Stream.prepare/4`), or the error of the prepare
  # Task: a plugin that returned anything else, or a Task that died. A
  # plan starts the summary call. In `Preparing` an error fails the turn; a
  # context request gets it as the answer. A compaction turn ends with the
  # notice when the plugin made no summary.
  def prepared(
        %State{phase: %{turn: %Turn{prepare: {_ref, _pid, messages}}}} = state,
        {:ok, %Context{messages: :base} = context, recall}
      ),
      do: prepared(state, {:ok, %{context | messages: messages}, recall})

  def prepared(%State{phase: %{turn: %Turn{} = turn} = phase} = state, {:summarize, plan}),
    do: Summary.start(%{state | phase: %{phase | turn: %{turn | prepare: nil}}}, plan)

  def prepared(%State{phase: %{turn: %Turn{compact: text} = turn} = phase} = state, result)
      when is_binary(text) do
    state = %{state | phase: %{phase | turn: %{turn | prepare: nil}}}

    case result do
      {:ok, _context, _recall} -> TurnLoop.progress(Compaction.unsupported(state))
      {:error, reason} -> TurnLoop.fail_turn(reason, state)
    end
  end

  # The recall message waits in the turn and goes last at the submit,
  # after the steers that join there.
  def prepared(%State{phase: %Preparing{turn: %Turn{} = turn} = phase} = state, result) do
    state = %{state | phase: %{phase | turn: %{turn | prepare: nil}}}

    case result do
      {:ok, context, recall} ->
        state = Records.system_prompt(state, context.system)
        {recall, state} = recall_notice(state, recall)

        TurnLoop.submit(%{
          state
          | phase: %{state.phase | turn: %{state.phase.turn | context: context, recall: recall}}
        })

      {:error, reason} ->
        TurnLoop.fail_turn(reason, state)
    end
  end

  def prepared(
        %State{phase: %Live{turn: %Turn{} = turn, provider: %{pid: pid}} = phase} = state,
        result
      ) do
    {result, state} =
      case result do
        {:ok, context, recall} ->
          state = Records.system_prompt(state, context.system)
          {recall, state} = recall_notice(state, recall)
          {{:ok, %{context | messages: context.messages ++ List.wrap(recall)}}, state}

        error ->
          {error, state}
      end

    # The context request stays open until the provider's reply (C3).
    from = ask(state, pid, {:context, turn.id, result}, :reply)
    turn = %{turn | prepare: nil}
    %{state | phase: %Live{turn: turn, provider: phase.provider, pending: from}}
  end

  # A failed recall is no recall, with one notice in the turn.
  defp recall_notice(%State{phase: %{turn: %Turn{recall_failed: false}}} = state, :failed),
    do:
      {nil, put_in(emit(state, :notice, %{text: @recall_failed}).phase.turn.recall_failed, true)}

  defp recall_notice(state, :failed), do: {nil, state}
  defp recall_notice(state, recall), do: {recall, state}

  # After a summary: a compaction turn ends; any other builds again.
  def summarized(%State{phase: %{turn: %Turn{compact: :reported}}} = state),
    do: TurnLoop.progress(Wait.finish(state, {:done, :end_turn, %{}}))

  def summarized(state), do: start(state, nil)

  # The reason of a prepare Task that ended before its context.
  def down_reason(:killed), do: :context_timeout
  def down_reason(reason), do: {:task_exit, reason}
end
