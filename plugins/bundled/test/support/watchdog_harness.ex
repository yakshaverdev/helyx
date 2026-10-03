defmodule Helyx.Test.WatchdogHarness do
  @moduledoc false
  # A connected provider (ADR 0007) whose program is `sleep` under the
  # watchdog, for the stop path end to end (#199). The program writes its
  # pid, which is also its group, to `pid_path(session_id)`. Models:
  #
  #   "block"  the turn callback blocks, so the armed kill stops the harness
  #   "flood"  the turn writes twice the watchdog stdin cap to the program,
  #            which never reads its stdin
  #   "idle"   the turn answers :ok and ends, so the provider process is idle
  #   other    the turn answers :ok and never ends
  @behaviour Helyx.Provider

  def pid_path(session_id), do: Path.join(System.tmp_dir!(), "helyx-wdh-#{session_id}.pid")

  @impl true
  def id, do: "wdh"

  @impl true
  def release(handles, mode, deadline), do: Helyx.Watchdog.Group.release(handles, mode, deadline)

  @impl true
  def init(model, _tools, opts) do
    argv = ["sh", "-c", "echo $$ > '#{pid_path(opts[:session_id])}'; exec sleep 30"]

    case Helyx.Watchdog.start(argv, opts[:cwd], :open, grace_ms: 200) do
      {:started, port, _pre} ->
        {:ok, %{model: model, port: port}}

      other ->
        {:error, other}
    end
  end

  # The block is the point of this model.
  @dialyzer {:nowarn_function, request: 3}
  @impl true
  def request({:turn, _turn_id, _context}, _from, %{model: "block"}),
    do: Process.sleep(:infinity)

  def request({:turn, _turn_id, _context}, from, %{model: "flood", port: port} = state) do
    Helyx.Watchdog.write(port, :binary.copy("x", 2 * Helyx.Watchdog.stdin_max_bytes()))
    {:ok, [{:reply, from, :ok}], state}
  end

  def request({:turn, turn_id, _context}, from, %{model: "idle"} = state) do
    done = {:done, %{stop_reason: :end_turn, usage: %{}}}
    {:ok, [{:reply, from, :ok}, {:event, turn_id, done}], state}
  end

  def request(_request, from, state), do: {:ok, [{:reply, from, :ok}], state}

  @impl true
  def info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:exit_status, status}, state}

  def info(_message, state), do: {:ok, [], state}
end
