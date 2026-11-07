defmodule Helyx.Provider.Codex.ReplayTest do
  use ExUnit.Case, async: true

  alias Helyx.Message
  alias Helyx.Provider.Codex
  alias Helyx.Provider.Codex.Replay

  @replay_max_bytes 400_000

  test "a large write call and its interrupted result give a typed error, not a silent cut" do
    call = %Message.ToolCall{
      id: "call_1",
      name: "write",
      arguments: %{"path" => "big.txt", "content" => String.duplicate("x", @replay_max_bytes)}
    }

    history = [
      Message.user("old"),
      %Message{role: :assistant, content: [call]},
      Message.tool_result(call, Helyx.Session.Transcript.interrupted_result())
    ]

    assert {:error, %Helyx.ProviderError{provider: "codex", kind: :replay_over_limit, text: text}} =
             Replay.items(history, Codex.id())

    assert text =~ "#{@replay_max_bytes}"
  end

  test "the interrupted result of the open turn stays when the closed history is cut" do
    call = %Message.ToolCall{id: "call_1", name: "write", arguments: %{"path" => "big.txt"}}
    {:error, interrupted} = Helyx.Session.Transcript.interrupted_result()

    history = [
      Message.user(String.duplicate("x", 300_000)),
      %Message{role: :assistant, content: [%Message.Text{text: String.duplicate("y", 200_000)}]},
      %Message{role: :assistant, content: [call]},
      Message.tool_result(call, {:error, interrupted})
    ]

    assert {:ok, items, 1} = Replay.items(history, Codex.id())

    assert [
             %{"content" => [%{"text" => _old}]},
             %{"type" => "function_call", "call_id" => "call_1"},
             %{"type" => "function_call_output", "output" => output}
           ] = Enum.map(items, &JSON.decode!/1)

    assert output == interrupted
  end
end
