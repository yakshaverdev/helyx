defmodule Helyx.Provider.Codex.State do
  @moduledoc false
  # The program of one provider process of `Helyx.Provider.Codex`.
  # `resume` is the thread id to resume, or nil; `thread` the thread's id,
  # and `fresh?` whether it still waits for its replay. `turn_id` is the
  # Helyx turn, `turn` the program's turn id (`:compact` for a compaction
  # until its `turn/started`), `from` the `{:turn, ...}` or the
  # `{:compact, ...}` without an answer,
  # `interrupt` an interrupt without an answer (`{:pending, from}` before
  # the turn id is known, `{:sent, from, id}` after the `turn/interrupt`
  # with the request id `id`), `due` maps the id of each request without
  # an answer to its method (the turn's end settles a `turn/interrupt`;
  # an answer with an id that is not due is dropped), `next_id` is the
  # id of the next request, `closing` the close without an answer,
  # `prompt` the prompt of a turn whose `turn/start` waits for the
  # `thread/inject_items` answer, and `out` the actions to return, newest
  # first.
  # `terminal` set means the provider process must stop, with that error.
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
  # `tools` holds the state of the Helyx tools (`Tools`).
  @enforce_keys [:model, :cwd]
  defstruct [
    :model,
    :cwd,
    :resume,
    :port,
    :thread,
    :terminal,
    :turn_id,
    :turn,
    :from,
    :interrupt,
    :closing,
    :prompt,
    tools: %Helyx.Provider.Codex.Tools{},
    fresh?: false,
    due: %{},
    next_id: 1,
    out: [],
    buffer: [],
    size: 0,
    items: %Helyx.Provider.Codex.Items{},
    agents: %{},
    asked: %{}
  ]
end
