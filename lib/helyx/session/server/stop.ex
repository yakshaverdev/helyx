defmodule Helyx.Session.Server.Stop do
  @moduledoc false
  # The stop of a session (`terminate/2` of `Helyx.Session.Server`): the work
  # that `work/1` lists ends, the kill of a prepare Task or the close of
  # provider processes, then the stop of the hands, the delete of the
  # background folder, and the release of the writer lock. `run/1` returns
  # the stop report (docs/features/session-lifecycle.md, "Session stop").
  # Each wait has a margin for load, so the supervisor does not kill it
  # first: `shutdown_ms/0` is the shutdown of the session process.

  import Helyx.Session.Server.State, only: [ask: 4]

  alias Helyx.Session.{Hands, Lock}
  alias Helyx.Session.Server.State
  alias Helyx.Session.Turn

  @load_hands_stop_ms 2_000
  @load_shutdown_ms 3_000
  @hands_stop_ms Hands.State.release_ms() + @load_hands_stop_ms
  def shutdown_ms,
    do: State.provider_close_ms() + @hands_stop_ms + Lock.release_ms() + @load_shutdown_ms

  # The prepare Task runs under the task supervisor, not linked: it is killed
  # here. Each provider process gets a close after any request it has open: a
  # `:busy` answer to an idle close does not keep it. The armed close kills
  # bound the waits, which run in parallel.
  def run(%State{} = state) do
    %{kill: kill, close: close} = work(state)
    Enum.each(kill, &Process.exit(&1, :kill))

    refs =
      for pid <- close do
        ref = Process.monitor(pid)
        ask(state, pid, :close, :close)
        ref
      end

    for ref <- refs do
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end

    left = stop_hands(state.hands)
    # A stop in a turn has no turn end: the sync gets the messages of the
    # turn here, before the worker sees the session end.
    Helyx.Session.Sync.push_turn(state)

    # After the hands: no background Task writes to the folder any more.
    File.rm_rf(state.background_dir)
    # Last, so no process of the session writes to the file once another OS
    # process can take the lock.
    Lock.release(State.lock(state))
    if left == [], do: :ok, else: {:error, {:not_released, left}}
  end

  # The end of a closed provider process must reach the hands before its
  # `:DOWN` reaches the session, so the hands release its handles and do not
  # kill it with `:cancel`. The releases end by one release deadline from
  # here; over `@hands_stop_ms` the hands are killed, and the handles left are
  # unknown. Hands that are already gone answer no call.
  defp stop_hands(hands) do
    ref = Process.monitor(hands)
    deadline = System.monotonic_time(:millisecond) + Hands.State.release_ms()

    left =
      try do
        Hands.stop(hands, deadline, @hands_stop_ms)
      catch
        :exit, _reason ->
          Process.exit(hands, :kill)
          :unknown
      end

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> left
    end
  end

  # In a turn, its prepare Task, to kill; the hands take its provider
  # process and a summary process (`Helyx.Session.Server.Summary`). With no
  # turn, the provider process, also one that ends, to close. A start with no
  # answer yet has no pid: its process ends with the hands.
  defp work(%State{phase: %{turn: %Turn{prepare: {_ref, pid, _messages}}}}),
    do: %{kill: [pid], close: []}

  # A turn with no prepare Task: the hands take its provider process.
  defp work(%State{phase: %{turn: %Turn{}}}), do: %{kill: [], close: []}

  defp work(%State{phase: %{provider: %{pid: pid}}}) when pid != nil,
    do: %{kill: [], close: [pid]}

  defp work(_state), do: %{kill: [], close: []}
end
