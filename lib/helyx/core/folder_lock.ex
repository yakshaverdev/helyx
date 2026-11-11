defmodule Helyx.Core.FolderLock do
  @moduledoc false
  # The lock of the data folder of a Core (docs/features/session-lock.md):
  # `flock` on `<sessions_dir>/core.lock`, held by the perl of
  # `Helyx.Session.Lock` from the start of Core to its stop. The first child
  # of Core, so it is taken before any session starts and released after the
  # last one stops. Its end stops Core (`auto_shutdown` of `Helyx.Core`).

  use GenServer

  alias Helyx.Session.Lock

  def start_link(dir), do: GenServer.start_link(__MODULE__, dir)

  @impl true
  def init(dir) do
    # The port of the take sends its exit to this process.
    Process.flag(:trap_exit, true)

    # The same spelling that the folder makes (`Helyx.Session.File.mkdir/1`):
    # a path with `.` or `..` names its folder, which need not hold those.
    dir = dir |> Path.absname() |> Path.expand()

    with :ok <- Helyx.Session.File.mkdir(dir),
         {:ok, port} <- Lock.take(Path.join(dir, "core")) do
      {:ok, %{dir: dir, port: port}}
    else
      {:error, :locked} -> {:stop, {:data_folder_locked, dir}}
      {:error, reason} -> {:stop, reason}
    end
  end

  # perl ended, so the kernel released the lock: another process can take
  # the folder now. Its status comes first, then the exit.
  @impl true
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state), do: lost(state)
  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: lost(state)

  defp lost(state), do: {:stop, {:data_folder_lock_lost, state.dir}, state}

  @impl true
  def terminate(_reason, state), do: Lock.release(state.port)
end
