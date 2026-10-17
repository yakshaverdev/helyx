defmodule Helyx.Session.Server.Stop do
  @moduledoc false
  # The stop of a session (`terminate/2` of `Helyx.Session.Server`): the
  # work that `work/1` lists ends, the kill of a prepare Task or
  # the close of provider processes (`State.provider_close_ms/0`, armed
  # kill), then the stop of the hands, which can finish one release
  # (`Hands.State.release_ms/0`), the delete of the background folder, and
  # the release of the writer lock (`Lock.release_ms/0`).
  # Each wait has a margin for load, so the
  # supervisor does not kill it first: `shutdown_ms/0` is the shutdown of
  # the session process.

  import Helyx.Session.Server.State, only: [ask: 4]

  alias Helyx.Session.{Hands, Lock}
  alias Helyx.Session.Server.{ProviderConn, State}
  alias Helyx.Session.Turn

  @load_hands_stop_ms 2_000
  @load_shutdown_ms 3_000
  @hands_stop_ms Hands.State.release_ms() + @load_hands_stop_ms
  def shutdown_ms,
    do: State.provider_close_ms() + @hands_stop_ms + Lock.release_ms() + @load_shutdown_ms

  # The prepare Task of a turn runs under the task supervisor, not linked:
  # it is killed here. On an untrappable kill of the session its armed
  # kill ends it. Each provider process gets a close, end of input then
  # the exit, after any request it has open: a `:busy` answer to an idle
  # close does not keep it. The armed close kills bound the waits, which
  # run in parallel, and a provider process that is already gone gives its
  # `:DOWN` at once.
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

    stop_hands(state.hands)
    # A stop in a turn has no turn end: the sync gets the messages of the
    # turn here, before the worker sees the session end.
    Helyx.Session.Sync.push_turn(state)

    # After the hands: no background Task writes to the folder any more.
    File.rm_rf(state.background_dir)
    # Last, so no process of the session writes to the file once another
    # OS process can take the lock.
    Lock.release(state.lock)
  end

  # The hands take the messages before the exit signal first: the end of a
  # closed provider process gets its release. That end reaches the hands
  # before the provider process's `:DOWN` reaches the session, on one node.
  # If it came later, the hands would end with no release of the
  # handles of the provider process. Each release has its deadline,
  # so the wait is bounded; over @hands_stop_ms the hands are killed, and a
  # killed process runs no release. Hands that are already gone give their
  # `:DOWN` at once.
  defp stop_hands(hands) do
    ref = Process.monitor(hands)
    Process.exit(hands, :shutdown)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @hands_stop_ms ->
        Process.exit(hands, :kill)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        end
    end
  end

  # The work that a session stop ends: in a turn, its prepare Task, to
  # kill; the hands take its provider process and a summary process
  # (`Helyx.Session.Server.Summary`). With no turn, the provider
  # process, also one that ends (an idle close, a switch close, an abort),
  # to close. A start with no answer yet has no pid: its process ends with
  # the hands.
  defp work(%State{activity: %Turn{prepare: pid}}), do: %{kill: List.wrap(pid), close: []}
  defp work(%State{conn: %ProviderConn{pid: pid}}) when pid != nil, do: %{kill: [], close: [pid]}
  defp work(_state), do: %{kill: [], close: []}
end
