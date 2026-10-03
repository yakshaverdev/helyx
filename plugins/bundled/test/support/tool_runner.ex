defmodule Helyx.Test.ToolRunner do
  @moduledoc false

  alias Helyx.Provider.Fake

  @doc """
  Runs one tool call through a session and returns the tool result message.
  `cwd` is the session's working directory. Core must run `Fake`.
  """
  @spec run_tool(Helyx.Core.name(), Helyx.Message.ToolCall.t(), String.t()) :: Helyx.Message.t()
  def run_tool(core, %Helyx.Message.ToolCall{} = call, cwd) do
    model = "run_tool_#{System.unique_integer([:positive])}"
    :ok = Fake.script(core, model, [[call], ["Done."]])
    {:ok, session} = Helyx.Session.start(core, model: "fake/#{model}", cwd: cwd)
    {:ok, _, _} = Helyx.Session.subscribe(session)
    :ok = Helyx.Session.prompt(session, "go")

    receive do
      {:helyx_event, %Helyx.Event{type: :tool_execution_end, data: %{message: message}}} ->
        message
    after
      Helyx.Test.Events.wait_ms() -> raise "no tool result for #{inspect(call)}"
    end
  end
end
