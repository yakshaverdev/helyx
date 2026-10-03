defmodule Mix.Tasks.Helyx.Graph do
  @shortdoc "Prints the call graph, or a trace of one turn"
  @moduledoc """
  Prints how the project fits together, for a person or an agent to read.

      mix helyx.graph calls [Module ...] [--mermaid]
      mix helyx.graph turn

  `calls` prints every function call from one project function to another,
  one `caller -> callee` line each, read from the compiled code with OTP
  `:xref`. A module argument keeps only the lines where that module calls or
  is called. `--mermaid` prints a Mermaid flowchart instead. The graph stops
  at process boundaries: a `GenServer.call` shows as a call to the client
  function, not to the process that answers it.

  `turn` runs one scripted turn with the fake provider and the read tool in
  a temporary directory, traces it, and prints a Mermaid sequence diagram.
  A participant is a process, named after the first project module it runs.
  An arrow is a message between two of them, and a note is a project
  function the process called. It crosses the process boundaries that
  `calls` cannot. No session file is written.
  """

  use Mix.Task

  # :xref is in the OTP :tools app, which only this task loads, at run time.
  @compile {:no_warn_undefined, :xref}
  @dialyzer {:nowarn_function, calls: 2}

  @apps [:helyx, :helyx_plugins, :coding_agent]
  @core :helyx_graph
  @turn_timeout_ms 10_000
  @callbacks [:init, :handle_call, :handle_cast, :handle_info, :handle_continue]

  @impl true
  def run(argv) do
    {opts, args} =
      try do
        OptionParser.parse!(argv, strict: [mermaid: :boolean])
      rescue
        error in OptionParser.ParseError -> Mix.raise(Exception.message(error))
      end

    case args do
      ["calls" | modules] ->
        calls(Enum.map(modules, &Module.concat([&1])), Keyword.get(opts, :mermaid, false))

      ["turn"] ->
        turn()

      _ ->
        Mix.raise("usage: mix helyx.graph calls [Module ...] [--mermaid] | mix helyx.graph turn")
    end
  end

  defp calls(filter, mermaid?) do
    Mix.Task.run("compile")
    Mix.ensure_application!(:tools)
    project = MapSet.new(project_modules())
    {:ok, xref} = :xref.start(:"helyx_graph_#{System.unique_integer([:positive])}")

    try do
      :xref.set_default(xref, warnings: false, verbose: false)

      for app <- @apps,
          do: {:ok, _} = :xref.add_directory(xref, to_charlist(Application.app_dir(app, "ebin")))

      {:ok, edges} = :xref.q(xref, ~c"E")

      edges
      |> Enum.filter(fn {{m1, f1, _}, {m2, f2, _}} ->
        m1 in project and m2 in project and source?(f1) and source?(f2) and
          (filter == [] or m1 in filter or m2 in filter)
      end)
      |> Enum.map(fn {from, to} -> {mfa(from), mfa(to)} end)
      |> Enum.sort()
      |> Enum.uniq()
      |> print_calls(mermaid?)
    after
      :xref.stop(xref)
    end
  end

  defp print_calls(edges, false) do
    Enum.each(edges, fn {from, to} -> IO.puts("#{from} -> #{to}") end)
  end

  defp print_calls(edges, true) do
    ids =
      edges
      |> Enum.flat_map(&Tuple.to_list/1)
      |> Enum.uniq()
      |> Enum.with_index(fn name, i -> {name, "n#{i}"} end)
      |> Map.new()

    IO.puts("flowchart LR")
    Enum.each(ids, fn {name, id} -> IO.puts(~s(  #{id}["#{name}"])) end)
    Enum.each(edges, fn {from, to} -> IO.puts("  #{ids[from]} --> #{ids[to]}") end)
  end

  defp turn do
    Mix.Task.run("app.start")
    modules = project_modules() -- [__MODULE__]
    Enum.each(modules, &Code.ensure_loaded!/1)
    dir = Path.join(System.tmp_dir!(), "helyx_graph_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hello.txt"), "hello\n")
    {:ok, core} = Helyx.Core.start_link(name: @core, plugins: CodingAgent.plugins())
    call = %Helyx.Message.ToolCall{id: "c1", name: "read", arguments: %{"path" => "hello.txt"}}
    :ok = Helyx.Provider.Fake.script(@core, "graph", [["Reading.", call], ["Done."]])
    tracer = spawn_link(fn -> collect([]) end)
    flags = [:call, :arity, :send, :strict_monotonic_timestamp, {:tracer, tracer}]

    # Core starts before the trace, so its startup stays out of the diagram,
    # and :all reaches its processes too.
    try do
      :erlang.trace(:all, true, flags)
      :erlang.trace(tracer, false, [:all])
      Enum.each(modules, &:erlang.trace_pattern({&1, :_, :_}, true, [:local]))
      run_turn(dir)
    after
      :erlang.trace(:all, false, [:all])
      :erlang.trace_pattern({:_, :_, :_}, false, [:local])
      Process.put(:helyx_graph_registered, registered())
      Supervisor.stop(core)
      File.rm_rf!(dir)
    end

    # Trace messages already sent must reach the tracer before it stops.
    ref = :erlang.trace_delivered(:all)
    receive do: ({:trace_delivered, :all, ^ref} -> :ok)
    send(tracer, {:done, self()})
    events = receive do: ({:events, events} -> events)
    registered = Process.delete(:helyx_graph_registered)
    events |> Enum.sort_by(&elem(&1, 0)) |> print_turn(self(), registered)
  end

  # Taken while Core runs, since its processes are gone when the diagram is made.
  defp registered do
    for name <- Process.registered(),
        pid = Process.whereis(name),
        into: %{},
        do: {pid, name |> Atom.to_string() |> String.replace_prefix("Elixir.", "")}
  end

  defp run_turn(dir) do
    {:ok, session} = Helyx.Session.start(@core, model: "fake/graph", cwd: dir)
    {:ok, _, _} = Helyx.Session.subscribe(session)
    :ok = Helyx.Session.prompt(session, "read hello.txt")

    receive do
      {:helyx_event, %Helyx.Event{type: :turn_end}} -> :ok
    after
      @turn_timeout_ms -> Mix.raise("the traced turn did not end in #{@turn_timeout_ms} ms")
    end
  end

  defp collect(events) do
    receive do
      {:trace_ts, pid, :call, mfa, ts} -> collect([{ts, pid, {:call, mfa}} | events])
      {:trace_ts, pid, :send, msg, to, ts} -> collect([{ts, pid, {:send, msg, to}} | events])
      {:done, from} -> send(from, {:events, events})
      _ -> collect(events)
    end
  end

  defp print_turn(events, caller, registered) do
    ids = participants(events, caller, registered)
    IO.puts("sequenceDiagram")

    ids
    |> Enum.sort_by(fn {_, {id, _}} -> id end)
    |> Enum.each(fn {_, {id, name}} -> IO.puts("  participant p#{id} as #{name}") end)

    # A note prints a function once per process between two of its messages,
    # so a loop or a repeated check does not flood the diagram.
    _seen =
      Enum.reduce(events, %{}, fn
        {_, pid, {:call, {_, f, _} = call}}, seen when is_map_key(ids, pid) ->
          if source?(f) and not MapSet.member?(Map.get(seen, pid, MapSet.new()), call) do
            IO.puts("  Note over p#{elem(ids[pid], 0)}: #{mfa(call)}")
            Map.update(seen, pid, MapSet.new([call]), &MapSet.put(&1, call))
          else
            seen
          end

        {_, pid, {:send, msg, to}}, seen when is_map_key(ids, pid) and is_map_key(ids, to) ->
          IO.puts("  p#{elem(ids[pid], 0)}->>p#{elem(ids[to], 0)}: #{label(msg)}")
          Map.drop(seen, [pid, to])

        _, seen ->
          seen
      end)

    :ok
  end

  # A process that ran project code is a participant, numbered in order of
  # its first event. It is named by its registered name, else by the module
  # of its first OTP callback, else as a task of the module whose function it
  # ran first, which for a Task is the module that defines the Task's function.
  defp participants(events, caller, registered) do
    calls = for {_, pid, {:call, {m, f, _}}} <- events, do: {pid, m, f}
    first = calls |> Enum.reverse() |> Map.new(fn {pid, m, _} -> {pid, "#{inspect(m)} task"} end)

    callback =
      for {pid, m, f} <- Enum.reverse(calls), f in @callbacks, into: %{}, do: {pid, inspect(m)}

    names =
      first
      |> Map.merge(callback)
      |> Map.merge(Map.take(registered, Map.keys(first)))
      |> Map.put(caller, "caller")

    events
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(names, &1))
    |> Enum.with_index()
    |> Enum.map_reduce(%{}, fn {pid, id}, counts ->
      name = names[pid]
      n = Map.get(counts, name, 0) + 1
      shown = if n == 1, do: name, else: "#{name} (#{n})"
      {{pid, {id, shown}}, Map.put(counts, name, n)}
    end)
    |> elem(0)
    |> Map.new()
  end

  defp label({:"$gen_call", _from, request}), do: "call " <> tag(request)
  defp label({:"$gen_cast", request}), do: "cast " <> tag(request)
  defp label({:helyx_event, %Helyx.Event{type: type}}), do: "event #{type}"
  defp label({ref, _reply}) when is_reference(ref), do: "reply"
  defp label({[:alias | ref], _reply}) when is_reference(ref), do: "reply"
  defp label(message), do: tag(message)

  defp tag(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp tag(tuple) when tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)), do: tag(elem(tuple, 0))
  defp tag(_), do: "message"

  defp project_modules do
    Enum.flat_map(@apps, fn app ->
      Application.load(app)
      Application.spec(app, :modules) || []
    end)
  end

  # Compiler-generated functions (`__info__/1`, `-fun-0-`) are not in the source.
  defp source?(f), do: not String.starts_with?(Atom.to_string(f), ["__", "-"])

  defp mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
end
