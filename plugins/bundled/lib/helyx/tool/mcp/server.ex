defmodule Helyx.Tool.MCP.Server do
  @moduledoc false
  # The server Task of one MCP server (`docs/features/mcp-client.md`,
  # "Helyx.Tool.MCP"): it starts the server under `Helyx.Watchdog` with the
  # start deadline, owns its port, and speaks JSON-RPC 2.0 lines on its
  # stdio: `initialize`, `notifications/initialized`, `tools/list` with its
  # pages, then calls, the answers to the server's requests, and a listing
  # again at each `notifications/tools/list_changed`. It sends its source
  # `{:listed, pid, entries, notices}` for each listing, and
  # `{:failed, pid, text}` before it ends on a failure. A failure ends only
  # this Task; the hands release its groups (decision 15).

  alias Helyx.Tool.MCP.{Config, Result}

  @protocol "2025-06-18"
  @versions ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
  # A line from the server, as `Helyx.HarnessIO`: past it the client cannot
  # tell which request the line answers.
  @max_line_bytes 16 * 1024 * 1024
  @max_pages 16
  @max_tools 256
  @max_description_bytes 4_096
  @call_ms 60_000
  # The least time from the start of one listing to the next.
  @list_gap_ms 1_000
  # The variables of the node that a server gets (decision 12).
  @keep ~w(HOME LOGNAME PATH SHELL TERM USER TMPDIR LANG)

  defstruct [
    :config,
    :source,
    :port,
    :wait_ms,
    buffer: [],
    buffered: 0,
    next_id: 1,
    pending: %{},
    list: nil,
    queued?: false,
    listed_at: nil,
    names: %{}
  ]

  # The whole life of the server: start, handshake, listing, then serve.
  # `opts`: `:wait_ms`, the bound of a start and of a listing;
  # `:watchdog_exe`, for tests.
  def run(%Config{} = config, source, cwd, deadline, opts) do
    state = %__MODULE__{config: config, source: source, wait_ms: Keyword.fetch!(opts, :wait_ms)}

    case Helyx.Watchdog.start(argv(config), cwd, :open, start_opts(config, deadline, opts)) do
      {:started, port, _pre, _handles} -> handshake(%{state | port: port}, deadline)
      {:error, reason} -> fail(state, "did not start: " <> reason)
    end
  end

  defp argv(config),
    do: ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), config.command | config.args]

  # The server gets the variables of `@keep` of the node and the `env` of
  # its config; every other variable of the node is unset for it.
  defp start_opts(config, deadline, opts) do
    unset = for {name, _value} <- System.get_env(), name not in @keep, do: name
    unset = Enum.reject(unset, &Map.has_key?(config.env, &1))
    exe = for {:watchdog_exe, exe} <- opts, do: {:watchdog_exe, exe}
    [env: Map.to_list(config.env), unset: unset, deadline: deadline] ++ exe
  end

  defp handshake(state, deadline) do
    params = %{
      protocolVersion: @protocol,
      capabilities: %{},
      clientInfo: %{name: "helyx", version: "1"}
    }

    {id, state} = request(state, "initialize", params)

    case await(state, id, deadline) do
      {{:ok, %{"protocolVersion" => version}}, state} when version in @versions ->
        notify(state, "notifications/initialized")
        state |> list(deadline) |> serve()

      {{:ok, _result}, state} ->
        fail(state, "initialize: a protocol version that Helyx does not speak")

      {{:error, text}, state} ->
        fail(state, "initialize: " <> text)
    end
  end

  # Waits for the answer to `id` before `deadline`, and handles every other
  # line on the way. Only the start waits so: no call can come before the
  # first listing.
  defp await(state, id, deadline) do
    case Map.pop(state.pending, {:await, id}) do
      {nil, _pending} ->
        receive do
          {port, {:data, data}} when port == state.port ->
            state |> data(data) |> await(id, deadline)

          {port, {:exit_status, _status}} when port == state.port ->
            fail(state, "the server exited")
        after
          max(deadline - now(), 0) ->
            fail(state, "did not start in #{div(state.wait_ms, 1000)} s")
        end

      {answer, pending} ->
        {answer, %{state | pending: pending}}
    end
  end

  defp serve(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        state |> data(data) |> serve()

      {port, {:exit_status, _status}} when port == state.port ->
        fail(state, "the server exited")

      {:call, from, name, args} ->
        state |> call(from, name, args) |> serve()

      {:call_timeout, id} ->
        state |> call_timeout(id) |> serve()

      :relist ->
        state |> relist() |> serve()

      {:list_timeout, ref} when state.list != nil and state.list.ref == ref ->
        fail(state, "a listing of tools did not end in #{div(state.wait_ms, 1000)} s")

      _other ->
        serve(state)
    end
  end

  # Lines

  # Only the new chunk is searched for a line end; the part of a line
  # before it waits as iodata, so a long line costs its length once.
  defp data(state, data) do
    case :binary.split(data, "\n", [:global]) do
      [part] ->
        buffered(%{
          state
          | buffer: [state.buffer | part],
            buffered: state.buffered + byte_size(part)
        })

      [first | more] ->
        {lines, [rest]} = Enum.split(more, -1)
        first = IO.iodata_to_binary([state.buffer | first])
        state = buffered(%{state | buffer: rest, buffered: byte_size(rest)})
        Enum.reduce([first | lines], state, &line/2)
    end
  end

  defp buffered(%{buffered: size} = state) when size > @max_line_bytes, do: too_long(state)
  defp buffered(state), do: state

  defp too_long(state), do: fail(state, "a line over #{@max_line_bytes} bytes")

  # A line that is not a JSON object is skipped, as `Helyx.HarnessIO` does.
  defp line(text, state) when byte_size(text) > @max_line_bytes, do: too_long(state)

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
          error: %{code: -32601, message: "Method not found"}
        })

    state
  end

  defp message(%{"method" => "notifications/tools/list_changed"}, state), do: changed(state)
  defp message(%{"method" => method}, state) when is_binary(method), do: state

  defp message(%{"id" => id} = message, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} -> state
      {kind, pending} -> answer(kind, id, reply(message), %{state | pending: pending})
    end
  end

  defp message(_message, state), do: state

  defp reply(%{"result" => result}), do: {:ok, result}

  defp reply(%{"error" => %{"message" => text}}) when is_binary(text),
    do: {:error, Helyx.Text.cap(text, 2_000, :head)}

  defp reply(_message), do: {:error, "an answer with no result"}

  defp answer(:await, id, reply, state), do: put_in(state.pending[{:await, id}], reply)

  defp answer({:call, {pid, ref}, timer}, _id, reply, state) do
    Process.cancel_timer(timer)

    result =
      case reply do
        {:ok, result} -> Result.text(result)
        {:error, text} -> {:error, "the MCP server answered an error: " <> text}
      end

    send(pid, {ref, result})
    state
  end

  defp answer(:list, _id, {:ok, %{"tools" => tools} = result}, state) when is_list(tools),
    do: page(state, tools, result["nextCursor"])

  defp answer(:list, _id, {:ok, _result}, state),
    do: fail(state, "tools/list: an answer with no list of tools")

  defp answer(:list, _id, {:error, text}, state), do: fail(state, "tools/list: " <> text)

  # Listing

  # The first listing, inside the start deadline.
  defp list(state, deadline) do
    state = start_list(state, deadline)
    wait_list(state, deadline)
  end

  defp wait_list(%{list: nil} = state, _deadline), do: state

  defp wait_list(state, deadline) do
    receive do
      {port, {:data, data}} when port == state.port ->
        state |> data(data) |> wait_list(deadline)

      {port, {:exit_status, _status}} when port == state.port ->
        fail(state, "the server exited")
    after
      max(deadline - now(), 0) -> fail(state, "did not start in #{div(state.wait_ms, 1000)} s")
    end
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
    {entries, names, notices} = entries(state.config.name, state.list.tools)
    send(state.source, {:listed, self(), entries, notices})
    state = %{state | list: nil, names: names}

    if state.queued?,
      do: queue(state, max(state.listed_at + @list_gap_ms - now(), 0)),
      else: state
  end

  # The tools of a listing as entries, deferred: task-only tools left out,
  # the first 256 by MCP name order. Two MCP names that map to one Helyx
  # name both go to Core, which keeps the first with a notice (decision 8);
  # a call of that name goes to the first.
  defp entries(server, tools) do
    tools = for %{"name" => name} = tool when is_binary(name) <- tools, do: tool

    {tasks, tools} =
      Enum.split_with(tools, &match?(%{"execution" => %{"taskSupport" => "required"}}, &1))

    {kept, over} = tools |> Enum.sort_by(& &1["name"]) |> Enum.split(@max_tools)

    named = Enum.map(kept, &{Config.tool_name(server, &1["name"]), &1})

    entries =
      for {name, tool} <- named do
        %{
          name: name,
          description: description(tool["description"]),
          parameters: if(is_map(tool["inputSchema"]), do: tool["inputSchema"], else: %{}),
          exposure: :deferred
        }
      end

    notices =
      for {count, why} <- [
            {length(tasks), "they need tasks"},
            {length(over), "past #{@max_tools} tools"}
          ],
          count > 0,
          do: "MCP server #{server}: #{count} tools were left out: #{why}"

    names =
      named |> Enum.uniq_by(&elem(&1, 0)) |> Map.new(fn {name, tool} -> {name, tool["name"]} end)

    {entries, names, notices}
  end

  # A description at most 4,096 bytes, cut at a character boundary.
  defp description(text) when is_binary(text),
    do:
      text
      |> binary_part(0, min(byte_size(text), @max_description_bytes))
      |> String.replace_invalid("")

  defp description(_text), do: ""

  # Calls

  defp call(state, {pid, ref} = from, name, args) do
    case Map.fetch(state.names, name) do
      {:ok, mcp_name} ->
        {id, state} = request(state, "tools/call", %{name: mcp_name, arguments: args})
        timer = Process.send_after(self(), {:call_timeout, id}, @call_ms)
        %{state | pending: Map.put(state.pending, id, {:call, from, timer})}

      :error ->
        send(pid, {ref, {:error, "the MCP server does not list #{name}"}})
        state
    end
  end

  defp call_timeout(state, id) do
    case Map.pop(state.pending, id) do
      {{:call, {pid, ref}, _timer}, pending} ->
        text = "timed out after #{div(@call_ms, 1000)} s; the call may have run"
        send(pid, {ref, {:error, text}})
        %{state | pending: pending}

      _other ->
        state
    end
  end

  # Output

  defp request(state, method, params) do
    id = state.next_id
    send_json(state, %{jsonrpc: "2.0", id: id, method: method, params: params})

    pending =
      if method == "initialize", do: Map.put(state.pending, id, :await), else: state.pending

    {id, %{state | next_id: id + 1, pending: pending}}
  end

  defp notify(state, method), do: send_json(state, %{jsonrpc: "2.0", method: method})

  # JSON escapes every control character, so no line holds a raw NUL,
  # which would end the server's input (`Helyx.Watchdog`).
  defp send_json(state, message),
    do: Helyx.Watchdog.write(state.port, [JSON.encode!(message), "\n"])

  # The open calls get an error result; the source learns the failure, and
  # the Task ends.
  defp fail(state, text) do
    for {_id, {:call, {pid, ref}, _timer}} <- state.pending,
        do: send(pid, {ref, {:error, "the MCP server ended during the call: " <> text}})

    send(state.source, {:failed, self(), text})
    exit(:normal)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
