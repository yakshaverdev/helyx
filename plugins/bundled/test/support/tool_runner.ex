defmodule Helyx.Test.ToolRunner do
  @moduledoc false

  alias Helyx.Provider.Fake

  @doc """
  Runs one tool call through a session and returns the tool result message.
  `cwd` is the session's working directory. Core must run `Fake`.
  """
  @spec run_tool(Helyx.Core.name(), Helyx.Message.ToolCall.t(), String.t()) :: Helyx.Message.t()
  def run_tool(core, %Helyx.Message.ToolCall{} = call, cwd) do
    _session = start_tool(core, call, cwd)

    receive do
      {:helyx_event, %Helyx.Event{type: :tool_execution_end, data: %{message: message}}} ->
        message
    after
      Helyx.Test.Events.wait_ms() -> raise "no tool result for #{inspect(call)}"
    end
  end

  @doc """
  Starts a session, subscribes the caller, and prompts a turn that makes
  `call`. Returns the session after the assistant message that holds the
  call, so the tool call runs or is about to run. Core must run `Fake`.
  """
  @spec start_tool(Helyx.Core.name(), Helyx.Message.ToolCall.t(), String.t()) :: Helyx.Session.t()
  def start_tool(core, %Helyx.Message.ToolCall{} = call, cwd) do
    # A model name for each session, so sessions on one Core get their own script.
    model = "run_tool_#{System.unique_integer([:positive])}"
    :ok = Fake.script(core, model, [[call], ["Done."]])
    {:ok, session} = Helyx.Session.start(core, model: "fake/#{model}", cwd: cwd)
    {:ok, _, _} = Helyx.Session.subscribe(session)
    :ok = Helyx.Session.prompt(session, "go")

    receive do
      {:helyx_event, %Helyx.Event{type: :message_end, data: %{message: %{role: :assistant}}}} ->
        session
    after
      Helyx.Test.Events.wait_ms() -> raise "no assistant message for #{inspect(call)}"
    end
  end

  @doc """
  The hands of `session` and the Task of its one running tool call. The one
  place where the tests read the state of the session and of the hands.
  """
  @spec running_tool(Helyx.Session.t()) :: %{hands: pid(), task: pid()}
  def running_tool(session) do
    hands = :sys.get_state(Helyx.Session.pid(session)).hands

    [task] =
      for {task, _turn_id, id, _module, _place} <- Map.values(:sys.get_state(hands).tasks),
          id != :provider,
          do: task.pid

    %{hands: hands, task: task}
  end
end
