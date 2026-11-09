defmodule Helyx.Tool.Agent do
  @moduledoc """
  Runs a task in a child session and gives its final text back: a
  subagent. The child is a normal session of the same Core, with the
  model of the parent's turn, its working folder, its `:provider_opts`,
  its ModelContext plugin, its tools but this one, `question`, and `tool_search`, and a
  fresh context. Its header links the parent call, and its id is derived
  from the link (`Helyx.Sessions.child_id/2`); it is out of the session
  list. The result is the text of the child's last assistant message; a
  failed or ended child turn gives an error result.

  Calls run together (`concurrent?/0`). The tool holds the child. An owner
  process stops it once with `Helyx.Sessions.stop/1`: at the end of the
  call, at the end of the call's Task, as an abort or a stop of the parent
  does, or at the end of the parent session. `release/3` takes that stop
  report, and a child whose report is not `:ok` stays held, so a stop of
  the parent reports it. The design and the bounds are in
  `docs/features/agent-tool.md`.
  """

  @behaviour Helyx.Tool

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
      model_context: context.model_context,
      parent: %{session_id: context.session_id, call_id: context.call_id},
      # No user watches a child, so it gets no question tool either; it
      # opens no tool source, so `tool_search` would find nothing.
      tools: context.tools -- [name(), "question", "tool_search"]
    ]

    case Helyx.Subagent.run(context.core, context.session_id, opts, prompt) do
      {:error, {:start, reason}} -> {:error, start_error(reason)}
      result -> result
    end
  end

  def run(_args, _cwd), do: {:error, "agent needs a description and a prompt, both strings"}

  # The child stays held while its owner reports no stop (`Helyx.Subagent`).
  @impl true
  def release(children, _mode, deadline), do: Helyx.Subagent.release(children, deadline)

  defp start_error(:too_many_sessions),
    do:
      "agent: the server runs as many sessions as it can; do this task yourself, " <>
        "without the agent tool"

  defp start_error(reason), do: "agent: the session did not start: " <> Helyx.Reason.text(reason)
end
