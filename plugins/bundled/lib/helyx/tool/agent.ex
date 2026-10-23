defmodule Helyx.Tool.Agent do
  @moduledoc """
  Runs a task in a child session and gives its final text back: a
  subagent. The child is a normal session of the same Core, with the
  model of the parent's turn, its working folder, its `:provider_opts`,
  its tools but this one and `question`, and a fresh context. Its header
  links the parent call, and its id is derived from the link
  (`Helyx.Sessions.child_id/2`); it is out of the session list. The
  result is the text of the child's last assistant message; a failed or
  ended child turn gives an error result.

  Calls run together (`concurrent?/0`). The tool holds the child. An owner
  process stops it once with `Helyx.Sessions.stop/1`: at the end of the
  call, at the end of the call's Task, as an abort or a stop of the parent
  does, or at the end of the parent session. `release/3` takes that stop
  report, and a child whose report is not `:ok` stays held, so a stop of
  the parent reports it. The design and the bounds are in
  `docs/features/agent-tool.md`.
  """

  @behaviour Helyx.Tool

  alias Helyx.{Event, Message, Session}

  @impl true
  def name, do: "agent"

  @impl true
  def concurrent?, do: true

  @impl true
  def description do
    "Give a task to a subagent: a new agent with your tools but this one, your model, " <>
      "your working folder, and no history of this conversation. It returns the subagent's " <>
      "final answer. The prompt must hold the whole task and the context it needs. " <>
      "Calls in one response run at the same time."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "description" => %{"type" => "string", "description" => "A short label of the task"},
        "prompt" => %{"type" => "string", "description" => "The whole task for the subagent"}
      },
      "required" => ["description", "prompt"]
    }
  end

  @impl true
  def run(%{"description" => description, "prompt" => prompt}, cwd)
      when is_binary(description) and is_binary(prompt) do
    context = Helyx.Tool.context()

    opts = [
      model: context.model,
      cwd: cwd,
      provider_opts: context.provider_opts,
      parent: %{session_id: context.session_id, call_id: context.call_id},
      # No user watches a child, so it gets no question tool either.
      tools: context.tools -- [name(), "question"]
    ]

    parent = Session.pid(%Session{id: context.session_id, core: context.core})
    {owner, monitor} = start_owner(context.core, opts, parent)

    receive do
      {^owner, {:ok, {child, _pid}}} ->
        handle = {child, owner}
        :ok = Helyx.Tool.hold(handle)
        result = ask(child, prompt)
        # A child whose stop left a handle held stays held (`release/3`).
        if report(owner, monitor) == :ok, do: :ok = Helyx.Tool.unhold([handle])
        result

      {^owner, {:error, reason}} ->
        {:error, start_error(reason)}

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, start_error(reason)}
    end
  end

  def run(_args, _cwd), do: {:error, "agent needs a description and a prompt, both strings"}

  # Asks the owner of each child for the report of its stop. A child whose
  # report is not `:ok`, or that has none at the deadline, stays held.
  @impl true
  def release(children, _mode, deadline) do
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

  defp start_error(:too_many_sessions),
    do:
      "agent: the server runs as many sessions as it can; do this task yourself, " <>
        "without the agent tool"

  defp start_error(reason), do: "agent: the session did not start: " <> Helyx.Reason.text(reason)
end
