defmodule Mix.Tasks.Helyx do
  @shortdoc "Starts the coding agent TUI"
  @moduledoc """
  Starts the coding agent in the alternate screen from the source tree.

      mix helyx [directory] [--model provider/model] [--resume] [--version]

  The options and the errors are those of `CodingAgent.CLI`. Sessions are
  written under `~/.helyx/sessions` as they run. A bad argument or a failed
  start prints one line on stderr and stops Mix with status 1.
  """

  use Mix.Task

  @impl true
  def run(argv) do
    # The arguments are checked before the applications start.
    Mix.Task.run("app.config")

    case CodingAgent.CLI.main(argv) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
