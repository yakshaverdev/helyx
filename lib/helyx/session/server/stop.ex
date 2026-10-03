defmodule Helyx.Session.Server.Stop do
  @moduledoc false
  # The stop of a session (`terminate/2` of `Helyx.Session.Server`): the
  # kill of the prepare Task of a turn, or the close of the provider
  # processes of a session with no turn
  # (`State.provider_close_ms/0`, armed kill), then the stop of the hands,
  # which can finish one release (`Hands.State.release_ms/0`). Each wait
  # has a margin for load, so the supervisor does not kill it first:
  # `shutdown_ms/0` is the shutdown of the session process.

  import Helyx.Session.Server.State, only: [ask: 4, provider_pid: 1]

  alias Helyx.Session.{Hands, Turn}
  alias Helyx.Session.Server.{State, TurnLoop, Wait}

  @load_hands_stop_ms 2_000
  @load_shutdown_ms 3_000
  @hands_stop_ms Hands.State.release_ms() + @load_hands_stop_ms
  def shutdown_ms, do: State.provider_close_ms() + @hands_stop_ms + @load_shutdown_ms

  # The close of the provider processes (`end_work/1`), then the stop of
  # the hands.
  def run(%State{} = state) do
    end_work(state)
    stop_hands(state.hands)
  end

  # The prepare Task of a turn runs under the task supervisor, not linked:
  # it is killed here. On an untrappable kill of the session its armed
  # kill ends it.
  defp end_work(%State{activity: %Turn{} = turn}), do: TurnLoop.kill_prepare(turn)

  # A session that ends with no turn closes its provider processes: the
  # current one and the one its wait is for (an idle close, a switch
  # close, an abort). Each gets a close, end of input then the exit, after
  # any request it has open: a `:busy` answer to an idle close does not
  # keep it. The armed close kills bound the waits, which run in parallel,
  # and a provider process that is already gone gives its `:DOWN` at once.
  defp end_work(%State{activity: activity} = state) do
    pids = [provider_pid(state), wait_pid(activity)]

    refs =
      for pid <- Enum.uniq(pids), is_pid(pid) do
        ref = Process.monitor(pid)
        ask(state, pid, :close, :close)
        ref
      end

    for ref <- refs do
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end
  end

  defp wait_pid(%Wait{provider: pid}), do: pid
  defp wait_pid(:idle), do: nil

  # The hands take the messages before the exit signal first: the end of a
  # closed provider process gets its release. That end reaches the hands
  # before the provider process's `:DOWN` reaches the session, on one node.
  # If it came later, the hands would end with no release, and the port
  # would close with the provider process. Each release has its deadline,
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
end
