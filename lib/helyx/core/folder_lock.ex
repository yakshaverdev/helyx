defmodule Helyx.Core.FolderLock do
  @moduledoc false
  # The lock of the data folder of a Core (docs/features/session-lock.md):
  # `flock` on `<sessions_dir>/core.lock`, held by the perl of
  # `Helyx.Session.Lock` from the start of Core to its stop. The first child
  # of Core, so it is taken before any session starts and released after the
  # last one stops. Its end stops Core (`auto_shutdown` of `Helyx.Core`).

  use GenServer

  alias Helyx.Session.Lock

  def start_link({dir, core}), do: GenServer.start_link(__MODULE__, {dir, core})

  @impl true
  def init({dir, core}) do
    # The port of the take sends its exit to this process.
    Process.flag(:trap_exit, true)

    # The same spelling that the folder makes (`Helyx.Session.File.mkdir/1`):
    # a path with `.` or `..` names its folder, which need not hold those.
    dir = dir |> Path.absname() |> Path.expand()

    with :ok <- Helyx.Session.File.mkdir(dir),
         {:ok, port} <- Lock.take(Path.join(dir, "core")) do
      {:ok, %{dir: dir, port: port, core: core}}
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

  # The stop of Core lets each session drain and save, and another Core may
  # own the folder by then. The sessions and the edits end at once, with no
  # last write; a write that runs now can still end.
  defp lost(state) do
    for supervisor <- [
          Helyx.Core.session_supervisor(state.core),
          Helyx.Core.task_supervisor(state.core)
        ],
        {_id, pid, _type, _modules} when is_pid(pid) <-
          DynamicSupervisor.which_children(supervisor),
        do: Process.exit(pid, :kill)

    {:stop, {:data_folder_lock_lost, state.dir}, state}
  end

  @impl true
  def terminate(_reason, state), do: Lock.release(state.port)
end
