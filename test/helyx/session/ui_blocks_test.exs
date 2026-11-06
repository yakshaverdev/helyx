defmodule Helyx.Session.UIBlocksTest.Result do
  @moduledoc false
  # Returns the UI blocks that its "mode" names: "n.<k>", k small blocks;
  # "max" and "big", one block with an integer of 100 or 101 digits; "huge",
  # one block over the byte bound; "error", an error result with one block;
  # "none", an empty list.
  use Helyx.Test.Tool, name: "result", description: "Returns UI blocks."

  def block(i), do: %{"kind" => "progress", "text" => "b#{i}", "i" => i}

  @impl true
  def run(%{"mode" => "n." <> k}, _cwd),
    do: {:ok, "r", Enum.map(1..String.to_integer(k), &block/1)}

  def run(%{"mode" => "max"}, _cwd), do: {:ok, "r", [Map.put(block(1), "n", 10 ** 100 - 1)]}
  def run(%{"mode" => "big"}, _cwd), do: {:ok, "r", [Map.put(block(1), "n", 10 ** 100)]}

  def run(%{"mode" => "huge"}, _cwd),
    do: {:ok, "r", [%{"kind" => "table", "text" => String.duplicate("x", 70_000)}]}

  def run(%{"mode" => "error"}, _cwd), do: {:error, "e", [block(1)]}
  def run(%{"mode" => "none"}, _cwd), do: {:ok, "r", []}
end

defmodule Helyx.Session.UIBlocksTest.Show do
  @moduledoc false
  # Shows a block for each [key, spec] of "shows" with `Helyx.Tool.show/2`,
  # then, with "gate", waits for the gate (`Helyx.Test.Gate`), then shows
  # each of "after". Gives the inspected replies, joined with ",". A spec is "max" or "big" for a
  # block with an integer of 100 or 101 digits, "huge" for a block over the
  # byte bound, and any other text for a block with that text.
  use Helyx.Test.Tool, name: "show", description: "Shows UI blocks."

  def block("max"), do: %{"kind" => "progress", "text" => "max", "n" => 10 ** 100 - 1}
  def block("big"), do: %{"kind" => "progress", "text" => "big", "n" => 10 ** 100}
  def block("huge"), do: %{"kind" => "table", "text" => String.duplicate("x", 70_000)}
  def block(text), do: %{"kind" => "progress", "text" => text}

  @impl true
  def run(%{"shows" => shows} = args, _cwd) do
    replies = for [key, spec] <- shows, do: Helyx.Tool.show(key, block(spec))
    with %{"gate" => gate} <- args, do: {:ok, "done"} = Helyx.Test.Gate.wait(gate)
    later = for [key, spec] <- Map.get(args, "after", []), do: Helyx.Tool.show(key, block(spec))
    {:ok, Enum.map_join(replies ++ later, ",", &inspect/1)}
  end
end

defmodule Helyx.Session.UIBlocksTest.Background do
  @moduledoc false
  # A background run: takes a place, answers "started", waits for the gate
  # in "gate", then ends with a text and one UI block.
  use Helyx.Test.Tool, name: "bg_blocks", description: "Runs in the background."

  def block, do: %{"kind" => "progress", "text" => "end"}

  @impl true
  def run(%{"gate" => gate}, _cwd) do
    {:ok, _place} = Helyx.Tool.background()
    :ok = Helyx.Tool.started("started")
    {:ok, "done"} = Helyx.Test.Gate.wait(gate)
    {:ok, "finished", [block()]}
  end
end

