defmodule Helyx.Tool.MCP.Source do
  @moduledoc false
  # The source process of `Helyx.Tool.MCP` (`docs/features/mcp-client.md`):
  # it reads the config, announces one group per server that passed the
  # checks, and launches one server Task per kept server with
  # `Helyx.Tool.launch/1`. It holds no port: each server Task owns its own,
  # so one server's failure stays with that server (decision 15). It puts
  # each listing of a server Task, fails a server that does not list its
  # tools within the start bound or that ends, starts a server again after
  # a call that ended with no response, at most 3 times (decision 14), and
  # routes the calls of its tools to the server Task of their server.
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
  # The time limit of a call, from the start of its call Task's call. The
  # app env `:mcp_call_ms` sets it for tests only.
  @call_ms 60_000
  # The starts again of one server after a call with no response.
  @max_restarts 3

  defstruct [:cwd, :wait_ms, servers: %{}, launches: %{}, tasks: %{}]

  def run(%{cwd: cwd}) do
    {servers, notices} = Config.read(Config.path())
    Enum.each(notices, &Helyx.Tool.notice/1)
    {:ok, kept} = Helyx.Tool.announce(Enum.map(servers, & &1.name))
    wait_ms = Application.get_env(:helyx_plugins, :mcp_wait_ms, @wait_ms)
    state = %__MODULE__{cwd: cwd, wait_ms: wait_ms}

    servers
    |> Enum.filter(&(&1.name in kept))
    |> Enum.reduce(state, fn config, state ->
      server = %{config: config, restarts: 0, waiting: [], handles: []}
      launch(%{state | servers: Map.put(state.servers, config.name, server)}, config.name)
    end)
    |> loop()
  end

  # A server Task of `name`, with the start bound from the request.
  defp launch(state, name) do
    %{config: config} = server = state.servers[name]
    deadline = System.monotonic_time(:millisecond) + state.wait_ms
    source = self()
    opts = [wait_ms: state.wait_ms, call_ms: call_ms()] ++ watchdog_exe(name)
    ref = Helyx.Tool.launch(fn -> Server.run(config, source, state.cwd, deadline, opts) end)
    timer = Process.send_after(self(), {:start_timeout, name}, state.wait_ms)

    server =
      Map.merge(server, %{ref: ref, pid: nil, timer: timer, status: :starting, handles: []})

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

  defp handle({:handles, pid, handles}, state) when is_map_key(state.tasks, pid),
    do: {:ok, update(state, state.tasks[pid], &%{&1 | handles: handles})}

  defp handle({:listed, pid, entries, notices}, state) when is_map_key(state.tasks, pid) do
    name = Map.fetch!(state.tasks, pid)
    Enum.each(notices, &Helyx.Tool.notice/1)

    case state.servers[name] do
      %{status: status} = server when status in [:starting, :ready] ->
        Process.cancel_timer(server.timer)
        :ok = Helyx.Tool.put_tools(name, {:ok, entries})
        for {caller, ref} <- server.waiting, do: send(caller, {ref, {:ok, pid, server.handles}})
        {:ok, put_in(state.servers[name], %{server | status: :ready, waiting: []})}

      _failed ->
        {:ok, state}
    end
  end

  defp handle({:failed, pid, text}, state) when is_map_key(state.tasks, pid),
    do: {:ok, fail(state, Map.fetch!(state.tasks, pid), text)}

  defp handle({:restart, pid}, state) when is_map_key(state.tasks, pid) do
    name = Map.fetch!(state.tasks, pid)
    server = state.servers[name]

    if server.restarts >= @max_restarts,
      do: {:ok, fail(state, name, "did not answer a call #{@max_restarts + 1} times")},
      else:
        {:ok,
         put_in(state.servers[name], %{
           server
           | status: :restarting,
             restarts: server.restarts + 1
         })}
  end

  # The hands released the groups of a server Task that ended for a
  # restart: only now a new one starts, so two never hold one server.
  defp handle({ref, :released, outcome}, state) do
    case Enum.find(state.servers, fn {_name, server} -> server[:ref] == ref end) do
      {name, %{status: :restarting}} when outcome == :ok ->
        {:ok, launch(state, name)}

      {name, %{status: :restarting}} ->
        {:ok, fail(state, name, "its process group was not confirmed gone; it may still run")}

      _other ->
        {:ok, state}
    end
  end

  defp handle({:start_timeout, name}, state) do
    case state.servers[name] do
      %{status: :starting} ->
        {:ok, fail(state, name, "did not start in #{div(state.wait_ms, 1000)} s")}

      _other ->
        {:ok, state}
    end
  end

  defp handle({:route, {pid, ref}, tool}, state), do: {:ok, route(state, tool, pid, ref)}

  defp handle({:EXIT, pid, _reason}, state) when is_map_key(state.tasks, pid) do
    {name, tasks} = Map.pop!(state.tasks, pid)
    state = %{state | tasks: tasks}

    case state.servers[name] do
      %{status: status} when status in [:failed, :restarting] -> {:ok, state}
      %{pid: ^pid} -> {:ok, fail(state, name, "the server ended")}
      _older -> {:ok, state}
    end
  end

  defp handle({:EXIT, _pid, _reason} = exit, state) do
    if map_size(state.launches) > 0,
      do: handle(exit, answers(state)),
      else: :stop
  end

  # A server Task's message can come before the hands' answer that names
  # its pid: two senders, no order. The open launches are answered first.
  defp handle(message, state) when map_size(state.launches) > 0 do
    case task_pid(message) do
      pid when is_pid(pid) and not is_map_key(state.tasks, pid) -> handle(message, answers(state))
      _other -> {:ok, state}
    end
  end

  defp handle(_message, state), do: {:ok, state}

  defp task_pid({kind, pid, _value}) when kind in [:handles, :failed], do: pid
  defp task_pid({:listed, pid, _entries, _notices}), do: pid
  defp task_pid({:restart, pid}), do: pid
  defp task_pid(_message), do: nil

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
      %{status: :starting, ref: ^ref} = server ->
        put_in(state.servers[name], %{server | pid: pid})

      # It failed before the hands answered: its start bound passed.
      _failed ->
        Process.exit(pid, :kill)
        state
    end
  end

  # The server is failed: its tools leave the session, a search names it
  # with `text` (decision 9), the calls that wait for it get the text, and
  # its Task is killed if it still runs.
  defp fail(state, name, text) do
    server = state.servers[name]
    Process.cancel_timer(server.timer)
    if server.pid, do: Process.exit(server.pid, :kill)

    for {caller, ref} <- server.waiting,
        do: send(caller, {ref, {:error, "the MCP server #{name} " <> text}})

    :ok = Helyx.Tool.put_tools(name, {:error, text})
    put_in(state.servers[name], %{server | status: :failed, waiting: []})
  end

  defp update(state, name, fun), do: %{state | servers: Map.update!(state.servers, name, fun)}

  # The server Task and the handles of a tool's server, by the part of its
  # name before the first `__` (decision 8). A call of a server that starts,
  # or starts again, waits for it within its own time limit.
  defp route(state, tool, caller, ref) do
    [name | _] = String.split(tool, "__", parts: 2)

    case state.servers[name] do
      %{status: :ready, pid: pid, handles: handles} ->
        send(caller, {ref, {:ok, pid, handles}})
        state

      # A waiter whose call Task ended (its time limit passed) leaves.
      %{status: status} when status in [:starting, :restarting] ->
        waiting = fn waiting ->
          [{caller, ref} | Enum.filter(waiting, &Process.alive?(elem(&1, 0)))]
        end

        update(state, name, &%{&1 | waiting: waiting.(&1.waiting)})

      _other ->
        send(caller, {ref, {:error, "the MCP server #{name} is not running"}})
        state
    end
  end

  # A call of an MCP tool, in its call Task: the route from the source,
  # the hold of the server's groups as `{:mcp_call, handles}` (an abort
  # releases them), then the call to the server Task, which answers
  # within the time limit.
  # Room past the call's deadline for the server Task's own answer at it.
  @answer_ms 5_000

  def call(args) do
    call_ms = call_ms()
    deadline = System.monotonic_time(:millisecond) + call_ms
    %{tool: tool, source: source} = Helyx.Tool.context()

    not_run =
      {:error,
       "timed out after #{div(call_ms, 1000)} s: the MCP server did not start, the call did not run"}

    # The wait for the route ends at the deadline: past it, the call is not sent.
    case ask(source, {:route, tool}, deadline, 0) do
      {:ok, pid, handles} ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: not_run,
          else: send_call(pid, handles, tool, args, deadline, call_ms)

      :timeout ->
        not_run

      {:error, _text} = error ->
        error
    end
  end

  defp send_call(pid, handles, tool, args, deadline, call_ms) do
    :ok = Helyx.Tool.hold({:mcp_call, handles})

    case ask(pid, {:call, tool, args, deadline}, deadline, @answer_ms) do
      :timeout -> {:error, "timed out after #{div(call_ms, 1000)} s; the call may have run"}
      reply -> reply
    end
  end

  defp call_ms, do: Application.get_env(:helyx_plugins, :mcp_call_ms, @call_ms)

  defp ask(pid, request, deadline, margin) do
    monitor = Process.monitor(pid)
    ref = make_ref()

    message =
      case request do
        {:route, tool} -> {:route, {self(), ref}, tool}
        {:call, tool, args, deadline} -> {:call, {self(), ref}, tool, args, deadline}
      end

    send(pid, message)

    receive do
      {^ref, reply} ->
        Process.demonitor(monitor, [:flush])
        reply

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, "the MCP server ended during the call"}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) + margin ->
        Process.demonitor(monitor, [:flush])
        :timeout
    end
  end
end
