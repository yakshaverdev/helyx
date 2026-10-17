defmodule Helyx.Provider.Codex.Wire do
  @moduledoc false
  # The output of `Helyx.Provider.Codex`: the actions in `out`, newest
  # first, and the lines to the program with the request ids in `due`.

  alias Helyx.HarnessIO
  alias Helyx.Provider.Codex.State

  def actions(state), do: {:ok, Enum.reverse(state.out), %{state | out: []}}

  # The output of the lines before the terminal line goes out first.
  def stop(reason, state), do: {:stop, reason, Enum.reverse(state.out), %{state | out: []}}

  def reply(state, from, value), do: %{state | out: [{:reply, from, value} | state.out]}

  # `events` in order; `out` is newest first.
  def push(state, events),
    do: %{state | out: Enum.reverse(Enum.map(events, &{:event, state.turn_id, &1}), state.out)}

  def rpc(state, method, params) do
    {id, state} = open(state, method)
    send_line(state, %{id: id, method: method, params: params})
    state
  end

  # A new request id, due until its answer.
  def open(%State{next_id: id} = state, method),
    do: {id, %{state | next_id: id + 1, due: Map.put(state.due, id, method)}}

  def send_line(state, %{} = map), do: send_line(state, JSON.encode!(map))
  def send_line(state, line), do: HarnessIO.write(state, [line, "\n"])
end