defmodule Helyx.Session.UIBlocksTest do
  # UI blocks in a session (docs/features/ui-blocks.md, ADR 0011): in a
  # tool result, in `:ui_block` events from a tool call and from the
  # provider, in the snapshot, in the request of an ask, and through the
  # session file. Driven with the connected test provider, which reports
  # each request of the session and sends the events that the test gives.
  use ExUnit.Case, async: true

  import Helyx.Test.Events

  alias Helyx.Message.ToolCall
  alias Helyx.Session
  alias Helyx.Session.UIBlocksTest.{Background, Result, Show}
  alias Helyx.Test.Connected

  @outside "the tool returned a value outside its contract"

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Connected, Result, Show, Background]})
    Process.register(self(), Connected.controller(core))
    %{core: core}
  end

  # A session of the "tools" model in a turn: its provider process and the turn id.
  defp started(core, opts \\ []) do
    {:ok, session} = Session.start(core, [model: "conn/tools"] ++ opts)
    {:ok, _, _} = Session.subscribe(session)
    turn(session)
  end

  defp turn(session) do
    :ok = Session.prompt(session, "go")
    assert_receive {:conn, :turn, proc, {:turn, turn_id, _context}}
    %{session: session, proc: proc, turn_id: turn_id}
  end

  defp events(proc, turn_id, events),
    do: send(proc, {:batch, Enum.map(events, &{:event, turn_id, &1})})

  # A call of the provider's message that asks the session to run a Helyx tool.
  defp request(%{proc: proc, turn_id: turn_id}, id, name, args) do
    events(proc, turn_id, [
      {:tool_call, %ToolCall{id: id, name: name, arguments: args}},
      {:message_end, :tool_use, nil},
      {:tool_request, id, name, args}
    ])
  end

  # The provider's request with the result of call `id`, which the provider
  # then gives back as its `tool_result` event. Returns that request's result.
  defp echo_result(%{proc: proc, turn_id: turn_id}, id) do
    assert_receive {:conn, :tool_result, ^proc, {:tool_result, ^turn_id, ^id, result}}
    events(proc, turn_id, [{:tool_result, id, result}])
    result
  end

  defp finish(%{proc: proc, turn_id: turn_id}) do
    send(proc, {:finish, turn_id})
    collect_until(:turn_end)
  end

  # The events up to and including the `n`-th of `type`.
  defp collect_n(type, n), do: Enum.flat_map(1..n//1, fn _ -> collect_until(type) end)

  # The test process is the controller, so a proxy holds the name of the
  # gate (`Helyx.Test.Gate`) and forwards each wait.
  defp gate do
    test = self()
    gate = :"gate_#{System.unique_integer([:positive])}"

    spawn_link(fn ->
      Process.register(self(), gate)
      send(test, :registered)
      forward_waits(test)
    end)

    assert_receive :registered
    Atom.to_string(gate)
  end

  defp forward_waits(test) do
    receive do: ({:waiting, run} -> send(test, {:waiting, run}))
    forward_waits(test)
  end

  defp ui(call_id, key, block), do: %{call_id: call_id, key: key, block: block}

  # The provider process sent its events before the pong, and the snapshot
  # call reaches the session after them.
  defp sync(%{proc: proc, session: session}) do
    send(proc, {:ping, self()})
    assert_receive :pong
    snapshot(session)
  end

  describe "in a tool result" do
    test "the blocks reach the message and tool_execution_end, not the provider's request",
         %{core: core} do
      turn = started(core)
      request(turn, "c1", "result", %{"mode" => "n.2"})

      assert echo_result(turn, "c1") == {:ok, "r"}
      [%{message: message}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert message.ui_blocks == [Result.block(1), Result.block(2)]
      assert message.content == [%Helyx.Message.Text{text: "r"}]

      finish(turn)
      transcript = :sys.get_state(Session.pid(turn.session)).transcript
      assert [_user, _assistant, %{role: :tool_result} = result, _last] = transcript
      assert result.ui_blocks == message.ui_blocks
      assert result.id == message.id
    end

    test "an error result keeps its blocks; an empty list gives none", %{core: core} do
      turn = started(core)
      request(turn, "c1", "result", %{"mode" => "error"})
      assert echo_result(turn, "c1") == {:error, "e"}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert {m.is_error, m.ui_blocks} == {true, [Result.block(1)]}

      request(turn, "c2", "result", %{"mode" => "none"})
      assert echo_result(turn, "c2") == {:ok, "r"}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert m.ui_blocks == []
    end

    @tag :capture_log
    test "8 blocks pass; 9 are a return outside the contract", %{core: core} do
      turn = started(core)
      request(turn, "c1", "result", %{"mode" => "n.8"})
      assert echo_result(turn, "c1") == {:ok, "r"}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert m.ui_blocks == Enum.map(1..8, &Result.block/1)

      request(turn, "c2", "result", %{"mode" => "n.9"})
      assert echo_result(turn, "c2") == {:error, @outside}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert {m.is_error, Helyx.Message.text(m), m.ui_blocks} == {true, @outside, []}
    end

    @tag :capture_log
    test "an integer of 100 digits in a block passes; 101 digits is outside the contract",
         %{core: core} do
      turn = started(core)
      request(turn, "c1", "result", %{"mode" => "max"})
      assert echo_result(turn, "c1") == {:ok, "r"}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert [%{"n" => n}] = m.ui_blocks
      assert n == 10 ** 100 - 1

      request(turn, "c2", "result", %{"mode" => "big"})
      assert echo_result(turn, "c2") == {:error, @outside}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert {m.is_error, m.ui_blocks} == {true, []}
    end

    test "a block over the byte bound is cut", %{core: core} do
      turn = started(core)
      request(turn, "c1", "result", %{"mode" => "huge"})
      echo_result(turn, "c1")
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert [%{"kind" => "table", "text" => text, "cut" => true} = block] = m.ui_blocks
      assert map_size(block) == 3
      assert byte_size(JSON.encode!(block)) <= Helyx.UIBlock.max_bytes()
      assert text =~ "x"
    end
  end

  describe "from a tool call, with Helyx.Tool.show/2" do
    test "each block is an event; the same key replaces; the snapshot holds the newest of each",
         %{core: core} do
      turn = started(core)
      gate = gate()
      shows = [["a", "one"], ["b", "two"], ["a", "three"]]
      request(turn, "c1", "show", %{"shows" => shows, "gate" => gate})
      assert_receive {:waiting, run}

      events = collect_n(:ui_block, 3)

      assert of_type(events, :ui_block) == [
               ui("c1", "a", Show.block("one")),
               ui("c1", "b", Show.block("two")),
               ui("c1", "a", Show.block("three"))
             ]

      assert Enum.all?(events, &(&1.turn_id == turn.turn_id))

      # A block of the provider for no call stays after the call's result.
      events(turn.proc, turn.turn_id, [{:ui_block, nil, "p", Show.block("p")}])
      collect_until(:ui_block)

      assert sync(turn).ui_blocks == [
               ui("c1", "a", Show.block("three")),
               ui("c1", "b", Show.block("two")),
               ui(nil, "p", Show.block("p"))
             ]

      send(run, :go)
      assert echo_result(turn, "c1") == {:ok, ":ok,:ok,:ok"}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert m.ui_blocks == []
      assert snapshot(turn.session).ui_blocks == [ui(nil, "p", Show.block("p"))]

      finish(turn)
      assert snapshot(turn.session).ui_blocks == []
    end

    # Round 2 of the #878 review: a result that joins the transcript while
    # the Task runs on, as an `aborted` result at a taken steer does, ends
    # the window of the call's blocks.
    test "a call whose result joined the transcript shows nothing more", %{core: core} do
      turn = started(core)
      gate = gate()
      args = %{"shows" => [["a", "one"]], "gate" => gate, "after" => [["b", "two"]]}
      request(turn, "c1", "show", args)
      assert_receive {:waiting, run}
      assert of_type(collect_until(:ui_block), :ui_block) == [ui("c1", "a", Show.block("one"))]

      events(turn.proc, turn.turn_id, [{:tool_result, "c1", {:ok, "early"}}])
      collect_until(:tool_execution_end)
      assert sync(turn).ui_blocks == []

      send(run, :go)
      assert echo_result(turn, "c1") == {:ok, ":ok,{:error, :not_running}"}
      assert sync(turn).ui_blocks == []
      events = finish(turn)
      assert of_type(events, :ui_block) == []
    end

    # Round 3 of the #878 review: a request for a call with no open tool
    # call runs (#369), but only an open call gets a window.
    test "a request for an answered call shows no block after the call's result",
         %{core: core} do
      turn = started(core)
      request(turn, "c1", "result", %{"mode" => "n.1"})
      assert echo_result(turn, "c1") == {:ok, "r"}
      collect_until(:tool_execution_end)

      events(turn.proc, turn.turn_id, [
        {:tool_request, "c1", "show", %{"shows" => [["k", "again"]]}}
      ])

      assert_receive {:conn, :tool_result, _, {:tool_result, _, "c1", result}}
      assert result == {:ok, "{:error, :not_running}"}
      # The echo finds no open call and is dropped.
      events(turn.proc, turn.turn_id, [{:tool_result, "c1", result}])
      assert sync(turn).ui_blocks == []
      assert of_type(finish(turn), :ui_block) == []
      assert snapshot(turn.session).ui_blocks == []
    end

    test "a request before its tool call gets no window: no block, and no blocks on its result",
         %{core: core} do
      turn = started(core)
      events(turn.proc, turn.turn_id, [{:tool_request, "x1", "show", %{"shows" => [["k", "v"]]}}])
      assert_receive {:conn, :tool_result, _, {:tool_result, _, "x1", shown}}
      assert shown == {:ok, "{:error, :not_running}"}

      events(turn.proc, turn.turn_id, [{:tool_request, "x2", "result", %{"mode" => "n.2"}}])
      assert_receive {:conn, :tool_result, _, {:tool_result, _, "x2", result}}

      # The calls join late: their results carry no blocks.
      events(turn.proc, turn.turn_id, [
        {:tool_call, %ToolCall{id: "x1", name: "show", arguments: %{}}},
        {:tool_call, %ToolCall{id: "x2", name: "result", arguments: %{}}},
        {:message_end, :tool_use, nil},
        {:tool_result, "x1", shown},
        {:tool_result, "x2", result}
      ])

      events = collect_n(:tool_execution_end, 2)
      assert of_type(events, :ui_block) == []
      messages = for %{message: m} <- of_type(events, :tool_execution_end), do: m

      assert Enum.map(messages, & &1.tool_call_id) == ["x1", "x2"]
      assert Enum.all?(messages, &(&1.ui_blocks == []))
      assert of_type(finish(turn), :ui_block) == []
    end

    test "8 keys pass, a known key replaces after them, a 9th key raises", %{core: core} do
      turn = started(core)
      keys = for i <- 1..8, do: ["k#{i}", "v#{i}"]
      request(turn, "c1", "show", %{"shows" => keys ++ [["k1", "again"], ["k9", "v9"]]})

      assert echo_result(turn, "c1") == {:error, "a call shows at most 8 UI blocks"}
      events = collect_until(:tool_execution_end)

      assert of_type(events, :ui_block) ==
               for([key, text] <- keys ++ [["k1", "again"]], do: ui("c1", key, Show.block(text)))
    end

    test "an integer of 100 digits passes; 101 digits raises in the call", %{core: core} do
      turn = started(core)
      request(turn, "c1", "show", %{"shows" => [["a", "max"]]})
      assert echo_result(turn, "c1") == {:ok, ":ok"}
      events = collect_until(:tool_execution_end)
      assert of_type(events, :ui_block) == [ui("c1", "a", Show.block("max"))]

      request(turn, "c2", "show", %{"shows" => [["a", "big"]]})
      assert echo_result(turn, "c2") == {:error, "show/2 needs a UI block"}
      assert of_type(collect_until(:tool_execution_end), :ui_block) == []
    end

    test "a block over the byte bound is cut; a bad key raises", %{core: core} do
      turn = started(core)
      request(turn, "c1", "show", %{"shows" => [["a", "huge"]]})
      echo_result(turn, "c1")

      assert [%{block: %{"kind" => "table", "cut" => true} = block}] =
               of_type(collect_until(:tool_execution_end), :ui_block)

      assert map_size(block) == 3

      long = String.duplicate("k", 65)
      request(turn, "c2", "show", %{"shows" => [[long, "x"]]})
      assert {:error, "a UI block key is" <> _} = echo_result(turn, "c2")
    end

    test "a call that is not running gets not_running", %{core: core} do
      {:ok, session} = Session.start(core, model: "conn/tools")
      Process.put(:helyx_call, %{core: core, session_id: session.id, call_id: "c1"})
      assert Helyx.Tool.show("a", Show.block("x")) == {:error, :not_running}
    end
  end

  describe "from the provider" do
    test "a block for an open call of the provider, or for none, is an event", %{core: core} do
      turn = started(core)

      events(turn.proc, turn.turn_id, [
        {:tool_call, %ToolCall{id: "p1", name: "read", arguments: %{}}},
        {:ui_block, "p1", "a", Show.block("max")},
        {:ui_block, nil, "a", Show.block("one")}
      ])

      events = collect_n(:ui_block, 2)

      assert of_type(events, :ui_block) == [
               ui("p1", "a", Show.block("max")),
               ui(nil, "a", Show.block("one"))
             ]

      assert sync(turn).ui_blocks == [
               ui("p1", "a", Show.block("max")),
               ui(nil, "a", Show.block("one"))
             ]

      # The result of the provider's call takes its blocks with it.
      events(turn.proc, turn.turn_id, [{:tool_result, "p1", {:ok, "read"}}])
      collect_until(:tool_execution_end)
      assert snapshot(turn.session).ui_blocks == [ui(nil, "a", Show.block("one"))]
    end

    test "a block whose call id names no open call, or a Helyx call, is dropped",
         %{core: core} do
      turn = started(core)
      gate = gate()
      request(turn, "c1", "show", %{"shows" => [], "gate" => gate})
      assert_receive {:waiting, run}

      events(turn.proc, turn.turn_id, [
        {:ui_block, "zz", "a", Show.block("unknown")},
        {:ui_block, "c1", "a", Show.block("helyx")},
        {:ui_block, nil, "m", Show.block("marker")}
      ])

      assert of_type(collect_until(:ui_block), :ui_block) == [ui(nil, "m", Show.block("marker"))]

      # A Helyx call whose result joined the transcript is no open call either.
      send(run, :go)
      echo_result(turn, "c1")
      collect_until(:tool_execution_end)

      events(turn.proc, turn.turn_id, [
        {:ui_block, "c1", "a", Show.block("late")},
        {:ui_block, nil, "m2", Show.block("marker")}
      ])

      assert of_type(collect_until(:ui_block), :ui_block) == [
               ui(nil, "m2", Show.block("marker"))
             ]

      assert [_marker, _marker2] = sync(turn).ui_blocks
    end

    test "8 keys for nil and 8 for a call pass; a 9th key stops the provider and fails the turn",
         %{core: core} do
      turn = started(core)
      call = {:tool_call, %ToolCall{id: "p1", name: "read", arguments: %{}}}
      for_id = fn id -> for i <- 1..8, do: {:ui_block, id, "k#{i}", Show.block("v#{i}")} end
      events(turn.proc, turn.turn_id, [call | for_id.(nil) ++ for_id.("p1")])

      assert length(of_type(collect_n(:ui_block, 16), :ui_block)) == 16
      # A known key replaces and is no new key.
      events(turn.proc, turn.turn_id, [{:ui_block, nil, "k1", Show.block("again")}])
      assert [ui(nil, "k1", Show.block("again"))] == of_type(collect_until(:ui_block), :ui_block)

      ref = Process.monitor(turn.proc)
      events(turn.proc, turn.turn_id, [{:ui_block, "p1", "k9", Show.block("v9")}])
      events = collect_until(:turn_end)
      assert of_type(events, :ui_block) == []
      assert List.last(events).data.error =~ "too_many_ui_block_keys"
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert snapshot(turn.session).ui_blocks == []
    end

    test "a 9th key for nil fails the turn too", %{core: core} do
      turn = started(core)
      blocks = for i <- 1..9, do: {:ui_block, nil, "k#{i}", Show.block("v#{i}")}
      events(turn.proc, turn.turn_id, blocks)

      events = collect_until(:turn_end)
      assert length(of_type(events, :ui_block)) == 8
      assert List.last(events).data.error =~ "too_many_ui_block_keys"
    end

    test "an integer of 100 digits passes; 101 digits is a malformed event that fails the turn",
         %{core: core} do
      turn = started(core)
      events(turn.proc, turn.turn_id, [{:ui_block, nil, "a", Show.block("max")}])
      assert of_type(collect_until(:ui_block), :ui_block) == [ui(nil, "a", Show.block("max"))]

      events(turn.proc, turn.turn_id, [{:ui_block, nil, "b", Show.block("big")}])
      events = collect_until(:turn_end)
      assert of_type(events, :ui_block) == []
      assert List.last(events).data.error =~ "{:bad_stream_event, {:ui_block, nil, \"b\""

      # The session lives.
      turn = turn(turn.session)
      assert List.last(finish(turn)).data.outcome == :done
    end

    test "a bad key or a block that is not a UI block is a malformed event", %{core: core} do
      for {key, block} <- [{"", Show.block("x")}, {"a", %{"kind" => "A", "text" => ""}}] do
        turn = started(core)
        events(turn.proc, turn.turn_id, [{:ui_block, nil, key, block}])
        assert List.last(collect_until(:turn_end)).data.error =~ "{:bad_stream_event, {:ui_block"
      end
    end
  end

  describe "a Helyx request and the turn end" do
    @tag :capture_log
    test "a Helyx request for a call that has blocks of the provider stops it and fails the turn",
         %{core: core} do
      turn = started(core)
      ref = Process.monitor(turn.proc)

      events(turn.proc, turn.turn_id, [
        {:tool_call, %ToolCall{id: "c1", name: "result", arguments: %{"mode" => "n.1"}}},
        {:ui_block, "c1", "k", Show.block("shown")},
        {:tool_request, "c1", "result", %{"mode" => "n.1"}}
      ])

      events = collect_until(:turn_end)
      assert of_type(events, :ui_block) == [ui("c1", "k", Show.block("shown"))]
      assert of_type(events, :tool_execution_start) == []
      assert %{outcome: :error, error: error} = List.last(events).data
      assert error =~ "bad_action"
      assert error =~ "tool_request"
      assert_receive {:DOWN, ^ref, :process, _, _}
      refute_received {:conn, :tool_result, _, _}
      assert snapshot(turn.session).ui_blocks == []
    end

    test "a Helyx request for an open call with no blocks runs the tool", %{core: core} do
      turn = started(core)

      events(turn.proc, turn.turn_id, [
        {:tool_call, %ToolCall{id: "c1", name: "result", arguments: %{"mode" => "n.1"}}},
        {:tool_request, "c1", "result", %{"mode" => "n.1"}}
      ])

      assert echo_result(turn, "c1") == {:ok, "r"}
      [%{message: m}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert m.ui_blocks == [Result.block(1)]
      assert List.last(finish(turn)).data.outcome == :done
    end

    # #595: at `done` a Helyx call still runs, so `turn_end` waits for the
    # hands' answer to the cancel request. The hands are suspended to hold
    # that window open; the trace shows that the session sent the request.
    test "a subscribe while turn_end waits for the hands gets the turn's blocks",
         %{core: core} do
      turn = started(core)
      gate = gate()

      events(turn.proc, turn.turn_id, [
        {:tool_request, "c1", "show", %{"shows" => [], "gate" => gate}}
      ])

      assert_receive {:waiting, _run}

      events(turn.proc, turn.turn_id, [{:ui_block, nil, "p", Show.block("p")}])
      assert of_type(collect_until(:ui_block), :ui_block) == [ui(nil, "p", Show.block("p"))]

      hands = :sys.get_state(Session.pid(turn.session)).hands
      turn_id = turn.turn_id
      :ok = :sys.suspend(hands)
      :erlang.trace(hands, true, [:receive])
      send(turn.proc, {:finish, turn_id})
      assert_receive {:trace, ^hands, :receive, {:"$gen_call", _, {:cancel, ^turn_id}}}
      :erlang.trace(hands, false, [:receive])

      held = snapshot(turn.session)
      assert %{id: ^turn_id} = held.turn
      assert held.ui_blocks == [ui(nil, "p", Show.block("p"))]
      refute_received {:helyx_event, %Helyx.Event{type: :turn_end}}

      :ok = :sys.resume(hands)
      assert List.last(collect_until(:turn_end)).data == %{outcome: :done}
      after_end = snapshot(turn.session)
      assert {after_end.turn, after_end.ui_blocks} == {nil, []}
    end
  end

  describe "a background run" do
    test "its start answer and its end carry no UI blocks", %{core: core} do
      turn = started(core)
      gate = gate()
      request(turn, "c1", "bg_blocks", %{"gate" => gate})
      assert_receive {:waiting, run}

      assert {:ok, "<background " <> _} = echo_result(turn, "c1")
      [%{message: start}] = of_type(collect_until(:tool_execution_end), :tool_execution_end)
      assert {start.role, start.ui_blocks} == {:tool_result, []}
      finish(turn)

      send(run, :go)
      assert_receive {:conn, :turn, _proc, {:turn, _turn_id, _context}}

      users =
        for %{message: %{role: :user} = m} <- of_type(collect_until(:message_end), :message_end),
            do: m

      assert [%{origin: %{kind: :background}} = user] = users
      assert user.ui_blocks == []
      assert Helyx.Message.text(user) =~ "finished"

      transcript = :sys.get_state(Session.pid(turn.session)).transcript
      assert [%{ui_blocks: []}] = for(%{role: :tool_result} = m <- transcript, do: m)
      assert Enum.all?(transcript, &(&1.ui_blocks == []))
    end
  end

  describe "the request of an ask" do
    # A session process that answers each ask with its request.
    setup %{core: core} do
      Process.put(:helyx_call, %{core: core, session_id: "s1", call_id: "c1", tool: "ask"})
      test = self()

      spawn_link(fn ->
        {:ok, _} = Registry.register(Helyx.Core.sessions_registry(core), "s1", nil)
        send(test, :registered)
        answer_asks()
      end)

      assert_receive :registered
      :ok
    end

    defp answer_asks do
      receive do
        {:"$gen_call", from, {:ask, "c1", "ask", request}} ->
          GenServer.reply(from, {:ok, request})
          answer_asks()
      end
    end

    test "a request with a kind passes the envelope check, or raises" do
      form = %{"kind" => "form", "text" => "1 question", "n" => 10 ** 100 - 1}
      assert Helyx.Tool.ask(form) == {:ok, form}

      assert_raise ArgumentError, fn -> Helyx.Tool.ask(%{form | "n" => 10 ** 100}) end
      assert_raise ArgumentError, fn -> Helyx.Tool.ask(Map.delete(form, "text")) end
      assert_raise ArgumentError, fn -> Helyx.Tool.ask(%{form | "kind" => "Form"}) end
      assert_raise ArgumentError, fn -> Helyx.Tool.ask(Map.put(form, "cut", "no")) end

      # A request with no kind needs no envelope.
      assert Helyx.Tool.ask(%{"q" => "one"}) == {:ok, %{"q" => "one"}}
    end
  end

  describe "the session file" do
    @describetag :tmp_dir

    test "the blocks of a result round-trip through the file; an empty list writes no key",
         %{core: core, tmp_dir: dir} do
      turn = started(core, sessions_dir: dir)
      request(turn, "c1", "result", %{"mode" => "max"})
      echo_result(turn, "c1")
      collect_until(:tool_execution_end)
      request(turn, "c2", "result", %{"mode" => "none"})
      echo_result(turn, "c2")
      collect_until(:tool_execution_end)
      finish(turn)

      [path] = Path.wildcard(Path.join([dir, "*", turn.session.id <> ".jsonl"]))

      entries =
        for line <- String.split(File.read!(path), "\n", trim: true),
            %{"role" => "tool_result"} = entry <- [JSON.decode!(line)],
            do: entry

      assert [%{"ui_blocks" => [written]}, second] = entries
      assert written["n"] == 10 ** 100 - 1
      refute Map.has_key?(second, "ui_blocks")

      Helyx.Test.SessionCase.stop_session(turn.session, &GenServer.stop/1)
      {:ok, resumed} = Session.resume(core, sessions_dir: dir)
      {:ok, snapshot, _} = Session.subscribe(resumed)

      assert [[%{"n" => n}], []] =
               for(%{role: :tool_result} = m <- snapshot.messages, do: m.ui_blocks)

      assert n == 10 ** 100 - 1
    end
  end
end
