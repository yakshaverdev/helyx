defmodule Helyx.Provider.ClaudeCode.State do
  @moduledoc false
  # The provider state of one program; the turn phases and the idle close
  # are in docs/features/long-lived-harness.md, "Claude Code".
  # `resume` is the harness session it resumed, or nil for a fresh one with
  # the id `session_id`. `commands?` is true for the program of a compaction,
  # which runs with the program's commands (`Program.start/2`).
  # `notified?` is true from a `task_notification` line until the next
  # `init` or `:busy` answer: a program turn can follow it (#240).
  @enforce_keys [:exe, :model, :cwd]
  defstruct [
    :exe,
    :model,
    :cwd,
    :resume,
    :session_id,
    :system,
    turn: %Helyx.Provider.ClaudeCode.Turn{},
    tools: [],
    calls: %{},
    tasks: [],
    meter: %Helyx.Provider.ClaudeCode.Meter{},
    init?: false,
    commands?: false,
    sent?: false,
    notified?: false,
    persist?: true,
    stream: %Helyx.HarnessIO.Stream{}
  ]
end
