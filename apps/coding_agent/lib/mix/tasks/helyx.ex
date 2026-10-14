defmodule Mix.Tasks.Helyx do
  @shortdoc "Starts the coding agent TUI, or print mode with -p"
  @moduledoc """
  Starts the coding agent from the source tree: the TUI in the alternate
  screen, or print mode with `-p`.

      mix helyx [directory] [--model provider/model] [--resume] [--version]
      mix helyx [directory] [--model provider/model] -p prompt
      mix helyx --session id
      mix helyx --list [--all] [directory]

  The options and the errors are those of `CodingAgent.CLI`. Sessions are
  written under `~/.helyx/sessions` as they run. A bad argument or a failed
  start prints one line on stderr and stops Mix with status 1. With `-p`,
  print mode (`CodingAgent.Print`) halts the VM with its status itself.
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
