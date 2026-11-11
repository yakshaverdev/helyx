defmodule Helyx.Session.Hands.Sources do
  @moduledoc false
  # The Tasks of the tool sources in `Helyx.Session.Hands`: a source process for
  # each tool source of the session, and the server Tasks that a source starts
  # with `Helyx.Tool.launch/1` (docs/features/mcp-client.md). Neither is a tool
  # call: no turn, no call cap, no abort. Their handles go to the plugin's
  # `release/3` when the Task ends, as a provider process's do.

  alias Helyx.Session.Hands
  alias Helyx.Session.Hands.{End, Entry, Release}

  # The server Tasks of one source, live at once.
  @max_server_tasks 16

  def start(hands, plugin, info), do: GenServer.cast(hands, {:source, {:start, plugin, info}})

  # The tool map of the hands (`Helyx.Session.ToolRegistry.modules/1`): the
  # session sends each change before any context holds it.
  def tools(hands, tools), do: GenServer.cast(hands, {:source, {:tools, tools}})

  # The pid of the source process of `plugin`, or nil: the tools of a source
  # count only while it runs.
  def pid(state, plugin) do
    Enum.find_value(state.tasks, fn {_ref, entry} ->
      case entry.kind do
        {:source, ^plugin} -> entry.task.pid
        _kind -> nil
      end
    end)
  end

  def handle({:tools, tools}, state), do: %{state | tools: tools}

  # The session records the pid before its go (`Helyx.Session.Ask.await_go/0`),
  # so a call of the source finds its record.
  def handle({:start, plugin, info}, state) do
    hands = self()

    {task, state} =
      Hands.spawn_task(state, {:source, plugin}, nil, plugin, body(plugin, info, hands))

    send(state.session, {:source, task.pid, plugin})
    state
  end

  # A launch of a source that ended since it sent it starts nothing.
  def handle({:launch, ref, source, fun}, state) do
    case plugin(state, source) do
      nil -> state
      plugin -> launch(state, ref, source, plugin, fun)
    end
  end

  # The module of the tool `name`, or `:error`. A tool of a source counts only
  # while that source runs: derived here at each call, whatever tool map the
  # session sent last, which can name the tools of a source that ended before
  # the session heard of its end.
  def lookup(state, name) do
    case Map.fetch(state.tools, name) do
      {:ok, tool} -> if live?(state, tool), do: {:ok, tool}, else: :error
      :error -> :error
    end
  end

  # The names that `lookup/2` finds, for `Helyx.Tool.context/0`.
  def names(state), do: for({name, tool} <- state.tools, live?(state, tool), do: name)

  defp live?(state, tool), do: not Helyx.Tool.source?(tool) or pid(state, tool) != nil

  # The plugin of the source process `source`, or nil.
  defp plugin(state, source) do
    Enum.find_value(state.tasks, fn
      {_ref, %{kind: {:source, plugin}, task: %{pid: ^source}}} -> plugin
      _other -> nil
    end)
  end

  # The body of the source process; it never returns (`run/3`).
  @spec body(module(), map(), pid()) :: (-> no_return())
  @dialyzer {:nowarn_function, body: 3}
  defp body(plugin, info, hands) do
    fn ->
      Process.put(:helyx_source, plugin)
      Helyx.Session.Ask.await_go()
      Helyx.Reason.task("tool source crashed", fn -> run(plugin, info, hands) end)
    end
  end

  # The source traps exits, and its Task ends with `:shutdown` when `source/1`
  # returns or calls `exit(:normal)`: a link passes no `:normal` on, and every
  # server Task must end with its source. A guard kills the source when the
  # hands end, as a kill of the hands that skips their `terminate/2` (`Stop`),
  # so no trapped exit signal waits for plugin code that never reads it.
  defp run(plugin, info, hands) do
    source = self()
    spawn(fn -> guard(source, hands) end)
    Process.flag(:trap_exit, true)

    try do
      plugin.source(info)
    catch
      :exit, :normal -> :ok
    end

    exit(:shutdown)
  end

  defp guard(source, hands) do
    source_ref = Process.monitor(source)
    hands_ref = Process.monitor(hands)

    receive do
      {:DOWN, ^hands_ref, :process, _pid, _reason} -> Process.exit(source, :kill)
      {:DOWN, ^source_ref, :process, _pid, _reason} -> :ok
    end
  end

  defp launch(state, ref, source, plugin, fun) do
    live =
      Enum.count(state.tasks, fn {_ref, entry} ->
        match?({:server, ^source, _launch}, entry.kind)
      end)

    cond do
      state.unconfirmed != [] ->
        send(source, {ref, {:error, :unconfirmed}})
        state

      live >= @max_server_tasks ->
        send(source, {ref, {:error, :too_many_tasks}})
        state

      true ->
        {task, state} =
          Hands.spawn_task(state, {:server, source, ref}, nil, plugin, fn ->
            serve(source, fun)
          end)

        send(source, {ref, {:ok, task.pid}})
        state
    end
  end

  # The link is the Task's first act: a source that is gone ends it here, and a
  # later end of the source ends it however it waits.
  defp serve(source, fun) do
    Helyx.Reason.task("tool source server crashed", fn ->
      Process.link(source)
      fun.()
    end)
  end

  # The release of its handles, then the word to the session or to the source.
  def deliver(state, ref) do
    %Entry{task: task, kind: kind} = Map.fetch!(state.tasks, ref)
    {left, state} = End.finish(state, [ref], :deliver, state.release_ms, false)
    # The log gets an unconfirmed handle; the session counts the Task gone.
    Release.error(left)
    ended(kind, task.pid, left, state)
  end

  defp ended({:source, _plugin}, pid, _left, state) do
    send(state.session, {:source_down, pid})
    state
  end

  defp ended({:server, source, ref}, _pid, left, state) do
    send(source, {ref, :released, if(left == %{}, do: :ok, else: :unconfirmed)})
    state
  end
end
