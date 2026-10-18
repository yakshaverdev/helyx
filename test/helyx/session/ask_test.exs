defmodule Helyx.Session.AskTest do
  # A tool call asks the clients and waits for the first answer
  # (`Helyx.Tool.ask/1`, `Helyx.Session.answer/3`,
  # docs/features/question-tool.md).
  use ExUnit.Case, async: true

  import Helyx.Test.Events, only: [collect_until: 1, of_type: 2, snapshot: 1, wait_until: 1]
  import Helyx.Test.SessionCase, only: [start_core: 1, final_text: 1]

  alias Helyx.{Event, Message, Session}

  setup do
    %{core: start_core([Helyx.Test.Provider, Helyx.Test.Tool.Ask])}
  end

  defp start(core, model, subscribe_opts \\ [answers: true]) do
    {:ok, session} = Session.start(core, model: "test/#{model}")
    {:ok, _snapshot, _ref} = Session.subscribe(session, subscribe_opts)
    :ok = Session.prompt(session, "go")
    session
  end

  defp results(events),
    do:
      for(
        %{message: m} <- of_type(events, :tool_execution_end),
        do: {m.is_error, Message.text(m)}
      )

  # A JSON object whose JSON has `bytes` bytes: `{"t":"` and `"}` around the text.
  defp answer_of(bytes), do: %{"t" => String.duplicate("a", bytes - 8)}

  test "the first answer goes to the call, a later one finds no ask", %{core: core} do
    session = start(core, "ask")

    assert %Event{data: ask, turn_id: turn_id} = List.last(collect_until(:ask))
    assert ask == %{call_id: "a1", tool: "ask", request: %{"q" => "one"}}
    assert turn_id != nil
    assert snapshot(session).asks == [ask]

    assert Session.answer(session, "a1", %{"pick" => ["x"], "n" => 1.5}) == :ok
    assert Session.answer(session, "a1", %{"pick" => ["y"]}) == {:error, :not_waiting}

    events = collect_until(:turn_end)
    assert of_type(events, :ask_end) == [%{call_id: "a1", outcome: :answered}]
    assert results(events) == [{false, ~s({"n":1.5,"pick":["x"]})}]
    assert final_text(events) == ~s({"n":1.5,"pick":["x"]})
    assert snapshot(session).asks == []
  end

  test "with no subscriber that can answer, the ask returns at once", %{core: core} do
    start(core, "ask", [])
    events = collect_until(:turn_end)

    assert of_type(events, :ask) == []
    assert results(events) == [{true, "no_client"}]
  end

  test "a subscriber that can answer counts only while it is subscribed", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ask")
    test = self()

    client =
      spawn(fn ->
        {:ok, _, _} = Session.subscribe(session, answers: true)
        send(test, :subscribed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :subscribed
    send(client, :stop)
    wait_until(fn -> :sys.get_state(Session.pid(session)).subscribers == %{} end)

    {:ok, _snapshot, _ref} = Session.subscribe(session)
    :ok = Session.prompt(session, "go")
    assert results(collect_until(:turn_end)) == [{true, "no_client"}]
  end

  test "an abort ends the ask before turn_end, and the call is aborted", %{core: core} do
    session = start(core, "ask")
    collect_until(:ask)

    :ok = Session.abort(session)
    events = collect_until(:turn_end)

    assert of_type(events, :ask_end) == [%{call_id: "a1", outcome: :ended}]
    types = Enum.map(events, & &1.type)
    assert Enum.find_index(types, &(&1 == :ask_end)) < Enum.find_index(types, &(&1 == :turn_end))
    assert results(events) == [{true, "aborted"}]
    assert Session.answer(session, "a1", %{}) == {:error, :not_waiting}
    assert snapshot(session).asks == []
  end

  test "two calls ask at once; each answer ends its own ask", %{core: core} do
    session = start(core, "ask2")
    asks = of_type(collect_until(:ask) ++ collect_until(:ask), :ask)

    assert Enum.sort_by(asks, & &1.call_id) == [
             %{call_id: "a1", tool: "ask", request: %{"q" => "one"}},
             %{call_id: "a2", tool: "ask", request: %{"q" => "two"}}
           ]

    assert snapshot(session).asks == asks

    assert Session.answer(session, "a2", %{"to" => "two"}) == :ok
    assert [%{call_id: "a2", outcome: :answered}] = of_type(collect_until(:ask_end), :ask_end)
    assert snapshot(session).asks == Enum.reject(asks, &(&1.call_id == "a2"))

    assert Session.answer(session, "a1", %{"to" => "one"}) == :ok
    events = collect_until(:turn_end)
    assert Enum.sort(results(events)) == [{false, ~s({"to":"one"})}, {false, ~s({"to":"two"})}]
  end

  @tag :capture_log
  test "a call that ends while it asks ends its ask; the other ask stays", %{core: core} do
    session = start(core, "ask2")
    collect_until(:ask)
    collect_until(:ask)
    # The caller of the ask is the Task of the call.
    %{activity: %{asks: asks}} = :sys.get_state(Session.pid(session))
    {"a1", {task, _tag}, _ask} = List.keyfind(asks, "a1", 0)
    Process.exit(task, :kill)

    assert [%{call_id: "a1", outcome: :ended}] = of_type(collect_until(:ask_end), :ask_end)
    assert [%{call_id: "a2"}] = snapshot(session).asks
    assert Session.answer(session, "a1", %{}) == {:error, :not_waiting}

    assert Session.answer(session, "a2", %{"to" => "two"}) == :ok

    assert [{false, ~s({"to":"two"})}, {true, "tool crashed: :killed"}] =
             Enum.sort(results(collect_until(:turn_end)))
  end

  @tag :capture_log
  test "a request that is not a JSON object fails the call as a raise", %{core: core} do
    start(core, "ask_bad")
    events = collect_until(:turn_end)

    assert of_type(events, :ask) == []
    assert results(events) == [{true, "an ask request is a JSON object of at most 64 KiB"}]
  end

  test "a request of at most 64 KiB of JSON goes to the session", %{core: core} do
    Process.put(:helyx_call, %{core: core, session_id: "s1", call_id: "c1", tool: "ask"})
    test = self()

    # A session process that answers with the request.
    spawn_link(fn ->
      {:ok, _} = Registry.register(Helyx.Core.sessions_registry(core), "s1", nil)
      send(test, :registered)

      receive do
        {:"$gen_call", from, {:ask, "c1", "ask", request}} ->
          GenServer.reply(from, {:ok, request})
      end
    end)

    assert_receive :registered
    assert_raise ArgumentError, fn -> Helyx.Tool.ask(answer_of(65_537)) end
    assert Helyx.Tool.ask(answer_of(65_536)) == {:ok, answer_of(65_536)}
  end

  test "an ask of no running call of the turn gets not_running", %{core: core} do
    {:ok, session} = Session.start(core, model: "test/ask")
    {:ok, _snapshot, _ref} = Session.subscribe(session, answers: true)

    assert GenServer.call(Session.pid(session), {:ask, "a1", "ask", %{}}) ==
             {:error, :not_running}
  end

  test "an answer is a JSON object of valid UTF-8 of at most 16 KiB", %{core: core} do
    session = start(core, "ask")
    collect_until(:ask)

    for bad <- [
          "text",
          [1],
          %{q: "atom key"},
          %{"q" => <<255>>},
          %{<<255>> => 1},
          %{"q" => :atom},
          %{"q" => {1, 2}},
          %{"q" => [1 | 2]},
          %{"q" => 10 ** 100},
          %{"q" => self()},
          URI.parse("http://x"),
          answer_of(16_385),
          %{"q" => String.duplicate("é", 8_189)}
        ] do
      assert Session.answer(session, "a1", bad) == {:error, :invalid_answer}
    end

    assert byte_size(JSON.encode!(answer_of(16_384))) == 16_384
    assert Session.answer(session, "a1", answer_of(16_384)) == :ok
    assert [{false, text}] = results(collect_until(:turn_end))
    assert byte_size(text) == 16_384
  end

  test "an answer to a session that is not running finds none", %{core: core} do
    session = %Session{id: "nosuchsessi0", core: core}
    assert Session.answer(session, "a1", %{}) == {:error, :session_not_found}
  end
end
