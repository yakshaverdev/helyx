defmodule Helyx.Subagent do
  @moduledoc false
  # A child session that one tool call starts, prompts once, and stops: the
  # child of the agent tool (`docs/features/agent-tool.md`), shared with
  # `Helyx.Tool.SessionRead` (`docs/features/coordinator.md`). The tool that
  # calls `run/3` holds the child, and its `release/3` gives the handles to
  # `release/2` here.

  alias Helyx.{Event, Message, Session}

  @doc false
  # Starts the child with the model, provider options and ModelContext of
  # the call `context`, the folder `cwd` and `tools` (`Helyx.Sessions.start/2`), sends `prompt`,
  # and gives the text of its last assistant message. A start that fails
  # gives `{:error, {:start, reason}}`, any other failure `{:error, text}`.
  @spec run(map(), String.t(), [String.t()], String.t()) ::
          {:ok, String.t()} | {:error, String.t() | {:start, term()}}
  def run(context, cwd, tools, prompt) do
    opts = [
      model: context.model,
      cwd: cwd,
      provider_opts: context.provider_opts,
      model_context: context.model_context,
      parent: %{session_id: context.session_id, call_id: context.call_id},
      tools: tools
    ]

    core = context.core
    parent = Session.pid(%Session{id: context.session_id, core: core})
    {owner, monitor} = start_owner(core, opts, parent)

    receive do
      {^owner, {:ok, {child, _pid}}} ->
        handle = {child, owner}
        :ok = Helyx.Tool.hold(handle)
        result = ask(child, prompt)
        # A child whose stop left a handle held stays held (`release/2`).
        if report(owner, monitor) == :ok, do: :ok = Helyx.Tool.unhold([handle])
        result

      {^owner, {:error, reason}} ->
        {:error, {:start, reason}}

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:start, reason}}
    end
  end

  @doc false
  # Asks the owner of each child for the report of its stop. A child whose
  # report is not `:ok`, or that has none at the deadline, stays held.
  @spec release([{Session.t(), pid()}], integer()) :: [{Session.t(), pid()}]
  def release(children, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    reports =
      Task.async_stream(children, fn {_child, owner} -> report(owner, Process.monitor(owner)) end,
        max_concurrency: length(children),
        timeout: timeout,
        on_timeout: :kill_task
      )

    for {report, child} <- Enum.zip(reports, children), report != {:ok, :ok}, do: child
  end

  # The owner starts the child, so no kill of the Task between the start
  # and the hold leaves a child that no process stops (ADR 0004).
  defp start_owner(core, opts, parent) do
    task = self()

    {:ok, owner} =
      Task.Supervisor.start_child(Helyx.Core.task_supervisor(core), fn ->
        watch = {task, Process.monitor(task), Process.monitor(parent)}

        result =
          with {:ok, child} <- Helyx.Sessions.start(core, opts),
               do: {:ok, {child, Session.pid(child)}}

        send(task, {self(), result})
        with {:ok, {_child, pid}} when is_pid(pid) <- result, do: own(pid, watch, nil)
      end)

    {owner, Process.monitor(owner)}
  end

  # The owner stops the child once, at the first ask for the report, at the
  # end of the Task, or at the end of the parent session, and answers each
  # ask with that report. It ends when the Task returned with the report,
  # after the ask of the release of any other end of the Task, or with the
  # parent session. A Task that returns did not always ask: the hands turn
  # a raise, a throw, or an exit of `run/2` into its result.
  # The stop acts on the process that the call started, never on a later
  # instance of its id (docs/features/agent-tool.md, "The cleanup").
  defp own(pid, {task, task_ref, parent_ref} = watch, report) do
    receive do
      {:report, from, ref} ->
        report = report || Helyx.Sessions.stop(pid)
        send(from, {ref, report})
        if from == task, do: own(pid, watch, report)

      {:DOWN, ^task_ref, :process, ^task, :normal} when report != nil ->
        :ok

      {:DOWN, ^task_ref, :process, ^task, _reason} ->
        own(pid, watch, report || Helyx.Sessions.stop(pid))

      {:DOWN, ^parent_ref, :process, _parent, _reason} ->
        report || Helyx.Sessions.stop(pid)
    end
  end

  # The report of the child's stop from its owner, which `monitor` watches.
  # An owner that is gone gave its report to the call, which kept the child
  # held, or it never owned a child.
  defp report(owner, monitor) do
    send(owner, {:report, self(), monitor})

    receive do
      {^monitor, report} ->
        Process.demonitor(monitor, [:flush])
        report

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        :gone
    end
  end

  # The child can end before the subscribe or the prompt reaches it.
  defp ask(child, prompt) do
    with {:ok, _snapshot, ref} <- Session.subscribe(child),
         :ok <- Session.prompt(child, prompt) do
      await(child, ref, nil)
    else
      {:error, :session_not_found} -> {:error, "the session ended"}
      {:error, reason} -> {:error, "the prompt was not sent: #{reason}"}
    end
  end

  # The events of the child's one turn: its last assistant message, or nil,
  # then its end. Each event is acked, so the child keeps the subscription.
  defp await(child, ref, last) do
    receive do
      {:helyx_event, %Event{} = event} ->
        :ok = Session.ack(child, event)

        case event do
          %Event{type: :message_end, data: %{message: %Message{role: :assistant} = message}} ->
            await(child, ref, message)

          %Event{type: :turn_end, data: %{outcome: :done}} ->
            {:ok, if(last, do: Message.text(last), else: "")}

          %Event{type: :turn_end, data: %{outcome: :error, error: error}} ->
            {:error, "the turn failed: " <> error}

          %Event{type: :turn_end, data: %{outcome: :aborted}} ->
            {:error, "the turn was aborted"}

          _event ->
            await(child, ref, last)
        end

      {:helyx_end, ^ref, :slow} ->
        {:error, "its events were not read in time"}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, "the session ended (#{Session.end_reason(reason)})"}
    end
  end
end
