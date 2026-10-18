defmodule Helyx.Transport.WebSocketAnswerTest do
  # The conformance client on asks: the `ask` event and the snapshot `asks`
  # for a subscriber with `answers: true`, the `answer` operation and its
  # errors (docs/features/question-tool.md, docs/features/wire-protocol.md).
  use ExUnit.Case, async: true

  alias Helyx.Message.ToolCall
  alias Helyx.Provider.Fake
  alias Helyx.Test.WireClient, as: Client
  alias Helyx.Transport.WebSocket

  @questions [
    %{
      "question" => "Which one?",
      "header" => "Pick",
      "options" => [
        %{"label" => "a", "description" => "it"},
        %{"label" => "b", "description" => "it"}
      ],
      "multi_select" => false
    }
  ]

  setup do
    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [Fake, Helyx.Tool.Question]})
    transport = start_supervised!({WebSocket, core: core, port: 0})
    socket = Client.open(WebSocket.port(transport))
    call = %ToolCall{id: "q1", name: "question", arguments: %{"questions" => @questions}}
    :ok = Fake.script(core, "ask", [[call], ["Done."]])

    %{"result" => %{"session" => session}} =
      Client.request(socket, "start", "start", %{"cwd" => File.cwd!(), "model" => "fake/ask"})

    # The requests go on their own socket: `Client.request/4` skips the
    # events before its reply.
    driver = Client.open(WebSocket.port(transport))
    %{socket: socket, driver: driver, session: session, port: WebSocket.port(transport)}
  end

  defp subscribe(socket, session, params) do
    %{"ok" => true, "result" => result} =
      Client.request(socket, "s", "subscribe", Map.put(params, "session", session))

    result
  end

  # The event of `type` on `sub`, after the frames before it.
  defp event(socket, sub, type) do
    case Client.recv(socket) do
      {:frame, %{"type" => "event", "sub" => ^sub, "event" => %{"type" => ^type} = event}} ->
        event

      {:frame, _other} ->
        event(socket, sub, type)
    end
  end

  defp answer(socket, session, call_id, answer),
    do:
      Client.request(socket, "a", "answer", %{
        "session" => session,
        "call_id" => call_id,
        "answer" => answer
      })

  test "the first answer goes to the call; every client sees the ask end", context do
    %{socket: socket, driver: driver, session: session, port: port} = context
    %{"sub" => sub} = subscribe(socket, session, %{"answers" => true})
    watcher = Client.open(port)
    %{"sub" => watch} = subscribe(watcher, session, %{})

    assert %{"ok" => true} =
             Client.request(driver, "p", "prompt", %{"session" => session, "text" => "go"})

    ask = %{"call_id" => "q1", "tool" => "question", "request" => %{"questions" => @questions}}
    assert event(socket, sub, "ask")["data"] == ask
    assert event(watcher, watch, "ask")["data"] == ask

    late = Client.open(port)
    assert %{"snapshot" => %{"asks" => [^ask]}} = subscribe(late, session, %{})

    selected = %{"answers" => [%{"selected" => ["b"]}]}
    assert %{"ok" => true, "result" => %{}} = answer(driver, session, "q1", selected)

    assert %{"ok" => false, "error" => %{"code" => "not_waiting"}} =
             answer(driver, session, "q1", selected)

    ended = %{"call_id" => "q1", "outcome" => "answered"}
    assert event(socket, sub, "ask_end")["data"] == ended
    assert event(watcher, watch, "ask_end")["data"] == ended

    assert [%{"text" => "The user answered:\n\nQ: Which one?\nA: b"}] =
             event(socket, sub, "tool_execution_end")["data"]["message"]["content"]
  end

  test "with no subscriber that answers, the tool tells the model to decide", context do
    %{socket: socket, driver: driver, session: session} = context
    %{"sub" => sub} = subscribe(socket, session, %{"answers" => false})

    assert %{"ok" => true} =
             Client.request(driver, "p", "prompt", %{"session" => session, "text" => "go"})

    assert [%{"text" => "No user can answer in this run." <> _}] =
             event(socket, sub, "tool_execution_end")["data"]["message"]["content"]
  end

  test "a bad answer or bad params get their errors", %{socket: socket, session: session} do
    assert %{"ok" => false, "error" => %{"code" => "invalid_answer"}} =
             answer(socket, session, "q1", %{"t" => String.duplicate("a", 16_377)})

    for bad <- ["text", [1], nil] do
      assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
               answer(socket, session, "q1", bad)
    end

    assert %{"ok" => false, "error" => %{"code" => "not_waiting"}} =
             answer(socket, session, "q1", %{"t" => String.duplicate("a", 16_376)})

    assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
             answer(socket, session, 1, %{})

    assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
             Client.request(socket, "a", "answer", %{"session" => session, "call_id" => "q1"})

    assert %{"ok" => false, "error" => %{"code" => "bad_params"}} =
             Client.request(socket, "s", "subscribe", %{"session" => session, "answers" => 1})

    assert %{"ok" => false, "error" => %{"code" => "session_not_found"}} =
             answer(socket, "nosuchsessi0", "q1", %{})
  end
end
