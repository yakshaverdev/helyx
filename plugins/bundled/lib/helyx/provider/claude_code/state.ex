defmodule Helyx.Provider.ClaudeCode.State do
  @moduledoc false
  # The program of one provider process of `Helyx.Provider.ClaudeCode`.
  # `resume` is the harness session it resumed, or nil for a fresh one with
  # the id `session_id`. `system` is the prompt it runs with, nil before
  # the first launch. `commands?` is true for the program of a compaction,
  # which runs with the program's commands (`Program.start/2`). `sent?` is
  # true once a turn was written to it.
  # `init?` is true from its first `init` line. `closing` is the `from` of
  # a close. `terminal` stops the read of stdout: `:lost`, a program that
  # did not start (`Helyx.HarnessIO.launch/4`), an `init` without the
  # needed capabilities, an error answer to `initialize`, or a line over
  # the cap (`Helyx.HarnessIO.lines/3`). `tasks` is the `tasks` value of
  # the last `background_tasks_changed` line: only `[]` lets an idle close
  # stop the program.
  # `notified?` is true from a `task_notification` line until the next
  # `init` or `:busy` answer: a program turn can follow it (#240).
  # `tools` are the Helyx tool specs, and `calls` the open `tools/call`
  # requests of `Mcp`. `meter` is the usage of the program (`Meter`).
  # `handles` are the held handles of the provider's programs
  # (`Helyx.HarnessIO`).
  @enforce_keys [:exe, :model, :cwd]
  defstruct [
    :exe,
    :model,
    :cwd,
    :resume,
    :session_id,
    :system,
    :port,
    :turn,
    :closing,
    :terminal,
    buffer: [],
    tools: [],
    calls: %{},
    tasks: [],
    handles: [],
    meter: %Helyx.Provider.ClaudeCode.Meter{},
    size: 0,
    init?: false,
    commands?: false,
    sent?: false,
    notified?: false
  ]
end
