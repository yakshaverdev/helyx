defmodule Helyx.Session.ProviderProcessToolsTest do
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
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _context}}
    hands = :sys.get_state(Session.pid(session)).hands
    %{core: core, session: session, proc: proc, turn_id: turn_id, hands: hands}
  end

  defp request(proc, turn_id, id, name, args),
    do: send(proc, {:tool_request, turn_id, id, name, args})

  defp slow(proc, turn_id, id, ms \\ 60_000),
    do: request(proc, turn_id, id, "slow", %{"ms" => ms, "text" => id})

  # The kinds of the provider's requests, in order, until one of `last`.
  defp requests_until(last, acc \\ []) do
    receive do
      {:conn, ^last, _pid, request} -> Enum.reverse([request | acc])
      {:conn, _kind, _pid, request} -> requests_until(last, [request | acc])
    after
      Helyx.Test.Events.wait_ms() -> flunk("timed out waiting for #{last}")
    end
  end

  # The tool Tasks of the hands; the provider process is a Task there too.
  defp running(hands),
    do: Enum.count(:sys.get_state(hands).tasks, fn {_ref, {_, _, id, _}} -> is_binary(id) end)

  # The call ids in the session's queue of the turn: only the running call,
  # because the provider loop owns the waiting queue.
  defp queued(session) do
    tool = :sys.get_state(Session.pid(session)).activity.tool
    if tool, do: [tool.id], else: []
  end

  # The provider process sent its events before the pong, and the snapshot
  # call reaches the session after them. The second pass covers the start
  # ask of a tool request: the session sent it before the first snapshot,
  # and handled its answer before the second one.
  defp sync(proc, session) do
    for _pass <- 1..2 do
      send(proc, {:ping, self()})
      assert_receive :pong
      GenServer.call(Session.pid(session), :snapshot).model
    end

    :ok
  end

  test "a request runs the tool and its result goes back; the transcript gets nothing from it",
       %{session: session, proc: proc, turn_id: turn_id} do
    request(proc, turn_id, "c1", "upcase", %{"text" => "hi"})

    assert_receive {:conn, :tool_result, ^proc, {:tool_result, ^turn_id, "c1", {:ok, "HI"}}}

    send(proc, {:finish, turn_id})
    events = collect_until(:agent_end)
    refute Enum.any?(events, &(&1.type in [:tool_execution_start, :tool_execution_end]))
    assert [%{role: :user}, %{role: :assistant}] = :sys.get_state(Session.pid(session)).transcript
  end

  test "the requests of a turn run one at a time, in order",
       %{proc: proc, turn_id: turn_id} do
    slow(proc, turn_id, "c1", 200)
    request(proc, turn_id, "c2", "upcase", %{"text" => "b"})

    # The results arrive in the order of their runs.
    assert_receive {:conn, :tool_result, _, {:tool_result, _, first, first_result}}
    assert_receive {:conn, :tool_result, _, {:tool_result, _, second, second_result}}

    assert [{first, first_result}, {second, second_result}] == [
             {"c1", {:ok, "c1"}},
             {"c2", {:ok, "B"}}
           ]
  end

  test "over one running and 16 waiting, a request gets an error at once and runs nothing",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    for i <- 1..17, do: slow(proc, turn_id, "c#{i}")
    slow(proc, turn_id, "c18")

    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c18", {:error, "too many" <> _}}}
    # The 17th (at the limit) was taken: only the 18th got an answer.
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c" <> _, _}}
    sync(proc, session)
    assert running(hands) == 1
  end

  test "a call id that was withdrawn is not used again in the turn",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    slow(proc, turn_id, "c1")
    sync(proc, session)
    :erlang.suspend_process(hands)
    send(proc, {:cancel, turn_id, "c1"})
    request(proc, turn_id, "c1", "upcase", %{"text" => "new"})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "c1", {:error, "the call id was used before" <> _}}}

    :erlang.resume_process(hands)
    # The killed run's result is dropped, and the next request runs.
    request(proc, turn_id, "c2", "upcase", %{"text" => "b"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c2", {:ok, "B"}}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c1", _}}
  end

  test "an answered call id gets an error in its turn, and a new turn can use it again",
       %{session: session, proc: proc, turn_id: turn_id} do
    request(proc, turn_id, "c1", "upcase", %{"text" => "a"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c1", {:ok, "A"}}}
    request(proc, turn_id, "c1", "upcase", %{"text" => "b"})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "c1", {:error, "the call id was used before" <> _}}}

    send(proc, {:finish, turn_id})
    collect_until(:agent_end)
    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^proc, {:turn, next, _}}
    request(proc, next, "c1", "upcase", %{"text" => "c"})
    assert_receive {:conn, :tool_result, _, {:tool_result, ^next, "c1", {:ok, "C"}}}
  end

  test "a second request with the id of an open request stops the provider process",
       %{proc: proc, turn_id: turn_id} do
    ref = Process.monitor(proc)
    slow(proc, turn_id, "c1")
    slow(proc, turn_id, "c1")
    assert_receive {:DOWN, ^ref, :process, ^proc, _reason}
  end

  test "a request of a turn that is not live gets aborted and runs nothing",
       %{proc: proc, turn_id: turn_id, hands: hands} do
    send(proc, {:finish, turn_id})
    collect_until(:agent_end)

    request(proc, turn_id, "late", "upcase", %{"text" => "x"})
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "late", {:error, "aborted"}}}
    assert running(hands) == 0
  end

  test "an argument with an integer over the limit is not run",
       %{proc: proc, turn_id: turn_id} do
    big = String.to_integer(String.duplicate("9", 5_000))
    request(proc, turn_id, "c1", "upcase", %{"text" => "x", "n" => big})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "c1", {:error, "tool call not run" <> _}}}
  end

  test "a withdrawn request stops its run, drops its result, and the next one runs",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    slow(proc, turn_id, "c1")
    slow(proc, turn_id, "c2")
    request(proc, turn_id, "c3", "upcase", %{"text" => "c"})
    sync(proc, session)
    assert running(hands) == 1

    send(proc, {:cancel, turn_id, "c2"})
    send(proc, {:cancel, turn_id, "c1"})

    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c3", {:ok, "C"}}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c1", _}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "c2", _}}
  end

  test "an abort kills the running tool, answers the open requests before the interrupt",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    slow(proc, turn_id, "c1")
    slow(proc, turn_id, "c2")
    sync(proc, session)

    :ok = Session.abort(session)

    requests = requests_until(:interrupt)

    assert Enum.take(requests, -3) |> Enum.map(&elem(&1, 0)) ==
             [:tool_result, :tool_result, :interrupt]

    assert {:tool_result, ^turn_id, _, {:error, "aborted"}} = Enum.at(requests, -2)
    assert running(hands) == 0
    assert Process.alive?(proc)
  end

  test "a crash of the provider process ends the turn and kills the running tool",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    slow(proc, turn_id, "c1")
    sync(proc, session)
    send(proc, :stop)

    events = collect_until(:agent_end)
    assert List.last(events).data.stop_reason == :error
    # The session asks the hands for the cleanup after it emits agent_end.
    GenServer.call(Session.pid(session), :snapshot).model
    assert running(hands) == 0
  end

  test "a normal end with a tool still running answers it aborted and runs the cleanup",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    slow(proc, turn_id, "c1")
    slow(proc, turn_id, "c2")
    sync(proc, session)
    send(proc, {:finish, turn_id})

    assert List.last(collect_until(:agent_end)).data.stop_reason == :end_turn
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "c1", {:error, "aborted"}}}
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "c2", {:error, "aborted"}}}

    # The next turn starts only after the cleanup.
    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^proc, _}
    assert running(hands) == 0
  end

  test "the loop's own answer that the provider does not reply to in its callback stops the provider process",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "conn/tools_late")
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _context}}
    ref = Process.monitor(proc)
    slow(proc, turn_id, "c1")
    sync(proc, session)
    send(proc, {:finish, turn_id})

    assert_receive {:conn, :tool_result, ^proc,
                    {:tool_result, ^turn_id, "c1", {:error, "aborted"}}}

    assert_receive {:DOWN, ^ref, :process, ^proc, _reason}
  end

  test "a tool result that the provider does not reply to in its callback stops the provider process before any interrupt",
       %{core: core} do
    {:ok, session} = Session.start(core, model: "conn/tools_late")
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _context}}
    ref = Process.monitor(proc)
    request(proc, turn_id, "c1", "upcase", %{"text" => "a"})

    assert_receive {:conn, :tool_result, ^proc, {:tool_result, ^turn_id, "c1", {:ok, "A"}}}
    assert_receive {:DOWN, ^ref, :process, ^proc, _reason}
    :ok = Session.abort(session)
    refute_received {:conn, :interrupt, _, _}
  end

  test "a tool result is written with 8 other requests open", %{core: core} do
    {:ok, session} = Session.start(core, model: "conn/steer_hold")
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _context}}

    for i <- 1..8 do
      Session.steer(session, "s#{i}")
      assert_receive {:conn, :steer, ^proc, _}
    end

    request(proc, turn_id, "c1", "upcase", %{"text" => "a"})
    assert_receive {:conn, :tool_result, ^proc, {:tool_result, ^turn_id, "c1", {:ok, "A"}}}
    assert Process.alive?(proc)
  end

  test "a call id that got the limit error never runs later in the turn",
       %{session: session, proc: proc, turn_id: turn_id} do
    for i <- 1..17, do: slow(proc, turn_id, "c#{i}")
    request(proc, turn_id, "x", "upcase", %{"text" => "x"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "too many" <> _}}}

    send(proc, {:cancel, turn_id, "c2"})
    request(proc, turn_id, "x", "upcase", %{"text" => "x"})

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "x", {:error, "the call id was used before" <> _}}}

    sync(proc, session)
    refute "x" in queued(session)
  end

  test "one batch: a request over the limit, its withdraw, a free slot, and the same id again",
       %{session: session, proc: proc, turn_id: turn_id} do
    for i <- 1..17, do: slow(proc, turn_id, "c#{i}")
    sync(proc, session)
    x = {:event, turn_id, {:tool_request, "x", "upcase", %{"text" => "x"}}}

    send(
      proc,
      {:batch, [x, {:cancel_tool, turn_id, "x"}, {:cancel_tool, turn_id, "c2"}, x]}
    )

    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "too many" <> _}}}

    assert_receive {:conn, :tool_result, _,
                    {:tool_result, _, "x", {:error, "the call id was used before" <> _}}}

    sync(proc, session)
    assert queued(session) == ["c1"]
  end

  # Waits until the mailbox of `pid` holds a message that `match?` finds;
  # the process is suspended, so the message stays there. Polls every 10 ms,
  # for at least `ms`.
  defp in_mailbox(pid, match?, ms \\ wait_ms())
  defp in_mailbox(_pid, _match?, ms) when ms <= 0, do: flunk("no such message in the mailbox")

  defp in_mailbox(pid, match?, ms) do
    {:messages, messages} = Process.info(pid, :messages)

    unless Enum.any?(messages, match?) do
      Process.sleep(10)
      in_mailbox(pid, match?, ms - 10)
    end
  end

  test "a waiting call that got aborted at the terminal never starts, when the running call's result came first",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = Session.pid(session)
    slow(proc, turn_id, "c1", 200)
    slow(proc, turn_id, "x")
    sync(proc, session)

    :erlang.suspend_process(pid)
    in_mailbox(pid, &match?({:tool_result, _, "c1", _}, &1))
    send(proc, {:finish, turn_id})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "aborted"}}}

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    collect_until(:agent_end)
    sync(proc, session)

    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a call that the loop sent and then answered aborted at the terminal never starts",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = Session.pid(session)
    slow(proc, turn_id, "c1", 200)
    slow(proc, turn_id, "x")
    sync(proc, session)

    :erlang.suspend_process(proc)
    in_mailbox(proc, &match?({:provider_request, _, _, {:tool_result, _, "c1", _}}, &1))
    :erlang.suspend_process(pid)
    send(proc, {:finish, turn_id})
    :erlang.resume_process(proc)
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "x", {:error, "aborted"}}}

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    collect_until(:agent_end)
    sync(proc, session)

    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a call withdrawn after the loop sent it and before the ask never starts, and the next one runs",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = Session.pid(session)
    slow(proc, turn_id, "c1", 200)
    slow(proc, turn_id, "x")
    request(proc, turn_id, "y", "upcase", %{"text" => "y"})
    sync(proc, session)

    :erlang.suspend_process(proc)
    in_mailbox(proc, &match?({:provider_request, _, _, {:tool_result, _, "c1", _}}, &1))
    :erlang.suspend_process(pid)
    :erlang.resume_process(proc)
    send(proc, {:cancel, turn_id, "x"})
    send(proc, {:ping, self()})
    assert_receive :pong

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "y", {:ok, "Y"}}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "an ask with no answer before its deadline stops the provider process and runs nothing",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = Session.pid(session)
    :sys.replace_state(pid, &put_in(&1.provider_ms.tool_start, 100))
    :erlang.suspend_process(pid)
    request(proc, turn_id, "c1", "upcase", %{"text" => "c"})
    send(proc, {:ping, self()})
    assert_receive :pong
    ref = Process.monitor(proc)
    :erlang.suspend_process(proc)

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    assert_receive {:DOWN, ^ref, :process, ^proc, :killed}
    events = collect_until(:agent_end)
    assert List.last(events).data.stop_reason == :error
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "c1"}}}, _}
  end

  # Holds the ask of `x` in the mailbox of the suspended provider process.
  defp hold_ask(session, proc, turn_id) do
    pid = Session.pid(session)
    :erlang.suspend_process(pid)
    request(proc, turn_id, "x", "upcase", %{"text" => "x"})
    send(proc, {:ping, self()})
    assert_receive :pong
    :erlang.suspend_process(proc)
    :erlang.resume_process(pid)
    in_mailbox(proc, &match?({:provider_request, _, _, {:tool_start, _, "x"}}, &1))
    pid
  end

  test "a terminal after the ok to the ask does not answer the call; the result of its run does, before the next turn",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = hold_ask(session, proc, turn_id)
    :erlang.suspend_process(pid)
    send(proc, {:finish, turn_id})
    :erlang.resume_process(proc)
    send(proc, {:ping, self()})
    assert_receive :pong
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}

    :erlang.trace(pid, true, [:send])
    :erlang.resume_process(pid)
    collect_until(:agent_end)
    assert_receive {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "x", {:error, "aborted"}}}

    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^proc, {:turn, _next, _context}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}
  end

  test "an abort during the ask answers the call once and runs nothing",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = hold_ask(session, proc, turn_id)
    :erlang.trace(pid, true, [:send])
    task = Task.async(fn -> Session.abort(session) end)
    in_mailbox(proc, &match?({:provider_request, _, _, {:tool_result, _, "x", _}}, &1))
    :erlang.resume_process(proc)
    assert :ok = Task.await(task, wait_ms())

    assert [{:tool_result, ^turn_id, "x", {:error, "aborted"}}, {:interrupt, ^turn_id}] =
             Enum.take(requests_until(:interrupt), -2)

    GenServer.call(Session.pid(session), :snapshot).model
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a provider process that dies during the ask fails the turn and runs nothing",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = hold_ask(session, proc, turn_id)
    :erlang.trace(pid, true, [:send])
    Process.exit(proc, :kill)
    events = collect_until(:agent_end)
    assert List.last(events).data.stop_reason == :error
    GenServer.call(Session.pid(session), :snapshot).model
    refute_received {:trace, ^pid, :send, {:"$gen_cast", {:run, _, %{id: "x"}}}, _}
  end

  test "a next turn waits for the answer of the call whose ask was open at the abort",
       %{session: session, proc: proc, turn_id: turn_id} do
    hold_ask(session, proc, turn_id)
    task = Task.async(fn -> Session.abort(session) end)
    in_mailbox(proc, &match?({:provider_request, _, _, {:tool_result, _, "x", _}}, &1))
    :ok = Session.prompt(session, "again")
    GenServer.call(Session.pid(session), :snapshot).model
    {:messages, held} = Process.info(proc, :messages)
    refute Enum.any?(held, &match?({:provider_request, _, _, {:turn, _, _}}, &1))

    :erlang.resume_process(proc)
    assert :ok = Task.await(task, wait_ms())

    assert [
             {:tool_result, ^turn_id, "x", {:error, "aborted"}},
             {:interrupt, ^turn_id},
             {:turn, _, _}
           ] =
             Enum.take(requests_until(:turn), -3)
  end

  test "a started call that the provider withdraws after the terminal gets no answer",
       %{session: session, proc: proc, turn_id: turn_id} do
    pid = hold_ask(session, proc, turn_id)
    :erlang.suspend_process(pid)
    send(proc, {:finish, turn_id})
    :erlang.resume_process(proc)
    send(proc, {:cancel, turn_id, "x"})
    send(proc, {:ping, self()})
    assert_receive :pong

    :erlang.resume_process(pid)
    collect_until(:agent_end)
    :ok = Session.prompt(session, "again")
    assert_receive {:conn, :turn, ^proc, {:turn, _next, _context}}
    refute_received {:conn, :tool_result, _, {:tool_result, _, "x", _}}
  end
end
