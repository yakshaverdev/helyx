defmodule Helyx.Session.ProviderProcessToolsTest do
  # Helyx tool calls of a connected turn (`docs/features/long-lived-harness.md`,
  # "Helyx tool calls"), driven through the session with the fake connected
  # provider: the session's queue and its rules, and the turn cleanup at an
  # abort, a crash, and a normal end.
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

  defp receive_result do
    assert_receive {:conn, :tool_result, _, request}
    request
  end

  # The tool Tasks of the hands; the provider process is a Task there too.
  defp running(hands),
    do: Enum.count(:sys.get_state(hands).tasks, fn {_ref, {_, _, id, _}} -> is_binary(id) end)

  # The provider process sent its events before the pong, and the snapshot
  # call reaches the session after them.
  defp sync(proc, session) do
    send(proc, {:ping, self()})
    assert_receive :pong
    GenServer.call(Session.pid(session), :snapshot).model
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

  test "a withdrawn request gets aborted: a waiting one at once, the running one after its kill; the next one runs",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    slow(proc, turn_id, "c1")
    slow(proc, turn_id, "c2")
    request(proc, turn_id, "c3", "upcase", %{"text" => "c"})
    sync(proc, session)
    assert running(hands) == 1

    send(proc, {:cancel, "c2"})
    send(proc, {:cancel, "c1"})

    assert [
             {:tool_result, _, "c2", {:error, "aborted"}},
             {:tool_result, _, "c1", {:error, "aborted"}},
             {:tool_result, _, "c3", {:ok, "C"}}
           ] = for(_ <- 1..3, do: receive_result())
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

  test "a request with a call id that the turn answered runs again",
       %{proc: proc, turn_id: turn_id} do
    request(proc, turn_id, "c1", "upcase", %{"text" => "a"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c1", {:ok, "A"}}}
    request(proc, turn_id, "c1", "upcase", %{"text" => "b"})
    assert_receive {:conn, :tool_result, _, {:tool_result, _, "c1", {:ok, "B"}}}
  end

  test "a request that arrives after the interrupt of its turn gets aborted after it and runs nothing",
       %{session: session, proc: proc, turn_id: turn_id, hands: hands} do
    :ok = Session.abort(session)
    assert_receive {:conn, :interrupt, ^proc, {:interrupt, ^turn_id}}

    request(proc, turn_id, "late", "upcase", %{"text" => "x"})
    assert_receive {:conn, :tool_result, _, {:tool_result, ^turn_id, "late", {:error, "aborted"}}}
    assert running(hands) == 0
  end
end
