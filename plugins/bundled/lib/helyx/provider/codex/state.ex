defmodule Helyx.Provider.Codex.State do
  @moduledoc false
  # The program of one provider process of `Helyx.Provider.Codex`.
  # `resume` is the thread id to resume, or nil; `thread` the thread's id,
  # nil until the first request opens it, `system` the prompt it was
  # opened with, and `fresh?` whether it still waits for its replay.
  #
  # `phase` is the phase of the turn, and holds the data that only that
  # phase has:
  #
  # - `:idle`: no turn.
  # - `{:opening, id, from, prompt, history}`: the thread opens for a model
  #   turn. `prompt` is the turn's input, and `history` the rest of its
  #   transcript for the replay of a fresh thread.
  # - `{:injecting, id, from, prompt}`: the thread takes the replay and
  #   waits for its `thread/inject_items` answer.
  # - `{:starting, id, from}`: the turn waits for its `turn/start` answer.
  # - `{:running, id, turn, mode}`: the program's turn `turn` runs; `mode`
  #   is `:model` for a model turn and `:compact` for a compaction.
  # - `{:compacting, id, from}`: a compaction whose `turn/started` did not
  #   come yet, which gives its program turn id.
  #
  # `id` is the Helyx turn, and `from` the `{:turn, ...}` or the
  # `{:compact, ...}` request that waits for an answer, nil once it has
  # one. `interrupt` is an interrupt without an answer (`{:pending, from}`
  # before the program turn id is known, `{:sent, from, id}` after the
  # `turn/interrupt` with the request id `id`), `due` maps the id of each
  # request without an answer to its method (the turn's end settles a
  # `turn/interrupt`; an answer with an id that is not due is dropped),
  # `next_id` is the id of the next request, and `out` the actions to
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
  # `approvals` holds the JSON-RPC id of each approval request that waits
  # for Core, by its approval id (`Approvals`).
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
    :interrupt,
    :trust,
    tools: %Helyx.Provider.Codex.Tools{},
    fresh?: false,
    persist?: true,
    phase: :idle,
    due: %{},
    next_id: 1,
    out: [],
    items: %Helyx.Provider.Codex.Items{},
    agents: %{},
    asked: %{},
    approvals: %{},
    stream: %Helyx.HarnessIO.Stream{}
  ]

  # The Helyx turn id of the phase, or nil between turns.
  def turn_id(%__MODULE__{phase: :idle}), do: nil
  def turn_id(%__MODULE__{phase: {:opening, id, _from, _prompt, _history}}), do: id
  def turn_id(%__MODULE__{phase: {:injecting, id, _from, _prompt}}), do: id
  def turn_id(%__MODULE__{phase: {:starting, id, _from}}), do: id
  def turn_id(%__MODULE__{phase: {:running, id, _turn, _mode}}), do: id
  def turn_id(%__MODULE__{phase: {:compacting, id, _from}}), do: id

  # The request of the turn that waits for an answer, or nil.
  def from(%__MODULE__{phase: {:opening, _id, from, _prompt, _history}}), do: from
  def from(%__MODULE__{phase: {:injecting, _id, from, _prompt}}), do: from
  def from(%__MODULE__{phase: {:starting, _id, from}}), do: from
  def from(%__MODULE__{phase: {:compacting, _id, from}}), do: from
  def from(%__MODULE__{}), do: nil

  # The state with no request of the turn waiting for an answer.
  def clear_from(%__MODULE__{phase: {:opening, id, _from, prompt, history}} = state),
    do: %{state | phase: {:opening, id, nil, prompt, history}}

  def clear_from(%__MODULE__{phase: {:injecting, id, _from, prompt}} = state),
    do: %{state | phase: {:injecting, id, nil, prompt}}

  def clear_from(%__MODULE__{phase: {:starting, id, _from}} = state),
    do: %{state | phase: {:starting, id, nil}}

  def clear_from(%__MODULE__{phase: {:compacting, id, _from}} = state),
    do: %{state | phase: {:compacting, id, nil}}

  # The program's turn id of the running turn, or nil.
  def program(%__MODULE__{phase: {:running, _id, turn, _mode}}), do: turn
  def program(%__MODULE__{}), do: nil

  # Whether the turn is a compaction.
  def compaction?(%__MODULE__{phase: {:compacting, _id, _from}}), do: true
  def compaction?(%__MODULE__{phase: {:running, _id, _turn, :compact}}), do: true
  def compaction?(%__MODULE__{}), do: false
end
