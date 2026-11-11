defmodule Helyx.Tool.MCP.Server do
  @moduledoc false
  # The server Task of one MCP server (`docs/features/mcp-client.md`,
  # "Helyx.Tool.MCP"): it starts the server (`Helyx.Tool.MCP.Launch`), owns
  # its port, and speaks JSON-RPC 2.0 lines on its stdio: the handshake,
  # the paged `tools/list`, calls, the answers to the server's requests,
  # and a listing again at each `list_changed`. It sends its source
  # `{:handles, pid, handles}` after the start, `{:listed, pid, entries,
  # notices}` for each listing, `{:failed, pid, text}` before it ends on a
  # failure, and `{:restart, pid}` before it ends for a call that ended
  # with no response (decision 14). Either end is of this Task only; the
  # hands release its groups (decision 15).

  alias Helyx.Tool.MCP.{Config, Launch, Lines, Listing, Result}

  @protocol "2025-06-18"
  @versions ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
  @max_pages 16
  # The least time from the start of one listing to the next.
  @list_gap_ms 1_000

  # The phases of one server: the handshake (`:initializing`), the first
  # listing inside the same start bound (`:listing`), then the calls and
  # the later listings (`:serving`). One loop runs all three; the phase
  # decides what an exit and the start timer mean.
  defstruct [
    :config,
    :source,
    :port,
    :wait_ms,
    :call_ms,
    phase: :initializing,
    buffer: Lines.new(),
    next_id: 1,
    pending: %{},
    list: nil,
    queued?: false,
    listed_at: nil,
    names: %{}
  ]

  # The whole life of the server: start, handshake, listing, then serve.
  # `opts`: `:wait_ms`, the bound of a start and of a listing; `:call_ms`,
  # the time limit of a call, for its text; `:watchdog_exe`, for tests.
  def run(%Config{} = config, source, cwd, deadline, opts) do
    state = %__MODULE__{
      config: config,
      source: source,
      wait_ms: Keyword.fetch!(opts, :wait_ms),
      call_ms: Keyword.fetch!(opts, :call_ms)
    }

    case Launch.start(config, cwd, deadline, opts) do
      {:started, port, _pre, handles} ->
        send(source, {:handles, self(), handles})
        Process.send_after(self(), :start_timeout, max(deadline - now(), 0))
        handshake(%{state | port: port}) |> serve()

      {:error, reason} ->
        fail(state, start_error(state, reason, deadline))
    end
  end

  # The watchdog start waits until the same deadline, so a start that ends
  # past it is the start bound, whichever read ended last.
  defp start_error(state, reason, deadline) do
    if now() >= deadline,
      do: "did not start in #{div(state.wait_ms, 1000)} s",
      else: "did not start: " <> reason
  end

  defp handshake(state) do
    params = %{
      protocolVersion: @protocol,
      capabilities: %{},
      clientInfo: %{name: "helyx", version: "1"}
    }

    {id, state} = request(state, "initialize", params)
    %{state | pending: Map.put(state.pending, id, :initialize)}
  end

  # One loop for every phase. A message that a phase cannot get waits for no
  # clause, as each loop of a phase did before; the start timer and the
  # listing timer are the only bounds, and `@wait_ms` is their whole.
  defp serve(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        state |> data(data) |> serve()

      {port, {:exit_status, _status}} when port == state.port ->
        exit_status(state)

      :start_timeout ->
        start_timeout(state)

      {:call, from, name, args, deadline} ->
        state |> call(from, name, args, deadline) |> serve()

      {:call_timeout, id} ->
        call_timeout(state, id)

      {:DOWN, monitor, :process, _pid, _reason} ->
        state |> caller_down(monitor) |> serve()

      :relist ->
        state |> relist() |> serve()

      {:list_timeout, ref} ->
        list_timeout(state, ref)

      _other ->
        serve(state)
    end
  end

  @spec exit_status(map()) :: no_return()
  defp exit_status(%{phase: :serving} = state), do: exited(state)
  defp exit_status(state), do: fail(state, "the server exited")

  defp start_timeout(%{phase: :serving} = state), do: serve(state)

  defp start_timeout(state),
    do: fail(state, "did not start in #{div(state.wait_ms, 1000)} s")

  defp list_timeout(%{phase: :serving, list: %{ref: ref}} = state, ref),
    do: fail(state, "a listing of tools did not end in #{div(state.wait_ms, 1000)} s")

  defp list_timeout(state, _ref), do: serve(state)

  # Lines

  defp data(state, data) do
    case Lines.add(state.buffer, data) do
      {lines, buffer} -> Enum.reduce(lines, %{state | buffer: buffer}, &line/2)
      :too_long -> fail(state, "a line over #{Lines.max_bytes()} bytes")
    end
  end

  # A line that is not a JSON object is skipped, as `Helyx.HarnessIO` does.
  defp line(text, state) do
    case Helyx.JSON.decode(text) do
      {:ok, %{} = message} -> message(message, state)
      _other -> state
    end
  end

  defp message(%{"method" => method, "id" => id}, state) when is_binary(method) do
    if method == "ping",
      do: send_json(state, %{jsonrpc: "2.0", id: id, result: %{}}),
      else:
        send_json(state, %{
          jsonrpc: "2.0",
          id: id,
          error: %{code: -32_601, message: "Method not found"}
        })

    state
  end

  defp message(%{"method" => "notifications/tools/list_changed"}, state), do: changed(state)
  defp message(%{"method" => method}, state) when is_binary(method), do: state

  defp message(%{"id" => id} = message, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} -> state
      {kind, pending} -> answer(kind, id, Result.reply(message), %{state | pending: pending})
    end
  end

  defp message(_message, state), do: state

  defp answer(:initialize, _id, {:ok, %{"protocolVersion" => version}}, state)
       when version in @versions do
    notify(state, "notifications/initialized")
    state |> Map.put(:phase, :listing) |> list()
  end

  defp answer(:initialize, _id, {:ok, _result}, state),
    do: fail(state, "initialize: a protocol version that Helyx does not speak")

  defp answer(:initialize, _id, {:error, text}, state), do: fail(state, "initialize: " <> text)

  defp answer({:call, {pid, ref}, timer, monitor}, _id, reply, state) do
    Process.cancel_timer(timer)
    Process.demonitor(monitor, [:flush])

    send(pid, {ref, Result.call(reply)})
    state
  end

  defp answer(:list, _id, {:ok, %{"tools" => tools} = result}, state) when is_list(tools),
    do: page(state, tools, result["nextCursor"])

  defp answer(:list, _id, {:ok, _result}, state),
    do: fail(state, "tools/list: an answer with no list of tools")

  defp answer(:list, _id, {:error, text}, state), do: fail(state, "tools/list: " <> text)

  # Listing

  # The first listing: the start timer ends it, so it holds no timer of its
  # own.
  defp list(state) do
    state = %{state | list: %{pages: 0, tools: []}, listed_at: now()}
    request_page(state, nil)
  end

  # A change: a listing at once, or one queued after the running one, at
  # least `@list_gap_ms` after the start of the last; more changes fold
  # into the queued one.
  # A change before the first listing starts is in that listing.
  defp changed(%{listed_at: nil} = state), do: state

  defp changed(%{list: nil, queued?: false} = state) do
    wait = state.listed_at + @list_gap_ms - now()

    if wait <= 0,
      do: start_list(state, now() + state.wait_ms),
      else: queue(state, wait)
  end

  defp changed(state), do: %{state | queued?: true}

  defp queue(state, wait) do
    Process.send_after(self(), :relist, wait)
    %{state | queued?: true}
  end

  defp relist(%{list: nil} = state),
    do: start_list(%{state | queued?: false}, now() + state.wait_ms)

  defp relist(state), do: state

  defp start_list(state, deadline) do
    ref = make_ref()
    Process.send_after(self(), {:list_timeout, ref}, max(deadline - now(), 0))
    state = %{state | list: %{ref: ref, pages: 0, tools: []}, listed_at: now()}
    request_page(state, nil)
  end

  defp request_page(state, cursor) do
    params = if cursor, do: %{cursor: cursor}, else: %{}
    {id, state} = request(state, "tools/list", params)
    %{state | pending: Map.put(state.pending, id, :list)}
  end

  defp page(state, tools, cursor) do
    list = %{state.list | pages: state.list.pages + 1, tools: state.list.tools ++ tools}
    state = %{state | list: list}

    cond do
      cursor == nil -> listed(state)
      not is_binary(cursor) -> fail(state, "tools/list: a nextCursor that is not a string")
      list.pages >= @max_pages -> fail(state, "tools/list has more than #{@max_pages} pages")
      true -> request_page(state, cursor)
    end
  end

  defp listed(state) do
    {entries, names, notices} = Listing.entries(state.config.name, state.list.tools)
    send(state.source, {:listed, self(), entries, notices})
    state = %{state | list: nil, names: names, phase: :serving}

    if state.queued?,
      do: queue(state, max(state.listed_at + @list_gap_ms - now(), 0)),
      else: state
  end

  # Calls

  # A call runs until the deadline of its call Task. The server Task
  # monitors that Task: an abort that kills it ends the call as a time
  # limit does.
  defp call(state, {pid, ref} = from, name, args, deadline) do
    case Map.fetch(state.names, name) do
      {:ok, mcp_name} ->
        {id, state} = request(state, "tools/call", %{name: mcp_name, arguments: args})
        timer = Process.send_after(self(), {:call_timeout, id}, max(deadline - now(), 0))
        monitor = Process.monitor(pid)
        %{state | pending: Map.put(state.pending, id, {:call, from, timer, monitor})}

      :error ->
        send(pid, {ref, {:error, "the MCP server does not list #{name}"}})
        state
    end
  end

  # The answers already in the mailbox go first: a call that the server
  # answered by its deadline is not cancelled.
  defp call_timeout(state, id) do
    state = drain(state)

    case Map.pop(state.pending, id) do
      {{:call, {pid, ref}, _timer, _monitor}, pending} ->
        text = "timed out after #{div(state.call_ms, 1000)} s; the call may have run"
        send(pid, {ref, {:error, text}})
        restart(%{state | pending: pending}, id)

      _other ->
        serve(state)
    end
  end

  defp drain(state) do
    port = state.port

    receive do
      {^port, {:data, data}} -> state |> data(data) |> drain()
    after
      0 -> state
    end
  end

  defp caller_down(state, monitor) do
    case Enum.find(state.pending, &match?({_id, {:call, _from, _timer, ^monitor}}, &1)) do
      {id, {:call, _from, timer, _monitor}} ->
        Process.cancel_timer(timer)
        restart(%{state | pending: Map.delete(state.pending, id)}, id)

      nil ->
        state
    end
  end

  # The server exited. With a call whose Task is gone, an abort's release
  # stopped it: that call ended with no response, as at a time limit.
  @spec exited(%__MODULE__{}) :: no_return()
  defp exited(state) do
    gone =
      for {id, {:call, {pid, _ref}, _timer, _monitor}} <- state.pending,
          not Process.alive?(pid),
          do: id

    case gone do
      [] -> fail(state, "the server exited")
      [id | _more] -> restart(state, id)
    end
  end

  # A call ended with no response (decision 14): MCP gives no confirmation
  # that a cancelled request stopped, so the server stops, and the source
  # starts a new one after the hands released this Task's groups. The
  # source learns it first: the write of the cancel can end this Task with
  # the port's `:epipe`.
  defp restart(state, id) do
    for {_id, {:call, {pid, ref}, _timer, _monitor}} <- state.pending,
        do:
          send(
            pid,
            {ref, {:error, "the MCP server restarts: another call ended with no response"}}
          )

    send(state.source, {:restart, self()})

    send_json(state, %{
      jsonrpc: "2.0",
      method: "notifications/cancelled",
      params: %{requestId: id, reason: "the call ended with no response"}
    })

    Launch.shutdown(state.port)
    exit(:normal)
  end

  # Output

  defp request(state, method, params) do
    id = state.next_id
    send_json(state, %{jsonrpc: "2.0", id: id, method: method, params: params})
    {id, %{state | next_id: id + 1}}
  end

  defp notify(state, method), do: send_json(state, %{jsonrpc: "2.0", method: method})

  # JSON escapes every control character, so no line holds a raw NUL,
  # which would end the server's input (`Helyx.Watchdog`).
  defp send_json(state, message),
    do: Helyx.Watchdog.write(state.port, [JSON.encode!(message), "\n"])

  # The open calls get an error result; the source learns the failure, and
  # the Task ends.
  defp fail(state, text) do
    for {_id, {:call, {pid, ref}, _timer, _monitor}} <- state.pending,
        do: send(pid, {ref, {:error, "the MCP server ended during the call: " <> text}})

    send(state.source, {:failed, self(), text})
    exit(:normal)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
