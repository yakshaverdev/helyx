defmodule Helyx.Session.HarnessToolsTest do
  # Helyx tool calls of a connected turn (`docs/features/long-lived-harness.md`,
  # "Helyx tool calls"), driven through the session with the fake connected
  # provider: the loop's rules, the queue of the session, and the turn
  # cleanup at an abort, a crash, and a normal end.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.Session
  alias Helyx.Test.Connected

  setup do
    core = :"core_#{System.unique_integer([:positive])}"

    plugins = [
      Connected,
      Helyx.Test.PrepareContext,
      Helyx.Test.Tool.Upcase,
      Helyx.Test.Tool.Slow
    ]

    start_supervised!({Helyx.Core, name: core, plugins: plugins})
    Process.register(self(), Connected.controller(core))
    {:ok, session} = Session.start(core, model: "conn/tools")
    {:ok, _} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, harness, {:turn, turn_id, _context}}
    hands = :sys.get_state(Session.pid(session)).hands
    %{core: core, session: session, harness: harness, turn_id: turn_id, hands: hands}
  end

  defp request(harness, turn_id, id, name, args),
    do: send(harness, {:tool_request, turn_id, id, name, args})

  defp slow(harness, turn_id, id, ms \\ 60_000),
    do: request(harness, turn_id, id, "slow", %{"ms" => ms, "text" => id})

  # The kinds of the provider's requests, in order, until one of `last`.
  defp requests_until(last, acc \\ []) do
    receive do
      {:conn, ^last, _pid, request} -> Enum.reverse([request | acc])
      {:conn, _kind, _pid, request} -> requests_until(last, [request | acc])
    after
      3_000 -> flunk("timed out waiting for #{last}")
    end
  end

  # The tool Tasks of the hands; the harness process is a Task there too.
  defp running(hands),
    do: Enum.count(:sys.get_state(hands).tasks, fn {_ref, {_, _, id, _}} -> is_binary(id) end)

  # The call ids in the session's queue of the turn: only the running call,
  # because the harness loop owns the waiting queue.
  defp queued(session) do
    tool = :sys.get_state(Session.pid(session)).turn.tool
    if tool, do: [tool.id], else: []
  end

  # The harness process sent its events before the pong, and the snapshot
  # call reaches the session after them. The second pass covers the start
  # ask of a tool request: the session sent it before the first snapshot,
  # and handled its answer before the second one.
  defp sync(harness, session) do
    for _pass <- 1..2 do
      send(harness, {:ping, self()})
      assert_receive :pong
      GenServer.call(Session.pid(session), {:snapshot}).model
    end

    :ok
  end

  test "a request runs the tool and its result goes back; the transcript gets nothing from it",
       %{session: session, harness: harness, turn_id: turn_id} do
    request(harness, turn_id, "c1", "upcase", %{"text" => "hi"})

    assert_receive {:conn, :tool_result, ^harness, {:tool_result, ^turn_id, "c1", {:ok, "HI"}}}

    send(harness, {:finish, turn_id})
    events = collect_until(:agent_end)
    refute Enum.any?(events, &(&1.type in [:tool_execution_start, :tool_execution_end]))
    assert [%{role: :user}, %{role: :assistant}] = :sys.get_state(Session.pid(session)).transcript
  end

  test "the requests of a turn run one at a time, in order",
       %{harness: harness, turn_id: turn_id} do
    slow(harness, turn_id, "c1", 200)
    request(harness, turn_id, "c2", "upcase", %{"text" => "b"})

    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c1", {:ok, "c1"}}}, 3_000
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c2", _}}
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c2", {:ok, "B"}}}
  end

  test "over one running and 16 waiting, a request gets an error at once and runs nothing",
       %{session: session, harness: harness, turn_id: turn_id, hands: hands} do
    for i <- 1..17, do: slow(harness, turn_id, "c#{i}")
    slow(harness, turn_id, "c18")

    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c18", {:error, "too many" <> _}}}
    # The 17th (at the limit) was taken: only the 18th got an answer.
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c" <> _, _}}
    sync(harness, session)
    assert running(hands) == 1
  end

  test "a call id that was withdrawn is not used again in the turn",
       %{session: session, harness: harness, turn_id: turn_id, hands: hands} do
    slow(harness, turn_id, "c1")
    sync(harness, session)
    :erlang.suspend_process(hands)
    send(harness, {:cancel, turn_id, "c1"})
    request(harness, turn_id, "c1", "upcase", %{"text" => "new"})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "c1", {:error, "the call id was used before" <> _}}}

    :erlang.resume_process(hands)
    # The killed run's result is dropped, and the next request runs.
    request(harness, turn_id, "c2", "upcase", %{"text" => "b"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c2", {:ok, "B"}}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c1", _}}
  end

  test "an answered call id gets an error in its turn, and a new turn can use it again",
       %{session: session, harness: harness, turn_id: turn_id} do
    request(harness, turn_id, "c1", "upcase", %{"text" => "a"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c1", {:ok, "A"}}}
    request(harness, turn_id, "c1", "upcase", %{"text" => "b"})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "c1", {:error, "the call id was used before" <> _}}}

    send(harness, {:finish, turn_id})
    collect_until(:agent_end)
    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^harness, {:turn, next, _}}
    request(harness, next, "c1", "upcase", %{"text" => "c"})
    assert_receive {:conn, :tool_result, _, {:tool_result, ^next, "c1", {:ok, "C"}}}
  end

  test "a second request with the id of an open request stops the harness process",
       %{harness: harness, turn_id: turn_id} do
    ref = Process.monitor(harness)
    slow(harness, turn_id, "c1")
    slow(harness, turn_id, "c1")
    assert_receive {:DOWN, ^ref, :process, ^harness, _reason}
  end

  test "a request of a turn that is not live gets aborted and runs nothing",
       %{harness: harness, turn_id: turn_id, hands: hands} do
    send(harness, {:finish, turn_id})
    collect_until(:agent_end)

    request(harness, turn_id, "late", "upcase", %{"text" => "x"})
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "late", {:error, "aborted"}}}
    assert running(hands) == 0
  end

  test "an argument with an integer over the limit is not run",
       %{harness: harness, turn_id: turn_id} do
    big = String.to_integer(String.duplicate("9", 5_000))
    request(harness, turn_id, "c1", "upcase", %{"text" => "x", "n" => big})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "c1", {:error, "tool call not run" <> _}}}
  end

  test "a withdrawn request stops its run, drops its result, and the next one runs",
       %{session: session, harness: harness, turn_id: turn_id, hands: hands} do
    slow(harness, turn_id, "c1")
    slow(harness, turn_id, "c2")
    request(harness, turn_id, "c3", "upcase", %{"text" => "c"})
    sync(harness, session)
    assert running(hands) == 1

    send(harness, {:cancel, turn_id, "c2"})
    send(harness, {:cancel, turn_id, "c1"})

    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c3", {:ok, "C"}}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c1", _}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c2", _}}
  end

  test "an abort kills the running tool, answers the open requests before the interrupt",
       %{session: session, harness: harness, turn_id: turn_id, hands: hands} do
    slow(harness, turn_id, "c1")
    slow(harness, turn_id, "c2")
    sync(harness, session)

    :ok = Session.abort(session)

    requests = requests_until(:interrupt)

    assert Enum.take(requests, -3) |> Enum.map(&elem(&1, 0)) ==
             [:tool_result, :tool_result, :interrupt]

    assert {:tool_result, ^turn_id, _, {:error, "aborted"}} = Enum.at(requests, -2)
    assert running(hands) == 0
    assert Process.alive?(harness)
  end

  test "a crash of the harness process ends the turn and kills the running tool",
       %{session: session, harness: harness, turn_id: turn_id, hands: hands} do
    slow(harness, turn_id, "c1")
    sync(harness, session)
    send(harness, :stop)

    events = collect_until(:agent_end)
    assert List.last(events).data.stop_reason == :error
    # The session asks the hands for the cleanup after it emits agent_end.
    GenServer.call(Session.pid(session), {:snapshot}).model
    assert running(hands) == 0
  end

  test "a normal end with a tool still running answers it aborted and runs the cleanup",
       %{session: session, harness: harness, turn_id: turn_id, hands: hands} do
    slow(harness, turn_id, "c1")
    slow(harness, turn_id, "c2")
    sync(harness, session)
    send(harness, {:finish, turn_id})

    assert List.last(collect_until(:agent_end)).data.stop_reason == :end_turn
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "c1", {:error, "aborted"}}}
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "c2", {:error, "aborted"}}}

    # The next turn starts only after the cleanup.
    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^harness, _}
    assert running(hands) == 0
  end

  test "the loop's own answer that the provider does not reply to in its callback stops the harness process",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "conn/tools_late")
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, harness, {:turn, turn_id, _context}}
    ref = Process.monitor(harness)
    slow(harness, turn_id, "c1")
    sync(harness, session)
    send(harness, {:finish, turn_id})

    assert_receive {:conn, :tool_result, ^harness,
                    {:tool_result, ^turn_id, "c1", {:error, "aborted"}}}

    assert_receive {:DOWN, ^ref, :process, ^harness, _reason}
  end

  test "a tool result that the provider does not reply to in its callback stops the harness process before any interrupt",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "conn/tools_late")
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, harness, {:turn, turn_id, _context}}
    ref = Process.monitor(harness)
    request(harness, turn_id, "c1", "upcase", %{"text" => "a"})

    assert_receive {:conn, :tool_result, ^harness, {:tool_result, ^turn_id, "c1", {:ok, "A"}}}
    assert_receive {:DOWN, ^ref, :process, ^harness, _reason}
    :ok = Session.abort(session)
    refute_received {:conn, :interrupt, _, _}
  end

  test "a tool result is written with 8 other requests open", %{core: core} do
    {:ok, session} = Session.start(core, model: "conn/steer_hold")
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, harness, {:turn, turn_id, _context}}

    for i <- 1..8 do
      Session.steer(session, "s#{i}")
      assert_receive {:conn, :steer, ^harness, _}
    end

    request(harness, turn_id, "c1", "upcase", %{"text" => "a"})
    assert_receive {:conn, :tool_result, ^harness, {:tool_result, ^turn_id, "c1", {:ok, "A"}}}
    assert Process.alive?(harness)
  end

  test "a call id that got the limit error never runs later in the turn",
       %{session: session, harness: harness, turn_id: turn_id} do
    for i <- 1..17, do: slow(harness, turn_id, "c#{i}")
    request(harness, turn_id, "x", "upcase", %{"text" => "x"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "too many" <> _}}}

    send(harness, {:cancel, turn_id, "c2"})
    request(harness, turn_id, "x", "upcase", %{"text" => "x"})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "x", {:error, "the call id was used before" <> _}}}

    sync(harness, session)
    refute "x" in queued(session)
  end

  test "one batch: a request over the limit, its withdraw, a free slot, and the same id again",
       %{session: session, harness: harness, turn_id: turn_id} do
    for i <- 1..17, do: slow(harness, turn_id, "c#{i}")
    sync(harness, session)
    x = {:event, turn_id, {:tool_request, "x", "upcase", %{"text" => "x"}}}

    send(
      harness,
      {:batch, [x, {:cancel_tool, turn_id, "x"}, {:cancel_tool, turn_id, "c2"}, x]}
    )

    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "too many" <> _}}}

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "x", {:error, "the call id was used before" <> _}}}

    sync(harness, session)
    assert queued(session) == ["c1"]
  end

  # Waits until the mailbox of `pid` holds a message that `match?` finds;
  # the process is suspended, so the message stays there. Polls every 10 ms,
  # for at least `ms`.
  defp in_mailbox(pid, match?, ms \\ 5_000)
  defp in_mailbox(_pid, _match?, ms) when ms <= 0, do: flunk("no such message in the mailbox")

  defp in_mailbox(pid, match?, ms) do
    {:messages, messages} = Process.info(pid, :messages)

    unless Enum.any?(messages, match?) do
      Process.sleep(10)
      in_mailbox(pid, match?, ms - 10)
    end
  end

  test "a waiting call that got aborted at the terminal never starts, when the running call's result came first",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = Session.pid(session)
    slow(harness, turn_id, "c1", 200)
    slow(harness, turn_id, "x")
    sync(harness, session)

    :erlang.suspend_process(pid)
    in_mailbox(pid, &match?({:tool_result, _, "c1", _}, &1))
    send(harness, {:finish, turn_id})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "aborted"}}}

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    collect_until(:agent_end)
    sync(harness, session)

    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a call that the loop sent and then answered aborted at the terminal never starts",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = Session.pid(session)
    slow(harness, turn_id, "c1", 200)
    slow(harness, turn_id, "x")
    sync(harness, session)

    :erlang.suspend_process(harness)
    in_mailbox(harness, &match?({:harness_request, _, _, {:tool_result, _, "c1", _}}, &1))
    :erlang.suspend_process(pid)
    send(harness, {:finish, turn_id})
    :erlang.resume_process(harness)
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "aborted"}}}

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    collect_until(:agent_end)
    sync(harness, session)

    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a call withdrawn after the loop sent it and before the ask never starts, and the next one runs",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = Session.pid(session)
    slow(harness, turn_id, "c1", 200)
    slow(harness, turn_id, "x")
    request(harness, turn_id, "y", "upcase", %{"text" => "y"})
    sync(harness, session)

    :erlang.suspend_process(harness)
    in_mailbox(harness, &match?({:harness_request, _, _, {:tool_result, _, "c1", _}}, &1))
    :erlang.suspend_process(pid)
    :erlang.resume_process(harness)
    send(harness, {:cancel, turn_id, "x"})
    send(harness, {:ping, self()})
    assert_receive :pong

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "y", {:ok, "Y"}}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "an ask with no answer before its deadline stops the harness process and runs nothing",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = Session.pid(session)
    :sys.replace_state(pid, &put_in(&1.harness_ms.tool_start, 100))
    :erlang.suspend_process(pid)
    request(harness, turn_id, "c1", "upcase", %{"text" => "c"})
    send(harness, {:ping, self()})
    assert_receive :pong
    ref = Process.monitor(harness)
    :erlang.suspend_process(harness)

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    assert_receive {:DOWN, ^ref, :process, ^harness, :killed}, 3_000
    events = collect_until(:agent_end)
    assert List.last(events).data.stop_reason == :error
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "c1"}}}, _}
  end

  # Holds the ask of `x` in the mailbox of the suspended harness process.
  defp hold_ask(session, harness, turn_id) do
    pid = Session.pid(session)
    :erlang.suspend_process(pid)
    request(harness, turn_id, "x", "upcase", %{"text" => "x"})
    send(harness, {:ping, self()})
    assert_receive :pong
    :erlang.suspend_process(harness)
    :erlang.resume_process(pid)
    in_mailbox(harness, &match?({:harness_request, _, _, {:tool_start, _, "x"}}, &1))
    pid
  end

  test "a terminal after the ok to the ask does not answer the call; the result of its run does, before the next turn",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = hold_ask(session, harness, turn_id)
    :erlang.suspend_process(pid)
    send(harness, {:finish, turn_id})
    :erlang.resume_process(harness)
    send(harness, {:ping, self()})
    assert_receive :pong
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    collect_until(:agent_end)
    assert_receive {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "x", {:error, "aborted"}}}

    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^harness, {:turn, _next, _context}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}
  end

  test "an abort during the ask answers the call once and runs nothing",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = hold_ask(session, harness, turn_id)
    :erlang.trace(pid, true, [:send])
    task = Task.async(fn -> Session.abort(session) end)
    in_mailbox(harness, &match?({:harness_request, _, _, {:tool_result, _, "x", _}}, &1))
    :erlang.resume_process(harness)
    assert :ok = Task.await(task)

    assert [{:tool_result, ^turn_id, "x", {:error, "aborted"}}, {:interrupt, ^turn_id}] =
             Enum.take(requests_until(:interrupt), -2)

    GenServer.call(Session.pid(session), {:snapshot}).model
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a harness process that dies during the ask fails the turn and runs nothing",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = hold_ask(session, harness, turn_id)
    :erlang.trace(pid, true, [:send])
    Process.exit(harness, :kill)
    events = collect_until(:agent_end)
    assert List.last(events).data.stop_reason == :error
    GenServer.call(Session.pid(session), {:snapshot}).model
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a next turn waits for the answer of the call whose ask was open at the abort",
       %{session: session, harness: harness, turn_id: turn_id} do
    hold_ask(session, harness, turn_id)
    task = Task.async(fn -> Session.abort(session) end)
    in_mailbox(harness, &match?({:harness_request, _, _, {:tool_result, _, "x", _}}, &1))
    :ok = Session.prompt(session, "again")
    GenServer.call(Session.pid(session), {:snapshot}).model
    {:messages, held} = Process.info(harness, :messages)
    refute Enum.any?(held, &match?({:harness_request, _, _, {:turn, _, _}}, &1))

    :erlang.resume_process(harness)
    assert :ok = Task.await(task)

    assert [
             {:tool_result, ^turn_id, "x", {:error, "aborted"}},
             {:interrupt, ^turn_id},
             {:turn, _, _}
           ] =
             Enum.take(requests_until(:turn), -3)
  end

  test "a started call that the harness withdraws after the terminal gets no answer",
       %{session: session, harness: harness, turn_id: turn_id} do
    pid = hold_ask(session, harness, turn_id)
    :erlang.suspend_process(pid)
    send(harness, {:finish, turn_id})
    :erlang.resume_process(harness)
    send(harness, {:cancel, turn_id, "x"})
    send(harness, {:ping, self()})
    assert_receive :pong

    :erlang.resume_process(pid)
    collect_until(:agent_end)
    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^harness, {:turn, _next, _context}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}
  end
end
