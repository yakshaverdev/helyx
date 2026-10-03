defmodule Helyx.Session.ToolsTest do
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Session.Tools

  defp call(id), do: %ToolCall{id: id, name: "t", arguments: %{}}

  defp request!(tools, id, rejection \\ nil) do
    {:ok, step} = Tools.request(tools, call(id), rejection)
    step
  end

  # The scheduler after requests of `ids`, with their effects dropped.
  defp after_requests(ids), do: Enum.reduce(ids, %Tools{}, &elem(request!(&2, &1), 0))

  describe "request/3" do
    test "the first request runs, the next ones wait in order" do
      assert {tools, [{:run, %ToolCall{id: "c1"}}]} = request!(%Tools{}, "c1")
      assert {tools, []} = request!(tools, "c2")
      assert {tools, []} = request!(tools, "c3")
      assert tools.running == "c1"
      assert Enum.map(tools.waiting, & &1.id) == ["c2", "c3"]
    end

    test "over one running and 16 waiting, a request gets an error and changes nothing" do
      full = after_requests(for i <- 1..17, do: "c#{i}")
      assert length(full.waiting) == 16

      assert {^full, [{:result, "c18", {:error, "too many Helyx tool calls" <> _}}]} =
               request!(full, "c18")
    end

    test "a rejected request gets its error and runs nothing, even with no call running" do
      assert {%Tools{running: nil}, [{:result, "c1", {:error, "tool call not run: bad"}}]} =
               request!(%Tools{}, "c1", "bad")
    end

    test "an id that runs or waits is open; an answered id runs again" do
      tools = after_requests(["c1", "c2"])
      assert Tools.request(tools, call("c1"), nil) == :open
      assert Tools.request(tools, call("c2"), "bad") == :open

      {tools, _} = Tools.result(after_requests(["c1"]), {:ok, "a"})
      assert {_, [{:run, %ToolCall{id: "c1"}}]} = request!(tools, "c1")
    end
  end

  describe "result/2" do
    test "answers the running call and runs the next waiting one" do
      assert {tools, [{:result, "c1", {:ok, "a"}}, {:run, %ToolCall{id: "c2"}}]} =
               Tools.result(after_requests(["c1", "c2"]), {:ok, "a"})

      assert {%Tools{running: nil, waiting: []}, [{:result, "c2", {:error, "e"}}]} =
               Tools.result(tools, {:error, "e"})
    end
  end

  describe "cancel/2" do
    test "the running call is killed and gets aborted at its result" do
      assert {tools, [{:kill, "c1"}]} = Tools.cancel(after_requests(["c1", "c2"]), "c1")

      assert {%Tools{running: "c2", killed?: false}, [{:result, "c1", {:error, "aborted"}}, _run]} =
               Tools.result(tools, {:ok, "late"})
    end

    test "a waiting call gets aborted at once; any other id changes nothing" do
      tools = after_requests(["c1", "c2", "c3"])
      assert {cancelled, [{:result, "c2", {:error, "aborted"}}]} = Tools.cancel(tools, "c2")
      assert Enum.map(cancelled.waiting, & &1.id) == ["c3"]
      assert Tools.cancel(tools, "other") == {tools, []}
    end
  end

  describe "end_turn/1" do
    test "each open call gets aborted, the running one first" do
      assert Tools.end_turn(after_requests(["c1", "c2"])) == [
               {:result, "c1", {:error, "aborted"}},
               {:result, "c2", {:error, "aborted"}}
             ]

      assert Tools.end_turn(%Tools{}) == []
    end
  end
end
