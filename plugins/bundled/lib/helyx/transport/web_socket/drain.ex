defmodule Helyx.Transport.WebSocket.Drain do
  @moduledoc false
  # The first step of the stop of the transport (`docs/features/wire-protocol.md`,
  # Bounds), one for each transport. It closes the listener and the gate,
  # then kills each connection that is not inside the gate: such a
  # connection holds no session, and one inside its HTTP headers would hold
  # the stop of Thousand Island for its `shutdown_timeout`. The supervisor
  # kills the step past its shutdown.

  use GenServer, shutdown: 5_000

  alias Helyx.Transport.WebSocket.Gate

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  # After a crash of the gate or of the listener, nothing tells the
  # WebSocket connections from the others, and the stop of Thousand Island
  # alone ends them.
  @impl true
  def terminate(_reason, {bandit, gate}) do
    if Process.alive?(bandit) and Process.alive?(gate) do
      :ok = ThousandIsland.suspend(bandit)
      {:ok, pids} = ThousandIsland.connection_pids(bandit)
      for pid <- pids -- Gate.close(gate), do: Process.exit(pid, :kill)
    end
  end
end
