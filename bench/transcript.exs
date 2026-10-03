# The cost of one session step on a long transcript (#436). Not a test: it
# asserts nothing and only prints the times. Run from the repository root:
#
#     mix run bench/transcript.exs
#
# Each round is one user message, one assistant message with one tool call,
# and its result. The transcript ends with an assistant message whose call is
# open. It times one append (`Records.append_user/2`), one
# `Transcript.open_calls/1`, and one tool result (`Records.tool_result/3`),
# each the median of 101 runs on the same state. The state has no file and
# no subscriber, so the times are the transcript work and one event struct.
# Each size runs in a new process, so one size does not pay for the heap of
# another.
defmodule Helyx.Bench.Transcript do
  @moduledoc false

  alias Helyx.{Message, ModelRef}
  alias Helyx.Session.{Transcript, Turn}
  alias Helyx.Session.Server.{Records, State}

  @runs 101

  def run(size) do
    rounds = div(size, 3)
    # The result of the last call is dropped: the transcript ends with it open.
    transcript = 1..rounds |> Enum.flat_map(&messages/1) |> Enum.drop(-1)
    open_id = "c#{rounds}"
    model = %ModelRef{provider: "bench", model: "m"}
    turn = %Turn{id: "t", model: model, provider: nil}

    state = %State{
      id: "s",
      core: nil,
      model: model,
      provider: nil,
      cwd: ".",
      activity: turn,
      transcript: transcript
    }

    append = median(fn -> Records.append_user(state, "next") end)
    open_calls = median(fn -> Transcript.open_calls(transcript) end)
    result = median(fn -> Records.tool_result(state, open_id, {:ok, "ok"}) end)

    "messages=#{length(transcript)} append=#{append}ms open_calls=#{open_calls}ms " <>
      "tool_result=#{result}ms"
  end

  # A user message and an assistant message with one call, then its result.
  defp messages(i) do
    call = %Message.ToolCall{id: "c#{i}", name: "bash", arguments: %{"command" => "ls"}}
    answer = %Message{role: :assistant, content: [%Message.Text{text: "Run."}, call]}
    [Message.user("go #{i}"), answer, Message.tool_result(call, {:ok, "lib\ntest"})]
  end

  defp median(fun) do
    times = for _ <- 1..@runs, do: fun |> :timer.tc() |> elem(0)
    Float.round(Enum.at(Enum.sort(times), div(@runs, 2)) / 1000, 3)
  end
end

for size <- [1_000, 10_000, 50_000] do
  task = Task.async(fn -> Helyx.Bench.Transcript.run(size) end)
  IO.puts(Task.await(task, :infinity))
end
