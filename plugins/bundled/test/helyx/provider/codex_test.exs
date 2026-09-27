defmodule Helyx.Provider.CodexTest do
  # A fake `codex` on PATH speaks the JSON-RPC lines of `codex app-server`
  # in the shapes that `docs/research/codex-app-server.md` records. Run N
  # saves its arguments to `args.N` and each line it reads to `stdin.N`;
  # for the K-th request or notification of method M it runs `on.N.M.K`,
  # or else `on.N.M` (M with `/` as `_`), which prints the canned answer.
  # It exits at the end of its input. PATH is global, so this module is not
  # async.
  use ExUnit.Case, async: false

  import Helyx.Test.OSHelpers

  alias Helyx.{Event, HarnessIO, Message, Session}
  alias Helyx.Provider.{Codex, Fake}

  @tid "019a0000-0000-7000-8000-000000000001"
  @fresh "019a0000-0000-7000-8000-000000000002"

  @fake """
  #!/bin/sh
  d=$(dirname "$0")
  n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
  echo $n > "$d/count"
  for a in "$@"; do printf '%s\\n' "$a"; done > "$d/args.$n"
  while IFS= read -r line; do
    printf '%s\\n' "$line" >> "$d/stdin.$n"
    m=$(printf '%s\\n' "$line" | perl -MJSON::PP -ne 'print decode_json($_)->{method} // ""' | tr / _)
    if [ -n "$m" ]; then
      k=$(( $(cat "$d/count.$n.$m" 2>/dev/null || echo 0) + 1 ))
      echo $k > "$d/count.$n.$m"
      if [ -f "$d/on.$n.$m.$k" ]; then . "$d/on.$n.$m.$k"
      elif [ -f "$d/on.$n.$m" ]; then . "$d/on.$n.$m"; fi
    fi
  done
  """

  setup %{tmp_dir: tmp} do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "codex"), @fake)
    File.chmod!(Path.join(bin, "codex"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Codex, Fake]})
    work = Path.join(tmp, "work")
    File.mkdir_p!(work)
    %{core: core, bin: bin, work: work, sessions: Path.join(tmp, "sessions")}
  end

  # Protocol lines

  defp j(map), do: JSON.encode!(map)

  defp note(tid, method, params),
    do: j(%{method: method, params: Map.put(params, :threadId, tid), emittedAtMs: 1})

  defp thread(tid), do: %{id: tid, cwd: "/work", model: "gpt-6-luna", path: "/r.jsonl"}

  defp delta(tid, item, text),
    do: note(tid, "item/agentMessage/delta", %{turnId: "turn1", itemId: item, delta: text})

  defp started(tid, item), do: note(tid, "item/started", %{turnId: "turn1", item: item})
  defp completed(tid, item), do: note(tid, "item/completed", %{turnId: "turn1", item: item})

  defp message(tid, id, text) do
    item = %{type: "agentMessage", id: id, phase: "final_answer"}

    [
      started(tid, Map.put(item, :text, "")),
      delta(tid, id, text),
      completed(tid, Map.put(item, :text, text))
    ]
  end

  defp command(id, fields),
    do:
      Map.merge(
        %{type: "commandExecution", id: id, command: "/bin/zsh -lc ls", cwd: "/work"},
        fields
      )

  defp usage(tid) do
    note(tid, "thread/tokenUsage/updated", %{
      turnId: "turn1",
      tokenUsage: %{last: %{inputTokens: 12, outputTokens: 7}, total: %{inputTokens: 12}}
    })
  end

  defp turn_end(tid, status, error \\ nil) do
    note(tid, "turn/completed", %{
      turn: %{id: "turn1", items: [], status: status, error: error && %{message: error}}
    })
  end

  # A turn: the turn/start answer, then `lines`.
  defp turn(tid, lines) do
    [
      j(%{id: 5, result: %{turn: %{id: "turn1", status: "inProgress"}}}),
      note(tid, "turn/started", %{turn: %{id: "turn1", status: "inProgress"}}) | lines
    ]
  end

  # The same lines as the program's turn `id`.
  defp as_turn(lines, id), do: Enum.map(lines, &String.replace(&1, ~s("turn1"), ~s("#{id}")))

  # Writes the answer of run `n` to `method`: `lines`, then `tail` as shell
  # code. With `k`, only to its `k`-th request.
  defp on(bin, n, method, lines, tail \\ "", k \\ nil) do
    name = String.replace(method, "/", "_") <> if(k, do: ".#{k}", else: "")
    File.write!(Path.join(bin, "out.#{n}.#{name}"), Enum.map(lines, &[&1, "\n"]))
    File.write!(Path.join(bin, "on.#{n}.#{name}"), ~s(cat "$d/out.#{n}.#{name}"\n) <> tail)
  end

  defp initialize(bin, n),
    do: on(bin, n, "initialize", [j(%{id: 1, result: %{userAgent: "fake", platformOs: "macos"}})])

  # A run that starts thread `tid`, takes the replay, and runs `lines` as
  # its turn.
  defp fresh(bin, n, tid, lines, tail \\ "") do
    initialize(bin, n)

    on(bin, n, "thread/start", [
      j(%{id: 3, result: %{thread: thread(tid)}}),
      j(%{method: "thread/started", params: %{thread: thread(tid)}})
    ])

    on(bin, n, "thread/inject_items", [j(%{id: 4, result: %{}})])
    on(bin, n, "turn/start", turn(tid, lines), tail)
  end

  defp resumed(bin, n, tid, lines) do
    initialize(bin, n)
    on(bin, n, "thread/resume", [j(%{id: 2, result: %{thread: thread(tid)}})])
    on(bin, n, "turn/start", turn(tid, lines))
  end

  defp reply(tid, text),
    do: message(tid, "msg_1", text) ++ [usage(tid), turn_end(tid, "completed")]

  defp stdin(bin, n) do
    bin
    |> Path.join("stdin.#{n}")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp request(bin, n, method), do: Enum.find(stdin(bin, n), &(&1["method"] == method))
  defp runs(bin), do: bin |> Path.join("count") |> File.read!() |> String.trim()

  defp collect_until(type, acc \\ []) do
    receive do
      {:helyx_event, %Event{type: ^type} = event} -> Enum.reverse([event | acc])
      {:helyx_event, %Event{} = event} -> collect_until(type, [event | acc])
    after
      5_000 -> flunk("timed out waiting for #{type}; got #{inspect(Enum.reverse(acc))}")
    end
  end

  defp start(ctx, model \\ "codex/gpt-6-luna") do
    {:ok, session} =
      Session.start(ctx.core, model: model, cwd: ctx.work, sessions_dir: ctx.sessions)

    {:ok, _} = Session.subscribe(session)
    session
  end

  defp prompt(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:agent_end)
  end

  defp messages(events), do: for(%Event{type: :message_end, data: %{message: m}} <- events, do: m)
  defp of_type(events, type), do: for(%Event{type: ^type, data: data} <- events, do: data)

  # The callbacks, driven in the test process as the harness loop drives
  # them, without Core. `Helyx.Tool.hold/1` does nothing here.

  # Shell code that writes `lines` to stdout in the background once the
  # test calls `go/1`.
  defp after_go(bin, name, lines) do
    File.write!(Path.join(bin, name), Enum.join(lines, "\n") <> "\n")
    ~s{(while [ ! -f "$d/go" ]; do sleep 0.02; done; cat "$d/#{name}") &\n}
  end

  defp go(bin), do: File.write!(Path.join(bin, "go"), "")

  defp connect(work, opts \\ []), do: Codex.harness_init("m", [], [cwd: work] ++ opts)

  defp ask(state, request) do
    from = make_ref()
    {:ok, actions, state} = Codex.harness_request(request, from, state)
    {from, actions, state}
  end

  # Gives the test process's messages to `harness_info/2` until `done?`
  # holds for the actions so far. A stop is the last action,
  # `{:stop, reason}`.
  defp drive(state, actions, done?) do
    if done?.(actions) do
      {actions, state}
    else
      receive do
        message ->
          case Codex.harness_info(message, state) do
            {:ok, more, state} -> drive(state, actions ++ more, done?)
            {:stop, reason, state} -> {actions ++ [{:stop, reason}], state}
          end
      after
        5_000 -> flunk("no end; got #{inspect(actions)}")
      end
    end
  end

  defp turn_ended?(actions) do
    Enum.any?(actions, fn
      {:event, _turn_id, {kind, _}} -> kind in [:done, :error]
      _action -> false
    end)
  end

  defp replied?(from), do: &Enum.any?(&1, fn action -> match?({:reply, ^from, _}, action) end)

  defp events(actions),
    do: for({:event, "t1", event} <- actions, do: event) ++ for({:stop, _} = s <- actions, do: s)

  # Runs one turn on a new program, and gives its events, then the stop, if
  # any.
  defp run_direct(messages, work) do
    {:ok, state} = connect(work)
    {_from, actions, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: messages}})
    {actions, state} = drive(state, actions, &turn_ended?/1)
    if not match?({:stop, _}, List.last(actions)), do: close(state)
    events(actions)
  end

  # Ends the program, so it has read every line that it was sent.
  defp close(state) do
    {from, [], state} = ask(state, :close)
    assert {[{:reply, ^from, :ok}], _state} = drive(state, [], replied?(from))
  end

  @moduletag :tmp_dir

  @done %{status: "completed", aggregatedOutput: "out", exitCode: 0}

  # The setup restores PATH.
  test "with no perl on PATH, the connect returns an error that names perl",
       %{bin: bin, work: work} do
    System.put_env("PATH", bin)
    assert {:error, "perl not found" <> _} = connect(work)
  end

  # The setup restores PATH.
  test "a perl that ends with no output fails the connect with an error that names perl",
       %{bin: bin, work: work} do
    File.write!(Path.join(bin, "perl"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin, "perl"), 0o755)
    System.put_env("PATH", bin)

    assert {:error, {:not_started, "the perl watchdog gave no marker: "}} = connect(work)
  end

  # The setup restores PATH. `Helyx.HarnessIO.cap_error/1` drops the invalid
  # byte, so the error is valid UTF-8 for every reader, the model too.
  test "a perl that writes an invalid byte and ends gives valid text that names perl",
       %{bin: bin, work: work} do
    File.write!(Path.join(bin, "perl"), "#!/bin/sh\nprintf 'bad \\351 byte'\nexit 1\n")
    File.chmod!(Path.join(bin, "perl"), 0o755)
    System.put_env("PATH", bin)

    assert {:error, {:not_started, "the perl watchdog gave no marker: bad  byte"}} =
             connect(work)
  end

  test "a turn: text, tool calls, and tool results join the transcript, and the id is stored",
       %{bin: bin} = ctx do
    fresh(
      bin,
      1,
      @tid,
      message(@tid, "msg_a", "I will list.") ++
        [
          started(@tid, command("exec-1", %{status: "inProgress"})),
          # A sub-agent's thread stays inside the harness.
          delta("019a0000-0000-7000-8000-00000000000f", "msg_x", "not mine"),
          completed(
            @tid,
            command("exec-1", %{status: "completed", aggregatedOutput: "a.txt\n", exitCode: 0})
          )
        ] ++ reply(@tid, "One file.")
    )

    session = start(ctx)
    events = prompt(session, "list the files")

    assert %{"params" => %{"clientInfo" => %{"name" => "helyx"}}} =
             request(bin, 1, "initialize")

    assert %{"method" => "initialized"} = Enum.at(stdin(bin, 1), 1)

    assert %{
             "params" => %{
               "approvalPolicy" => "never",
               "sandbox" => "danger-full-access",
               "model" => "gpt-6-luna",
               "cwd" => cwd
             }
           } = request(bin, 1, "thread/start")

    assert cwd == ctx.work
    assert request(bin, 1, "thread/inject_items") == nil

    assert %{"params" => %{"threadId" => @tid, "input" => [%{"text" => "list the files"}]}} =
             request(bin, 1, "turn/start")

    assert ["app-server"] = bin |> Path.join("args.1") |> File.read!() |> String.split()

    assert [%{provider: "codex", harness_session_id: @tid, lost: false, cut: 0}] =
             of_type(events, :harness_session)

    call = %Message.ToolCall{
      id: "exec-1",
      name: "commandExecution",
      arguments: %{"command" => "/bin/zsh -lc ls", "cwd" => "/work"}
    }

    assert [
             %Message{role: :user},
             %Message{role: :assistant, stop_reason: :tool_use, model: "codex/gpt-6-luna"} =
               first,
             %Message{role: :assistant, stop_reason: :end_turn} = last
           ] = messages(events)

    assert first.content == [%Message.Text{text: "I will list."}, call]
    assert last.content == [%Message.Text{text: "One file."}]
    assert last.usage == %{"inputTokens" => 12, "outputTokens" => 7}

    assert [%{message: %Message{role: :tool_result, tool_call_id: "exec-1"} = result}] =
             of_type(events, :tool_execution_end)

    assert Message.text(result) == "a.txt\n"
    refute result.is_error
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)

    assert {:ok, %{harness_sessions: %{"codex" => {@tid, 1}}}} =
             Session.File.resume(ctx.sessions, ctx.work)
  end

  test "a later turn runs in the same program, and a resumed session resumes the thread",
       %{bin: bin} = ctx do
    fresh(bin, 1, @tid, reply(@tid, "Hi."))
    on(bin, 1, "turn/start", as_turn(turn(@tid, reply(@tid, "Again.")), "turn2"), "", 2)
    resumed(bin, 2, @tid, reply(@tid, "Back."))

    session = start(ctx)
    prompt(session, "hello")
    events = prompt(session, "again")

    # One program: no start, no resume, and only the prompt.
    assert runs(bin) == "1"
    assert request(bin, 1, "thread/resume") == nil

    assert [_, %{"params" => %{"threadId" => @tid, "input" => [%{"text" => "again"}]}}] =
             for(%{"method" => "turn/start"} = line <- stdin(bin, 1), do: line)

    assert of_type(events, :harness_session) == []

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Again."}]}] =
             messages(events)

    # The session end closes the program: its input ends, and it exits.
    GenServer.stop(Session.pid(session))
    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _} = Session.subscribe(session)
    prompt(session, "back")

    assert %{
             "params" => %{
               "threadId" => @tid,
               "excludeTurns" => true,
               "approvalPolicy" => "never",
               "sandbox" => "danger-full-access"
             }
           } = request(bin, 2, "thread/resume")

    assert request(bin, 2, "thread/start") == nil
    assert request(bin, 2, "thread/inject_items") == nil
    assert %{"params" => %{"input" => [%{"text" => "back"}]}} = request(bin, 2, "turn/start")
  end

  test "a lost thread starts a fresh one in the same program, with the transcript replayed",
       %{bin: bin} = ctx do
    fresh(bin, 1, @tid, reply(@tid, "Hi."))
    fresh(bin, 2, @fresh, reply(@fresh, "Fresh."))

    on(bin, 2, "thread/resume", [
      j(%{id: 2, error: %{code: -32_600, message: "no rollout found for thread id #{@tid}"}})
    ])

    session = start(ctx)
    prompt(session, "hello")
    GenServer.stop(Session.pid(session))
    {:ok, session} = Session.resume(ctx.core, sessions_dir: ctx.sessions, cwd: ctx.work)
    {:ok, _} = Session.subscribe(session)
    events = prompt(session, "again")

    assert runs(bin) == "2"
    assert %{"params" => %{"threadId" => @tid}} = request(bin, 2, "thread/resume")
    assert %{"params" => %{"model" => "gpt-6-luna"}} = request(bin, 2, "thread/start")

    assert %{
             "params" => %{
               "threadId" => @fresh,
               "items" => [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "hello"}]
                 },
                 %{
                   "type" => "message",
                   "role" => "assistant",
                   "content" => [%{"type" => "output_text", "text" => "Hi."}]
                 }
               ]
             }
           } = request(bin, 2, "thread/inject_items")

    assert %{"params" => %{"threadId" => @fresh, "input" => [%{"text" => "again"}]}} =
             request(bin, 2, "turn/start")

    assert [%{harness_session_id: @fresh, lost: true, cut: 0}] = of_type(events, :harness_session)

    assert [%Message{role: :user}, %Message{content: [%Message.Text{text: "Fresh."}]}] =
             messages(events)

    assert {:ok, %{harness_sessions: %{"codex" => {@fresh, 3}}}} =
             Session.File.resume(ctx.sessions, ctx.work)
  end

  test "a switch to a codex model replays the history, tool calls too", %{bin: bin} = ctx do
    long = String.duplicate("i", 65)

    calls = [
      %Message.ToolCall{id: "call:1", name: "read", arguments: %{"path" => "a"}},
      %Message.ToolCall{id: long, name: "mcp/srv.tool", arguments: %{}}
    ]

    :ok = Fake.script(ctx.core, "m", [calls, ["Read it."]])
    fresh(bin, 1, @tid, reply(@tid, "Done."))

    session = start(ctx, "fake/m")
    prompt(session, "read a")
    :ok = Session.set_model(session, "codex/gpt-6-luna")
    events = prompt(session, "and now?")

    assert request(bin, 1, "thread/resume") == nil

    assert %{
             "params" => %{
               "items" => [
                 %{"type" => "message", "role" => "user"},
                 %{"type" => "function_call"} = read,
                 %{"type" => "function_call"} = mcp,
                 %{"type" => "function_call_output"} = read_result,
                 %{"type" => "function_call_output"} = mcp_result,
                 %{"type" => "message", "role" => "assistant"}
               ]
             }
           } = request(bin, 1, "thread/inject_items")

    assert %{"name" => "read", "arguments" => ~s({"path":"a"}), "call_id" => "h_" <> _ = id} =
             read

    assert byte_size(id) == 64
    assert read_result["call_id"] == id
    assert %{"name" => "mcp_srv_tool", "call_id" => "h_" <> _ = long_id} = mcp
    assert byte_size(long_id) == 64 and long_id != id
    assert mcp_result["call_id"] == long_id
    assert is_binary(read_result["output"])
    assert [%{lost: false, cut: 0}] = of_type(events, :harness_session)
  end

  test "an abort during model output interrupts the turn, and the program serves the next one",
       %{bin: bin} = ctx do
    fresh(bin, 1, @tid, [delta(@tid, "msg_1", "thinking")])
    on(bin, 1, "turn/interrupt", [j(%{id: 6, result: %{}}), turn_end(@tid, "interrupted")])
    on(bin, 1, "turn/start", as_turn(turn(@tid, reply(@tid, "Next.")), "turn2"), "", 2)

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    :ok = Session.abort(session)

    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)

    assert %{"params" => %{"threadId" => @tid, "turnId" => "turn1"}} =
             request(bin, 1, "turn/interrupt")

    events = prompt(session, "next")
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
    assert runs(bin) == "1"
  end

  test "an abort during a command stops the program, and the next turn starts a new one",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    running = [started(@tid, command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, @tid, running, ~s{sleep 30 &\necho $! > "#{pidfile}"\n})
    on(bin, 1, "turn/interrupt", [j(%{id: 6, result: %{}}), turn_end(@tid, "interrupted")])

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    pid = wait_for_pid(pidfile)

    # The abort returns only when the program's group is gone.
    :ok = Session.abort(session)
    refute os_alive?(pid)
    assert request(bin, 1, "turn/interrupt") == nil

    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)

    # The turn made no message, so its thread is not resumed: the next
    # program starts a thread of its own, with both prompts.
    fresh(bin, 2, @fresh, reply(@fresh, "Back."))
    events = prompt(session, "back")
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
    assert runs(bin) == "2"
    assert request(bin, 2, "thread/resume") == nil

    assert %{
             "params" => %{
               "threadId" => @fresh,
               "input" => [%{"text" => "wait"}, %{"text" => "back"}]
             }
           } =
             request(bin, 2, "turn/start")
  end

  # Like codex: a command in a process group of its own, which the program
  # ends 3 s after the first TERM (the watchdog and the release each send
  # one); a KILL of the program's group would leave it running.
  defp own_group_command(pidfile, after_pid) do
    """
    perl -e 'setpgrp(0, 0); exec "sleep", "30"' </dev/null >/dev/null 2>&1 &
    c=$!
    trap 'trap "" TERM; sleep 3; kill -9 $c; exit 0' TERM
    echo $c > "#{pidfile}"
    #{after_pid}
    while :; do sleep 0.1; done
    """
  end

  test "an abort gives the program time to end its commands", %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    running = [started(@tid, command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, @tid, running, own_group_command(pidfile, ""))

    session = start(ctx)
    :ok = Session.prompt(session, "wait")
    collect_until(:message_update)
    pid = wait_for_pid(pidfile)

    :ok = Session.abort(session)
    refute os_alive?(pid)
    assert [%{stop_reason: :aborted}] = of_type(collect_until(:agent_end), :agent_end)
  end

  test "a line over the cap while a command runs gives the program the same time",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    over_cap = ~s{perl -e 'print "x" x #{HarnessIO.line_max_bytes() + 1}, "\\n"'}
    running = [started(@tid, command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, @tid, running, own_group_command(pidfile, over_cap))

    session = start(ctx)
    :ok = Session.prompt(session, "wait")

    # The release returns before the session gets the end of the harness.
    assert [%{stop_reason: :error, error: {:harness_stop, {:line_over_limit, 16_777_216}}}] =
             of_type(collect_until(:agent_end), :agent_end)

    refute os_alive?(wait_for_pid(pidfile))
  end

  test "a failed turn with an open command stops the harness process, and the next turn starts a new program",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    failed = Path.join(bin, "failed")
    File.write!(failed, turn_end(@tid, "failed", "usage limit") <> "\n")
    running = [started(@tid, command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, @tid, running, own_group_command(pidfile, ~s(cat "#{failed}")))
    # The stop drops the turn's events: no message, so no thread to resume.
    fresh(bin, 2, @fresh, reply(@fresh, "Back."))

    session = start(ctx)

    assert [%{stop_reason: :error, error: {:harness_stop, :command_running}}] =
             of_type(prompt(session, "go"), :agent_end)

    # The release ended the command before the next turn.
    refute os_alive?(wait_for_pid(pidfile))

    events = prompt(session, "again")
    assert [%{stop_reason: :end_turn}] = of_type(events, :agent_end)
    assert runs(bin) == "2"
  end

  # A completion with a status that does not end the item.
  @not_ended %{status: "inProgress", exitCode: nil}

  test "an inProgress completion of a command stops the harness process before the turn's end",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [
      started(@tid, command("exec-1", %{status: "inProgress"})),
      completed(@tid, command("exec-1", @not_ended)),
      turn_end(@tid, "completed")
    ])

    # The stop drops the events of its chunk, the tool call included.
    assert run_direct([Message.user("go")], work) ==
             [{:harness_session, @tid, 0}, {:stop, :item_not_ended}]
  end

  test "a command start with no turn id or no string id stops the harness process",
       %{bin: bin, work: work} do
    starts = [
      note(@tid, "item/started", %{item: command("exec-1", %{status: "inProgress"})}),
      started(@tid, command(7, %{status: "inProgress"}))
    ]

    # One program run per start.
    for {start, n} <- Enum.with_index(starts, 1) do
      fresh(bin, n, @tid, [start, turn_end(@tid, "completed")])

      assert run_direct([Message.user("go")], work) ==
               [{:harness_session, @tid, 0}, {:stop, :item_malformed}]
    end
  end

  test "an inProgress completion of a command ends the turn, so an abort sends no turn/interrupt",
       %{bin: bin} = ctx do
    pidfile = Path.join(bin, "pid")
    line = Path.join(bin, "line")
    File.write!(line, completed(@tid, command("exec-1", @not_ended)) <> "\n")
    running = [started(@tid, command("exec-1", %{status: "inProgress"}))]
    fresh(bin, 1, @tid, running, own_group_command(pidfile, ~s(cat "#{line}")))

    session = start(ctx)

    assert [%{stop_reason: :error, error: {:harness_stop, :item_not_ended}}] =
             of_type(prompt(session, "go"), :agent_end)

    refute os_alive?(wait_for_pid(pidfile))
    :ok = Session.abort(session)
    assert request(bin, 1, "turn/interrupt") == nil
  end

  # A tool item that never completes. It is not a command, because an open
  # command at the turn's end stops the harness process.
  @search %{type: "webSearch", id: "b", query: "x", status: "inProgress"}

  test "a failed turn fails the turn, and a call with no result gets an aborted one",
       %{bin: bin} = ctx do
    fresh(bin, 1, @tid, [
      started(@tid, command("exec-a", %{status: "inProgress"})),
      started(@tid, %{@search | id: "exec-b"}),
      completed(
        @tid,
        command("exec-a", %{status: "failed", aggregatedOutput: "no", exitCode: 2})
      ),
      turn_end(@tid, "failed", "usage limit")
    ])

    events = prompt(start(ctx), "go")

    assert [%{stop_reason: :error, error: {:codex, "failed", "usage limit"}}] =
             of_type(events, :agent_end)

    assert [
             %{message: %Message{tool_call_id: "exec-a", is_error: true}},
             %{message: %Message{tool_call_id: "exec-b", is_error: true} = aborted}
           ] = of_type(events, :tool_execution_end)

    assert Message.text(aborted) == "aborted"
  end

  # The callbacks

  test "an interrupt with no open command sends turn/interrupt and answers at the turn's end",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [
      started(@tid, command("exec-1", %{status: "inProgress"})),
      completed(@tid, command("exec-1", @done))
    ])

    on(bin, 1, "turn/interrupt", [j(%{id: 6, result: %{}}), turn_end(@tid, "interrupted")])
    {:ok, state} = connect(work)

    {turn, actions, state} =
      ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

    {actions, state} =
      drive(
        state,
        actions,
        &Enum.any?(&1, fn a -> match?({:event, _, {:tool_result, _, _}}, a) end)
      )

    assert {:reply, turn, :ok} in actions
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = drive(state, [], replied?(from))

    assert [{:event, "t1", {:error, {:codex, "interrupted", ""}}}, {:reply, ^from, :ok}] = actions

    assert %{"params" => %{"threadId" => @tid, "turnId" => "turn1"}} =
             request(bin, 1, "turn/interrupt")
  end

  test "an interrupt with an open command answers an error at once and sends nothing",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [started(@tid, command("exec-1", %{status: "inProgress"}))])
    {:ok, state} = connect(work)

    {_turn, actions, state} =
      ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})

    {_actions, state} =
      drive(state, actions, &Enum.any?(&1, fn a -> match?({:event, _, {:tool_call, _}}, a) end))

    assert {from, [{:reply, from, {:error, :command_running}}], _state} =
             ask(state, {:interrupt, "t1"})

    assert request(bin, 1, "turn/interrupt") == nil
  end

  test "an interrupt before the turn id is known goes out after the turn/start answer",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [])
    on(bin, 1, "turn/interrupt", [j(%{id: 6, result: %{}}), turn_end(@tid, "interrupted")])
    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = drive(state, [], replied?(from))

    assert [{:reply, ^turn, :ok}, {:event, "t1", {:error, _}}, {:reply, ^from, :ok}] = actions
    assert %{"params" => %{"turnId" => "turn1"}} = request(bin, 1, "turn/interrupt")
  end

  test "a command that starts after the interrupt stops the harness process at the turn's end",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [])

    on(bin, 1, "turn/interrupt", [
      started(@tid, command("exec-1", %{status: "inProgress"})),
      j(%{id: 6, result: %{}}),
      turn_end(@tid, "interrupted")
    ])

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, _state} = drive(state, [], fn _ -> false end)

    assert {:stop, :command_running} = List.last(actions)
    refute Enum.any?(actions, &match?({:reply, ^from, _}, &1))
  end

  test "an interrupt of a turn that ended answers at once", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, reply(@tid, "ok"))
    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {_actions, state} = drive(state, [], &turn_ended?/1)
    assert {from, [{:reply, from, :ok}], _state} = ask(state, {:interrupt, "t1"})
    assert request(bin, 1, "turn/interrupt") == nil
  end

  test "after an interrupt, an item of the stopped turn stops the harness process",
       %{bin: bin, work: work} do
    File.write!(Path.join(bin, "late"), completed(@tid, command("exec-1", @done)) <> "\n")
    fresh(bin, 1, @tid, [])

    on(
      bin,
      1,
      "turn/interrupt",
      [j(%{id: 6, result: %{}}), turn_end(@tid, "interrupted")],
      ~s{sleep 0.2; cat "$d/late"\n}
    )

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {from, [], state} = ask(state, {:interrupt, "t1"})
    {actions, state} = drive(state, [], replied?(from))
    assert {:reply, from, :ok} in actions
    assert {[{:stop, :item_of_ended_turn}], _state} = drive(state, [], fn _ -> false end)
  end

  test "a turn that Helyx did not ask for stops the harness process", %{bin: bin, work: work} do
    other = note(@tid, "turn/started", %{turn: %{id: "turn9", status: "inProgress"}})
    File.write!(Path.join(bin, "other"), other <> "\n")
    fresh(bin, 1, @tid, reply(@tid, "ok"), ~s{sleep 0.2; cat "$d/other"\n})

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, state} = drive(state, [], &turn_ended?/1)
    assert {:event, "t1", {:done, _}} = List.last(actions)
    assert {[{:stop, :turn_not_asked}], _state} = drive(state, [], fn _ -> false end)
  end

  test "an error answer to turn/start answers the turn with it", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [])
    on(bin, 1, "turn/start", [j(%{id: 5, error: %{code: -1, message: "busy"}})])
    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, _state} = drive(state, [], replied?(turn))
    assert {:reply, turn, {:error, {:codex, "turn/start", "busy"}}} in actions
  end

  test "a turn that completes before its turn/start answer ends at once, and the next turn waits for that answer",
       %{bin: bin, work: work} do
    answer = j(%{id: 5, result: %{turn: %{id: "turn1", status: "inProgress"}}})
    fresh(bin, 1, @tid, [])

    on(
      bin,
      1,
      "turn/start",
      [
        note(@tid, "turn/started", %{turn: %{id: "turn1", status: "inProgress"}}),
        turn_end(@tid, "failed", "boom")
      ],
      after_go(bin, "late", [answer]),
      1
    )

    on(bin, 1, "turn/start", as_turn(turn(@tid, reply(@tid, "Next.")), "turn2"), "", 2)

    {:ok, state} = connect(work)
    {turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {actions, state} = drive(state, [], &turn_ended?/1)
    assert [{:reply, ^turn, :ok} | rest] = actions
    assert [{:error, {:codex, "failed", "boom"}}] = events(rest)

    # The turn ended: an interrupt sends nothing.
    {interrupt, actions, state} = ask(state, {:interrupt, "t1"})
    assert actions == [{:reply, interrupt, :ok}]

    {next, [], state} =
      ask(state, {:turn, "t2", %Helyx.Context{messages: [Message.user("again")]}})

    go(bin)
    {actions, state} = drive(state, [], &turn_ended?/1)
    assert {:reply, next, :ok} in actions
    assert [{:done, _}] = for({:event, "t2", {:done, _} = e} <- actions, do: e)
    assert request(bin, 1, "turn/interrupt") == nil
    close(state)
    assert length(for %{"method" => "turn/start"} <- stdin(bin, 1), do: 1) == 2
  end

  test "a turn/started while the next turn waits for the late answer stops the harness process",
       %{bin: bin, work: work} do
    answer = j(%{id: 5, result: %{turn: %{id: "turn1", status: "inProgress"}}})
    ghost = note(@tid, "turn/started", %{turn: %{id: "turn9", status: "inProgress"}})
    fresh(bin, 1, @tid, [])

    on(
      bin,
      1,
      "turn/start",
      [
        note(@tid, "turn/started", %{turn: %{id: "turn1", status: "inProgress"}}),
        turn_end(@tid, "completed")
      ],
      after_go(bin, "late", [ghost, answer]),
      1
    )

    # Were the ghost taken as the next turn, this answer would complete it.
    on(bin, 1, "turn/start", as_turn(turn(@tid, reply(@tid, "Ghost.")), "turn9"), "", 2)

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {_actions, state} = drive(state, [], &turn_ended?/1)

    {_next, [], state} =
      ask(state, {:turn, "t2", %Helyx.Context{messages: [Message.user("again")]}})

    go(bin)
    assert {[{:stop, :turn_not_asked}], _state} = drive(state, [], fn _ -> false end)
  end

  test "a late turn/interrupt answer does not answer the next interrupt", %{bin: bin, work: work} do
    late = j(%{id: 6, error: %{code: -1, message: "no active turn"}})
    fresh(bin, 1, @tid, [delta(@tid, "msg_1", "thinking")])

    on(
      bin,
      1,
      "turn/interrupt",
      [turn_end(@tid, "interrupted")],
      after_go(bin, "late", [late]),
      1
    )

    second = [j(%{id: 6, result: %{}}), turn_end(@tid, "interrupted")]
    on(bin, 1, "turn/interrupt", as_turn(second, "turn2"), "", 2)

    on(
      bin,
      1,
      "turn/start",
      as_turn(turn(@tid, [delta(@tid, "msg_2", "again")]), "turn2"),
      "",
      2
    )

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    {_actions, state} = drive(state, [], &match?([_ | _], events(&1)))
    {first, [], state} = ask(state, {:interrupt, "t1"})
    {actions, state} = drive(state, [], replied?(first))
    assert {:reply, first, :ok} in actions

    {_next, _, state} =
      ask(state, {:turn, "t2", %Helyx.Context{messages: [Message.user("again")]}})

    {_actions, state} =
      drive(state, [], &Enum.any?(&1, fn a -> match?({:event, "t2", {:text_delta, _}}, a) end))

    # The answer to the first `turn/interrupt` is still due, so the second
    # waits for it.
    {second, [], state} = ask(state, {:interrupt, "t2"})
    go(bin)
    {actions, state} = drive(state, [], replied?(second))
    assert {:reply, second, :ok} in actions
    close(state)

    assert [%{"params" => %{"turnId" => "turn1"}}, %{"params" => %{"turnId" => "turn2"}}] =
             for(%{"method" => "turn/interrupt"} = r <- stdin(bin, 1), do: r)
  end

  test "a turn/completed before the turn is known stops the harness process",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [])
    on(bin, 1, "turn/start", [turn_end(@tid, "completed")])

    {:ok, state} = connect(work)
    {_turn, _, state} = ask(state, {:turn, "t1", %Helyx.Context{messages: [Message.user("go")]}})
    assert {[{:stop, :turn_not_asked}], _state} = drive(state, [], fn _ -> false end)
  end

  test "a close ends the input and answers at the exit", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [])
    {:ok, state} = connect(work)
    close(state)
  end

  test "an approval request is accepted and any other server request gets an error",
       %{bin: bin, work: work} do
    fresh(
      bin,
      1,
      @tid,
      [
        j(%{id: 0, method: "item/commandExecution/requestApproval", params: %{threadId: @tid}}),
        j(%{id: "r", method: "item/fileChange/requestApproval", params: %{threadId: @tid}}),
        j(%{id: 7, method: "item/tool/requestUserInput", params: %{threadId: @tid}})
      ] ++ reply(@tid, "ok")
    )

    assert [{:harness_session, @tid, 0}, {:text_delta, "ok"}, {:done, _}] =
             run_direct([Message.user("go")], work)

    answers =
      for %{"id" => id} = line <- stdin(bin, 1), not is_map_key(line, "method"), do: {id, line}

    assert [
             {0, %{"result" => %{"decision" => "accept"}}},
             {"r", %{"result" => %{"decision" => "accept"}}},
             {7, %{"error" => %{"code" => -32_601}}}
           ] = answers
  end

  # Codex can run tool items side by side: the message of both calls
  # closes once, before the first result.
  test "two tool items that run together close one message", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("a", @done)),
      completed(@tid, command("b", @done)),
      turn_end(@tid, "completed")
    ])

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_result, "b", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)
  end

  test "a tool result over the limits arrives cut, with the notice", %{bin: bin, work: work} do
    big = String.duplicate("x\n", 3_000)

    fresh(bin, 1, @tid, [
      completed(@tid, command("a", %{@done | aggregatedOutput: big})),
      turn_end(@tid, "completed")
    ])

    events = run_direct([Message.user("go")], work)
    assert [text] = for({:tool_result, "a", {:ok, t}} <- events, do: t)
    assert text == Helyx.Text.truncate(big, :tail)
    assert text =~ "[truncated: showing lines 1001-3000 of 3000]"
  end

  # A message that closes while a call of the message before it still
  # runs waits for that call's result, so the session does not abort it.
  test "a message that closes before an earlier call's result waits for it",
       %{bin: bin, work: work} = ctx do
    lines = [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("a", @done)),
      delta(@tid, "msg_x", "x"),
      started(@tid, command("d", %{status: "inProgress"})),
      completed(@tid, command("d", @done)),
      completed(@tid, command("b", @done)),
      turn_end(@tid, "completed")
    ]

    fresh(bin, 1, @tid, lines)
    fresh(bin, 2, @tid, lines)

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:text_delta, "x"},
             {:tool_call, %{id: "d"}},
             {:tool_result, "b", {:ok, "out"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)

    # The same run in a session: every real result joins the transcript,
    # each before the next message.
    events = ctx |> start() |> prompt("go")

    assert [{"a", "out"}, {"b", "out"}, {"d", "out"}] =
             for(
               %{message: m} <- of_type(events, :tool_execution_end),
               do: {m.tool_call_id, Message.text(m)}
             )

    assert [
             %Message{role: :user},
             %Message{role: :assistant, content: [%{id: "a"}, %{id: "b"}]},
             %Message{role: :assistant, content: [%Message.Text{text: "x"}, %{id: "d"}]},
             # The session closes the turn with an empty message when the
             # turn ends right after a result (as before this change).
             %Message{role: :assistant, content: [], stop_reason: :end_turn}
           ] = messages(events)
  end

  # A result of a held message must not wait behind a later held message.
  test "a held result goes before a later message's end", %{bin: bin, work: work} = ctx do
    lines = [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, command("b", %{status: "inProgress"})),
      completed(@tid, command("b", @done)),
      started(@tid, command("c", %{status: "inProgress"})),
      started(@tid, command("e", %{status: "inProgress"})),
      completed(@tid, command("c", @done)),
      started(@tid, command("d", %{status: "inProgress"})),
      completed(@tid, command("d", @done)),
      completed(@tid, command("e", @done)),
      completed(@tid, command("a", @done)),
      delta(@tid, "msg_y", "ok"),
      turn_end(@tid, "completed")
    ]

    fresh(bin, 1, @tid, lines)
    fresh(bin, 2, @tid, lines)

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "b", _},
             {:tool_call, %{id: "c"}},
             {:tool_call, %{id: "e"}},
             {:tool_result, "a", _},
             {:message_end, :tool_use, _},
             {:tool_result, "c", _},
             {:tool_result, "e", _},
             {:tool_call, %{id: "d"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", _},
             {:text_delta, "ok"},
             {:done, _}
           ] = run_direct([Message.user("go")], work)

    events = ctx |> start() |> prompt("go")

    assert ["out", "out", "out", "out", "out"] =
             for(%{message: m} <- of_type(events, :tool_execution_end), do: Message.text(m))
  end

  # The turn's end sends what was held.
  test "the turn's end sends the held events", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, [
      started(@tid, command("a", %{status: "inProgress"})),
      started(@tid, @search),
      completed(@tid, command("a", @done)),
      started(@tid, command("d", %{status: "inProgress"})),
      completed(@tid, command("d", @done)),
      turn_end(@tid, "completed")
    ])

    assert [
             {:harness_session, @tid, 0},
             {:tool_call, %{id: "a"}},
             {:tool_call, %{id: "b"}},
             {:message_end, :tool_use, _},
             {:tool_result, "a", {:ok, "out"}},
             {:tool_call, %{id: "d"}},
             {:message_end, :tool_use, _},
             {:tool_result, "d", {:ok, "out"}},
             {:done, _}
           ] = run_direct([Message.user("go")], work)
  end

  # The events that go out before the `message_end` of "d", which waits for
  # "b". The held events are dropped with the turn, as at an abort.
  @sent [
    {:harness_session, @tid, 0},
    {:tool_call,
     %Message.ToolCall{
       id: "a",
       name: "commandExecution",
       arguments: %{"command" => "/bin/zsh -lc ls", "cwd" => "/work"}
     }},
    {:tool_call, %Message.ToolCall{id: "b", name: "webSearch", arguments: %{"query" => "x"}}},
    {:message_end, :tool_use, %{}},
    {:tool_result, "a", {:ok, "out"}},
    {:tool_call,
     %Message.ToolCall{
       id: "d",
       name: "commandExecution",
       arguments: %{"command" => "/bin/zsh -lc ls", "cwd" => "/work"}
     }}
  ]

  defp held(tid) do
    [
      started(tid, command("a", %{status: "inProgress"})),
      started(tid, @search),
      completed(tid, command("a", @done)),
      started(tid, command("d", %{status: "inProgress"})),
      completed(tid, command("d", @done))
    ]
  end

  test "an exit during a turn stops the harness process", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, held(@tid), "exit 3\n")
    assert run_direct([Message.user("go")], work) == @sent ++ [{:stop, {:codex_exit, 3}}]
  end

  test "a line over the cap stops the harness process", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, held(@tid) ++ [String.duplicate("x", 16 * 1024 * 1024 + 1)])

    assert run_direct([Message.user("go")], work) ==
             @sent ++ [{:stop, {:line_over_limit, 16_777_216}}]
  end

  # The `message_end` of "d" waits for "b", so it and every event after it
  # is held: the end, the result, and 9,998 deltas make 10,000, the cap.
  defp held_run(bin, work, count) do
    deltas = for i <- 1..count, do: delta(@tid, "msg_y", "#{i}")
    fresh(bin, 1, @tid, held(@tid) ++ deltas ++ [turn_end(@tid, "completed")])
    {sent, rest} = Enum.split(run_direct([Message.user("go")], work), length(@sent))
    assert sent == @sent
    rest
  end

  test "the held events one under the cap go out at the turn's end", %{bin: bin, work: work} do
    assert [{:message_end, _, _}, {:tool_result, "d", _} | rest] = held_run(bin, work, 9_997)

    assert {texts, [{:done, _}]} = Enum.split(rest, -1)
    assert texts == for(i <- 1..9_997, do: {:text_delta, "#{i}"})
  end

  test "the held events at the cap go out at the turn's end", %{bin: bin, work: work} do
    assert [_, _ | rest] = held_run(bin, work, 9_998)
    assert {texts, [{:done, _}]} = Enum.split(rest, -1)
    assert texts == for(i <- 1..9_998, do: {:text_delta, "#{i}"})
  end

  # The next delta is over the cap: nothing held goes out.
  test "the held events over the cap stop the harness process", %{bin: bin, work: work} do
    assert held_run(bin, work, 9_999) == [{:stop, {:held_over_limit, 10_000}}]
  end

  test "a replayed call id and tool name keep to the API limits", %{bin: bin, work: work} do
    fresh(bin, 1, @tid, reply(@tid, "ok"))

    ids = [
      String.duplicate("a", 63),
      String.duplicate("b", 64),
      String.duplicate("c", 65),
      "é",
      "e",
      ""
    ]

    names = [
      String.duplicate("l", 63),
      String.duplicate("n", 64),
      String.duplicate("m", 65),
      "é" <> String.duplicate("o", 64),
      "",
      "p"
    ]

    calls =
      Enum.zip_with(ids, names, &%Message.ToolCall{id: &1, name: &2, arguments: %{}})

    run_direct([%Message{role: :assistant, content: calls}, Message.user("go")], work)
    %{"params" => %{"items" => items}} = request(bin, 1, "thread/inject_items")
    [a63, b64 | _] = ids
    assert [^a63, ^b64, id65, id_multibyte, "e", "h_" <> _] = Enum.map(items, & &1["call_id"])
    assert "h_" <> _ = id65
    assert "h_" <> _ = id_multibyte
    assert byte_size(id65) == 64
    assert byte_size(id_multibyte) == 64
    assert id65 != id_multibyte

    assert Enum.map(items, & &1["name"]) == [
             String.duplicate("l", 63),
             String.duplicate("n", 64),
             String.duplicate("m", 64),
             "_" <> String.duplicate("o", 63),
             "_",
             "p"
           ]
  end

  test "a message with no deltas gives its text whole", %{bin: bin, work: work} do
    item = %{type: "agentMessage", id: "msg_1", text: "Whole."}
    fresh(bin, 1, @tid, [completed(@tid, item), turn_end(@tid, "completed")])

    assert [{:harness_session, @tid, 0}, {:text_delta, "Whole."}, {:done, _}] =
             run_direct([Message.user("go")], work)
  end

  test "the replay keeps the newest messages within 400,000 bytes and never starts at a result",
       %{bin: bin, work: work} do
    fresh(bin, 1, @tid, reply(@tid, "ok"))
    big = String.duplicate("x", 150_000)
    call = %Message.ToolCall{id: "c1", name: "read", arguments: %{}}

    history = [
      %Message{role: :user, content: [%Message.Text{text: "old " <> big}]},
      %Message{role: :assistant, content: [%Message.Text{text: big <> big}, call]},
      %Message{role: :tool_result, tool_call_id: "c1", content: [%Message.Text{text: big}]},
      %Message{role: :assistant, content: [%Message.Text{text: "tail"}]},
      Message.user("go")
    ]

    # The result and the tail fit; the assistant message with the call does
    # not, so the replay starts after the result, at the tail.
    assert [{:harness_session, @tid, 3} | _] = run_direct(history, work)

    assert %{"params" => %{"items" => [%{"content" => [%{"text" => "tail"}]}]}} =
             request(bin, 1, "thread/inject_items")
  end

  test "a response error fails the connect with the method and the message",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [j(%{id: 3, error: %{code: -1, message: "bad model"}})])
    assert {:error, {:codex, "thread/start", "bad model"}} = connect(work)
  end

  test "a program that exits before its thread is ready fails the connect",
       %{bin: bin, work: work} do
    initialize(bin, 1)
    on(bin, 1, "thread/start", [], "exit 3\n")
    assert {:error, {:codex_exit, 3}} = connect(work)
  end
end
