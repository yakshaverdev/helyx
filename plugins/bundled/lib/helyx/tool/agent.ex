defmodule Helyx.Tool.Agent do
  @moduledoc """
  Runs a task in a child session and gives its final text back: a
  subagent. The child is a normal session of the same Core, with the
  model of the parent's turn, its working folder, its tools but this one,
  and a fresh context. Its header links the parent call, and its id is
  derived from the link (`Helyx.Sessions.child_id/2`); it is out of the
  session list. The result is the text of the child's last assistant
  message; a failed or ended child turn gives an error result.

  Calls run together (`concurrent?/0`). The tool holds the child, and
  `release/3` stops it, so an abort or a stop of the parent ends it; an
  owner process stops it when the call's Task dies with no release. The
  design and the bounds are in `docs/features/agent-tool.md`.
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
      parent: %{session_id: context.session_id, call_id: context.call_id},
      tools: List.delete(context.tools, name())
    ]

    {owner, monitor} = start_owner(context.core, opts)

    receive do
      {^owner, {:ok, child}} ->
        :ok = Helyx.Tool.hold(child)
        result = ask(child, prompt)
        stop(owner, monitor)
        :ok = Helyx.Tool.unhold([child])
        result

      {^owner, {:error, reason}} ->
        {:error, start_error(reason)}

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, start_error(reason)}
    end
  end

  def run(_args, _cwd), do: {:error, "agent needs a description and a prompt, both strings"}

  # Stops each child; a child whose stop is not done at the deadline stays
  # held. A child that ended already gives `:session_not_found`.
  @impl true
  def release(children, _mode, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    stops =
      Task.async_stream(children, &Helyx.Sessions.stop/1,
        max_concurrency: length(children),
        timeout: timeout,
        on_timeout: :kill_task
      )

    for {{:exit, :timeout}, child} <- Enum.zip(stops, children), do: child
  end

  # The owner starts the child, so no kill of the Task between the start
  # and the hold leaves a child that no process stops (ADR 0004). It stops
  # the child when the Task asks or ends, whichever comes first.
  defp start_owner(core, opts) do
    task = self()

    {:ok, owner} =
      Task.Supervisor.start_child(Helyx.Core.task_supervisor(core), fn ->
        ref = Process.monitor(task)
        result = Helyx.Sessions.start(core, opts)
        send(task, {self(), result})

        receive do
          :stop -> :ok
          {:DOWN, ^ref, :process, ^task, _reason} -> :ok
        end

        with {:ok, child} <- result, do: Helyx.Sessions.stop(child)
      end)

    {owner, Process.monitor(owner)}
  end

  # The owner ends after the stop of the child.
  defp stop(owner, monitor) do
    send(owner, :stop)

    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
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
