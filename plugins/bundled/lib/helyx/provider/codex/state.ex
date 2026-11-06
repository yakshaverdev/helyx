defmodule Helyx.Provider.Codex.State do
  @moduledoc false
  # The program of one provider process of `Helyx.Provider.Codex`.
  # `resume` is the thread id to resume, or nil; `thread` the thread's id,
  # nil until the first request opens it, `system` the prompt it was
  # opened with, and `fresh?` whether it still waits for its replay. `turn_id` is the
  # Helyx turn, `turn` the program's turn id (`:compact` for a compaction
  # until its `turn/started`), `from` the `{:turn, ...}` or the
  # `{:compact, ...}` without an answer,
  # `interrupt` an interrupt without an answer (`{:pending, from}` before
  # the turn id is known, `{:sent, from, id}` after the `turn/interrupt`
  # with the request id `id`), `due` maps the id of each request without
  # an answer to its method (the turn's end settles a `turn/interrupt`;
  # an answer with an id that is not due is dropped), `next_id` is the
  # id of the next request,
  # `prompt` the prompt of a turn whose `turn/start` waits for the
  # `thread/inject_items` answer or the thread, `history` the rest of its
  # transcript for the replay of a fresh thread, and `out` the actions to
  # return, newest first.
  # A `terminal` in `stream` means the provider process must stop, with
  # that error.
  # `persist?` is false with the option `persist: false`: the thread is
  # ephemeral and never resumed (docs/features/harness-no-state.md). `env`
  # in `stream` is the option `env` as name and value pairs
  # (`Helyx.HarnessIO.env/1`); `inspect` leaves it out. `trust` holds the
  # `sandbox`, `approvalPolicy`, and `approvalsReviewer` of the thread
  # (`Program.options/1`).
  #
  # `agents` maps each child thread with open work to the program's turn
  # id of its last `subAgentActivity` item. It belongs to the program and
  # stays between turns.
  #
  # Of the running turn: `items` the state of its items (`Items`).
  # `asked` maps the request id of each `turn/steer` with no answer yet to
  # its `from`; it outlives the turn, because the answer can come after
  # `turn/completed`.
  #
  # `tools` holds the state of the Helyx tools (`Tools`). `stream` holds
  # what the provider shares with `Helyx.HarnessIO`: the port, the read
  # buffer, the terminal, the close, the held handles, and the env
  # (`Helyx.HarnessIO.Stream`).
  @enforce_keys [:exe, :model, :cwd]
  defstruct [
    :exe,
    :model,
    :cwd,
    :resume,
    :thread,
    :system,
    :turn_id,
    :turn,
    :from,
    :interrupt,
    :prompt,
    :history,
    :trust,
    tools: %Helyx.Provider.Codex.Tools{},
    fresh?: false,
    persist?: true,
    due: %{},
    next_id: 1,
    out: [],
    items: %Helyx.Provider.Codex.Items{},
    agents: %{},
    asked: %{},
    stream: %Helyx.HarnessIO.Stream{}
  ]
end
