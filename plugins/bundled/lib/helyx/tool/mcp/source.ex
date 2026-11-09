defmodule Helyx.Tool.MCP.Source do
  @moduledoc false
  # The source process of `Helyx.Tool.MCP` (`docs/features/mcp-client.md`):
  # it reads the config, announces one group per server that passed the
  # checks, and launches one server Task per kept server with
  # `Helyx.Tool.launch/1`. It holds no port: each server Task owns its own,
  # so one server's failure stays with that server (decision 15). It puts
  # each listing of a server Task, fails a server that does not list its
  # tools within the start bound or that ends, and routes the calls of its
  # tools to the server Task of their server.
  #
  # The source traps exits. An `{:EXIT, pid, reason}` of a pid that is no
  # server Task of its own ends it, once the hands answered every open
  # launch: a server Task's exit and the hands' answer come from two
  # senders and have no order (`Helyx.Tool`, `launch/1`).

  alias Helyx.Tool.MCP.{Config, Server}

  # The bound of a start, from the launch request to the last page of
  # `tools/list`, and of a later listing. The app env `:mcp_wait_ms` of
  # `helyx_plugins` sets it for tests only.
  @wait_ms 30_000

  defstruct [:cwd, :wait_ms, servers: %{}, launches: %{}, tasks: %{}]

  def run(%{cwd: cwd}) do
    {servers, notices} = Config.read(Config.path())
    Enum.each(notices, &Helyx.Tool.notice/1)
    {:ok, kept} = Helyx.Tool.announce(Enum.map(servers, & &1.name))

    state = %__MODULE__{
      cwd: cwd,
      wait_ms: Application.get_env(:helyx_plugins, :mcp_wait_ms, @wait_ms)
    }

    servers
    |> Enum.filter(&(&1.name in kept))
    |> Enum.reduce(state, &launch/2)
    |> loop()
  end

  defp launch(%Config{name: name} = config, state) do
    deadline = System.monotonic_time(:millisecond) + state.wait_ms
    source = self()
    opts = [wait_ms: state.wait_ms] ++ watchdog_exe(name)
    ref = Helyx.Tool.launch(fn -> Server.run(config, source, state.cwd, deadline, opts) end)
    timer = Process.send_after(self(), {:start_timeout, name}, state.wait_ms)
    server = %{ref: ref, pid: nil, timer: timer, status: :starting}

    %{
      state
      | servers: Map.put(state.servers, name, server),
        launches: Map.put(state.launches, ref, name)
    }
  end

  # For tests only: the program in place of perl for a server's watchdog.
  defp watchdog_exe(name) do
    case Application.get_env(:helyx_plugins, :mcp_watchdog_exe, %{}) do
      %{^name => exe} -> [watchdog_exe: exe]
      _none -> []
    end
  end

  defp loop(state) do
    receive do
      message ->
        case handle(message, state) do
          {:ok, state} -> loop(state)
          :stop -> :ok
        end
    end
  end

  defp handle({ref, {:ok, pid}}, state) when is_map_key(state.launches, ref),
    do: {:ok, started(state, ref, pid)}

  defp handle({ref, {:error, reason}}, state) when is_map_key(state.launches, ref) do
    {name, launches} = Map.pop!(state.launches, ref)
    {:ok, fail(%{state | launches: launches}, name, "the hands refused its start (#{reason})")}
  end

  defp handle({:listed, pid, entries, notices}, state) when is_map_key(state.tasks, pid) do
    name = Map.fetch!(state.tasks, pid)
    Enum.each(notices, &Helyx.Tool.notice/1)

    case state.servers[name] do
      %{status: status} = server when status in [:starting, :ready] ->
        Process.cancel_timer(server.timer)
        :ok = Helyx.Tool.put_tools(name, {:ok, entries})
        {:ok, put_in(state.servers[name], %{server | status: :ready})}

      _failed ->
        {:ok, state}
    end
  end

  defp handle({:failed, pid, text}, state) when is_map_key(state.tasks, pid),
    do: {:ok, fail(state, Map.fetch!(state.tasks, pid), text)}

  defp handle({:start_timeout, name}, state) do
    case state.servers[name] do
      %{status: :starting} ->
        {:ok, fail(state, name, "did not start in #{div(state.wait_ms, 1000)} s")}

      _other ->
        {:ok, state}
    end
  end

  defp handle({:route, {pid, ref}, tool}, state) do
    send(pid, {ref, route(state, tool)})
    {:ok, state}
  end

  defp handle({:EXIT, pid, _reason}, state) when is_map_key(state.tasks, pid) do
    {name, tasks} = Map.pop!(state.tasks, pid)
    state = %{state | tasks: tasks}

    case state.servers[name] do
      %{status: :failed} -> {:ok, state}
      _running -> {:ok, fail(state, name, "the server ended")}
    end
  end

  defp handle({:EXIT, _pid, _reason} = exit, state) do
    if map_size(state.launches) > 0,
      do: handle(exit, answers(state)),
      else: :stop
  end

  defp handle(_message, state), do: {:ok, state}

  # The hands' answers to the open launches, before an exit decides.
  defp answers(state) do
    receive do
      {ref, {:ok, pid}} when is_map_key(state.launches, ref) ->
        started(state, ref, pid)

      {ref, {:error, _reason}} = refused when is_map_key(state.launches, ref) ->
        elem(handle(refused, state), 1)
    end
  end

  defp started(state, ref, pid) do
    {name, launches} = Map.pop!(state.launches, ref)
    state = %{state | launches: launches, tasks: Map.put(state.tasks, pid, name)}

    case state.servers[name] do
      %{status: :starting} = server -> put_in(state.servers[name], %{server | pid: pid})
      # It failed before the hands answered: its start bound passed.
      _failed -> tap(state, fn _ -> Process.exit(pid, :kill) end)
    end
  end

  # The server is failed: its tools leave the session, a search names it
  # with `text` (decision 9), and its Task is killed if it still runs.
  defp fail(state, name, text) do
    server = state.servers[name]
    Process.cancel_timer(server.timer)
    if server.pid, do: Process.exit(server.pid, :kill)
    :ok = Helyx.Tool.put_tools(name, {:error, text})
    put_in(state.servers[name], %{server | status: :failed})
  end

  # The server Task of a tool's server, by the part of its name before the
  # first `__` (decision 8).
  defp route(state, tool) do
    [name | _] = String.split(tool, "__", parts: 2)

    case state.servers[name] do
      %{status: :ready, pid: pid} when is_pid(pid) -> {:ok, pid}
      %{status: :starting} -> {:error, "the MCP server #{name} has not started yet"}
      _other -> {:error, "the MCP server #{name} is not running"}
    end
  end

  # A call of an MCP tool, in its call Task: the route from the source,
  # then the call to the server Task, which answers within its time limit.
  def call(args) do
    %{tool: tool, source: source} = Helyx.Tool.context()

    with {:ok, pid} <- ask(source, {:route, tool}) do
      ask(pid, {:call, tool, args})
    end
  end

  defp ask(pid, request) do
    monitor = Process.monitor(pid)
    ref = make_ref()

    message =
      case request do
        {:route, tool} -> {:route, {self(), ref}, tool}
        {:call, tool, args} -> {:call, {self(), ref}, tool, args}
      end

    send(pid, message)

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, "the MCP server ended during the call"}
    end
  end
end
