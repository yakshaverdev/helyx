defmodule Helyx.Session.ToolQueueTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Session.ToolQueue

  defp call(id), do: %ToolCall{id: id, name: "t", arguments: %{}}

  @max 8 * 1_048_576

  defp request!(tools, id, rejection \\ nil, bytes \\ 10) do
    {:ok, step} = ToolQueue.request(tools, call(id), bytes, rejection)
    step
  end

  # The queue after requests of `ids`, with their effects dropped.
  defp after_requests(ids), do: Enum.reduce(ids, %ToolQueue{}, &elem(request!(&2, &1), 0))

  describe "request/4" do
    test "the first request runs, the next ones wait in order" do
      assert {tools, [{:run, %ToolCall{id: "c1"}}]} = request!(%ToolQueue{}, "c1")
      assert {tools, []} = request!(tools, "c2")
      assert {tools, []} = request!(tools, "c3")
      assert tools.running == "c1"
      assert Enum.map(tools.waiting, fn {c, 10} -> c.id end) == ["c2", "c3"]
    end

    test "over one running and 16 waiting, a request gets an error and changes nothing" do
      full = after_requests(for i <- 1..17, do: "c#{i}")
      assert length(full.waiting) == 16

      assert {^full, [{:result, "c18", {:error, "too many Helyx tool calls" <> _}}]} =
               request!(full, "c18")
    end

    test "a rejected request gets its error and runs nothing, even with no call running" do
      assert {%ToolQueue{running: nil}, [{:result, "c1", {:error, "tool call not run: bad"}}]} =
               request!(%ToolQueue{}, "c1", "bad")
    end

    test "an id that runs or waits is open; an answered id runs again" do
      tools = after_requests(["c1", "c2"])
      assert ToolQueue.request(tools, call("c1"), 10, nil) == :open
      assert ToolQueue.request(tools, call("c2"), 10, "bad") == :open

      {tools, _} = ToolQueue.result(after_requests(["c1"]), {:ok, "a"})
      assert {_, [{:run, %ToolCall{id: "c1"}}]} = request!(tools, "c1")
    end

    test "a request over the byte sum of the open calls gets an error; the next one under it waits" do
      {tools, _} = request!(%ToolQueue{}, "c1", nil, div(@max, 2))
      {tools, []} = request!(tools, "c2", nil, div(@max, 4))

      assert {^tools, [{:result, "c3", {:error, "Helyx tool calls too large" <> _}}]} =
               request!(tools, "c3", nil, div(@max, 4) + 1)

      assert {tools, []} = request!(tools, "c4", nil, div(@max, 4))
      assert Enum.map(tools.waiting, fn {c, _} -> c.id end) == ["c2", "c4"]
    end

    test "a single request over the bound is rejected with no call open; one at it runs" do
      assert {%ToolQueue{running: nil},
              [{:result, "c1", {:error, "Helyx tool calls too large" <> _}}]} =
               request!(%ToolQueue{}, "c1", nil, @max + 1)

      assert {_, [{:run, _}]} = request!(%ToolQueue{}, "c1", nil, @max)
    end

    test "the bytes of a call leave the sum at its result and at a cancel of a waiting call" do
      {tools, _} = request!(%ToolQueue{}, "c1", nil, @max - 1)
      {tools, _} = request!(tools, "c2", nil, 1)
      assert {_, [{:result, "c3", {:error, _}}]} = request!(tools, "c3", nil, 1)

      # The cancel of the waiting c2 frees 1 byte.
      {cancelled, _} = ToolQueue.cancel(tools, "c2")
      assert {_, []} = request!(cancelled, "c3", nil, 1)

      # The result of c1 frees its bytes, and c2 runs.
      {tools, _} = ToolQueue.result(tools, {:ok, "a"})
      assert {_, []} = request!(tools, "c3", nil, @max - 1)
    end
  end

  describe "result/2" do
    test "answers the running call and runs the next waiting one" do
      assert {tools, [{:result, "c1", {:ok, "a"}}, {:run, %ToolCall{id: "c2"}}]} =
               ToolQueue.result(after_requests(["c1", "c2"]), {:ok, "a"})

      assert {%ToolQueue{running: nil, waiting: []}, [{:result, "c2", {:error, "e"}}]} =
               ToolQueue.result(tools, {:error, "e"})
    end
  end

  describe "cancel/2" do
    test "the running call is killed and gets aborted at its result" do
      assert {tools, [{:kill, "c1"}]} = ToolQueue.cancel(after_requests(["c1", "c2"]), "c1")

      assert {%ToolQueue{running: "c2", killed?: false},
              [{:result, "c1", {:error, "aborted"}}, _run]} =
               ToolQueue.result(tools, {:ok, "late"})
    end

    test "a waiting call gets aborted at once; any other id changes nothing" do
      tools = after_requests(["c1", "c2", "c3"])
      assert {cancelled, [{:result, "c2", {:error, "aborted"}}]} = ToolQueue.cancel(tools, "c2")
      assert Enum.map(cancelled.waiting, fn {c, _} -> c.id end) == ["c3"]
      assert ToolQueue.cancel(tools, "other") == {tools, []}
    end
  end

  describe "end_turn/1" do
    test "each open call gets aborted, the running one first" do
      assert ToolQueue.end_turn(after_requests(["c1", "c2"])) == [
               {:result, "c1", {:error, "aborted"}},
               {:result, "c2", {:error, "aborted"}}
             ]

      assert ToolQueue.end_turn(%ToolQueue{}) == []
    end
  end
end
