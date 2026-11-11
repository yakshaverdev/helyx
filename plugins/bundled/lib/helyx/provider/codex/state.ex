defmodule Helyx.Provider.Codex.State do
  @moduledoc false
  # The provider state of one program. The phases, the interrupt, the
  # request ids, and the child threads are in
  # docs/features/long-lived-harness.md, "Codex".
  # `fresh?` is true while the thread waits for its replay. `out` holds the
  # actions to return, newest first.
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
