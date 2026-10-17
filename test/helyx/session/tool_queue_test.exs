defmodule Helyx.Session.ToolQueueTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Session.ToolQueue

  defp call(id), do: %ToolCall{id: id, name: "t", arguments: %{}}

  @max 8 * 1_048_576

  defp request!(tools, id, rejection \\ nil, bytes \\ 10, concurrent? \\ false) do
    {:ok, step} = ToolQueue.request(tools, call(id), bytes, rejection, concurrent?)
    step
  end

  # The queue after requests of `ids`, with their effects dropped.
  defp after_requests(ids, concurrent? \\ false, tools \\ %ToolQueue{}),
    do: Enum.reduce(ids, tools, &elem(request!(&2, &1, nil, 10, concurrent?), 0))

  defp ids(effects), do: for({:run, %ToolCall{id: id}} <- effects, do: id)
  defp waiting(tools), do: Enum.map(tools.waiting, &elem(&1, 0).id)

  describe "request/5" do
    test "the first serial request runs, the next ones wait in order" do
      assert {tools, [{:run, %ToolCall{id: "c1"}}]} = request!(%ToolQueue{}, "c1")
      assert {tools, []} = request!(tools, "c2")
      assert {tools, []} = request!(tools, "c3", nil, 10, true)
      assert Map.keys(tools.running) == ["c1"]
      assert waiting(tools) == ["c2", "c3"]
    end

    test "concurrent requests run together; a serial one waits, and the ones after it too" do
      tools = after_requests(["a1", "a2"], true)
      assert Map.keys(tools.running) == ["a1", "a2"]
      {tools, []} = request!(tools, "s")
      assert {tools, []} = request!(tools, "a3", nil, 10, true)
      assert waiting(tools) == ["s", "a3"]
    end

    test "at most 8 run; the 9th waits" do
      tools = after_requests(for(i <- 1..8, do: "a#{i}"), true)
      assert map_size(tools.running) == 8
      assert {tools, []} = request!(tools, "a9", nil, 10, true)
      assert waiting(tools) == ["a9"]
    end

    test "over 8 running and 16 waiting, a request gets an error and changes nothing" do
      full = after_requests(for(i <- 1..24, do: "c#{i}"), true)
      assert {map_size(full.running), length(full.waiting)} == {8, 16}

      assert {^full, [{:result, "c25", {:error, "too many Helyx tool calls: 8 run and 16 wait"}}]} =
               request!(full, "c25", nil, 10, true)

      serial = after_requests(for(i <- 1..17, do: "c#{i}"))
      assert length(serial.waiting) == 16
      assert {^serial, [{:result, "c18", {:error, "too many" <> _}}]} = request!(serial, "c18")
    end

    test "a rejected request gets its error and runs nothing, even with no call running" do
      assert {%ToolQueue{running: running}, [{:result, "c1", {:error, "tool call not run: bad"}}]} =
               request!(%ToolQueue{}, "c1", "bad")

      assert running == %{}
    end

    test "an id that runs or waits is open; an answered id runs again" do
      tools = after_requests(["c1", "c2"])
      assert ToolQueue.request(tools, call("c1"), 10, nil, false) == :open
      assert ToolQueue.request(tools, call("c2"), 10, "bad", true) == :open

      {tools, _} = ToolQueue.result(after_requests(["c1"]), "c1", {:ok, "a"})
      assert {_, [{:run, %ToolCall{id: "c1"}}]} = request!(tools, "c1")
    end

    test "a request over the byte sum of the open calls gets an error; the next one under it waits" do
      {tools, _} = request!(%ToolQueue{}, "c1", nil, div(@max, 2))
      {tools, []} = request!(tools, "c2", nil, div(@max, 4))

      assert {^tools, [{:result, "c3", {:error, "Helyx tool calls too large" <> _}}]} =
               request!(tools, "c3", nil, div(@max, 4) + 1)

      assert {tools, []} = request!(tools, "c4", nil, div(@max, 4))
      assert waiting(tools) == ["c2", "c4"]
    end

    test "the byte sum counts every running call" do
      {tools, _} = request!(%ToolQueue{}, "a1", nil, div(@max, 2), true)
      {tools, [{:run, _}]} = request!(tools, "a2", nil, div(@max, 2), true)

      assert {_, [{:result, "a3", {:error, "Helyx tool calls too large" <> _}}]} =
               request!(tools, "a3", nil, 1, true)
    end

    test "a single request over the bound is rejected with no call open; one at it runs" do
      assert {%ToolQueue{running: running},
              [{:result, "c1", {:error, "Helyx tool calls too large" <> _}}]} =
               request!(%ToolQueue{}, "c1", nil, @max + 1)

      assert running == %{}
      assert {_, [{:run, _}]} = request!(%ToolQueue{}, "c1", nil, @max)
    end

    test "the bytes of a call leave the sum at its result" do
      {tools, _} = request!(%ToolQueue{}, "c1", nil, @max - 1)
      {tools, _} = request!(tools, "c2", nil, 1)
      assert {_, [{:result, "c3", {:error, _}}]} = request!(tools, "c3", nil, 1)

      # The result of c1 frees its bytes, and c2 runs.
      {tools, _} = ToolQueue.result(tools, "c1", {:ok, "a"})
      assert {_, []} = request!(tools, "c3", nil, @max - 1)
    end
  end

  describe "result/3" do
    test "answers the running call and runs the next waiting one" do
      assert {tools, [{:result, "c1", {:ok, "a"}}, {:run, %ToolCall{id: "c2"}}]} =
               ToolQueue.result(after_requests(["c1", "c2"]), "c1", {:ok, "a"})

      assert {%ToolQueue{waiting: []} = tools, [{:result, "c2", {:error, "e"}}]} =
               ToolQueue.result(tools, "c2", {:error, "e"})

      assert tools.running == %{}
    end

    test "a serial call starts only at the last running result, then runs alone" do
      tools = after_requests(["a1", "a2"], true)
      tools = after_requests(["s"], false, tools)
      tools = after_requests(["a3", "a4"], true, tools)

      assert {tools, [{:result, "a2", {:ok, "b"}}]} = ToolQueue.result(tools, "a2", {:ok, "b"})
      assert {tools, [{:result, "a1", _} | runs]} = ToolQueue.result(tools, "a1", {:ok, "a"})
      assert ids(runs) == ["s"]
      assert {_tools, [{:result, "s", _} | runs]} = ToolQueue.result(tools, "s", {:ok, "s"})
      # The concurrent calls after it start together.
      assert ids(runs) == ["a3", "a4"]
    end

    test "a result under the cap starts the first waiting call, in arrival order" do
      tools = after_requests(for(i <- 1..10, do: "a#{i}"), true)
      assert {tools, [{:result, "a3", _} | runs]} = ToolQueue.result(tools, "a3", {:ok, "x"})
      assert ids(runs) == ["a9"]
      assert waiting(tools) == ["a10"]
    end
  end

  describe "end_turn/1" do
    test "each running and waiting call gets aborted" do
      tools = after_requests(["a1", "a2"], true)
      tools = after_requests(["s"], false, tools)

      assert Enum.sort(ToolQueue.end_turn(tools)) == [
               {:result, "a1", {:error, "aborted"}},
               {:result, "a2", {:error, "aborted"}},
               {:result, "s", {:error, "aborted"}}
             ]

      assert ToolQueue.end_turn(%ToolQueue{}) == []
    end
  end
end
