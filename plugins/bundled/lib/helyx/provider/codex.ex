defmodule Helyx.Provider.Codex do
  @moduledoc """
  A connected harness provider (ADR 0007) that drives the unmodified Codex
  program, with its shell off, by JSON-RPC lines of `codex app-server` on stdio.
  The model ref is `codex/<model>`, where `<model>` is a model id of `codex`.

  One program serves the session's provider process. `init/3` returns when it
  answered `initialize`. The first request opens the thread with the turn's
  system prompt as `baseInstructions`: `thread/resume` with `:resume_id`, or
  `thread/start`; a later prompt change starts a new program that resumes the
  thread. A `{:turn, ...}` is `turn/start`, a steer is `turn/steer`, and an
  interrupt is `turn/interrupt`, or `{:error, :command_running}` or
  `{:error, :agent_running}` when open work would outlive it. The session's
  tools go to the thread as `dynamicTools`, and the user's config is off where
  the program lets it be. A line that fails the shape check, a turn that Helyx
  did not ask for, and the program's exit stop the provider process.

  The full contract is in `docs/features/long-lived-harness.md`, section
  "Codex", and `docs/features/provider-parity.md`. The protocol facts are in
  `docs/research/codex-app-server.md`.
  """

  @behaviour Helyx.Provider

  alias Helyx.{HarnessIO, Message, ModelInfo}
  alias Helyx.Provider.Codex.{Check, Items, Program, Replay, State, Tools}

  import Helyx.Provider.Codex.Wire

  @impl true
  def id, do: "codex"

  @impl true
  defdelegate release(handles, mode, deadline), to: HarnessIO

  @impl true
  def init(model, tools, opts) do
    with {:ok, info} <- ModelInfo.lookup(id(), "openai", model),
         {:ok, exe} <- HarnessIO.find("codex") do
      state = %State{
        exe: exe,
        model: model,
        items: %Items{info: info},
        tools: %Tools{specs: tools},
        cwd: Keyword.fetch!(opts, :cwd),
        resume: Program.resumable(opts[:resume_id], tools)
      }

      case Program.launch(state) do
        %State{terminal: {:error, reason}} -> {:error, reason}
        state -> handshake(state)
      end
    end
  end

  # Reads the program's lines until `initialize` has its answer. The connect kill of Core
  # bounds the wait. Only the port's messages are taken: any other stays for the provider
  # loop.
  defp handshake(%State{port: port} = state) do
    message =
      receive do
        {^port, _} = message -> message
      end

    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, _, %State{terminal: {:error, reason}}} -> {:error, reason}
      {:lines, _, %State{due: due} = state} when map_size(due) > 0 -> handshake(state)
      {:lines, _, state} -> {:ok, state}
      {:exit, status} -> {:error, {:codex_exit, status}}
    end
  end

  @impl true
  def request(
        {:turn, turn_id, %Helyx.Context{messages: messages, system: system}},
        from,
        %State{turn_id: nil} = state
      ) do
    {prompt, history} = HarnessIO.split_prompt(messages)
    state = %{state | turn_id: turn_id, from: from, prompt: prompt, history: history}
    actions(thread(state, system || ""))
  end

  # A compaction is `thread/compact/start`; its turn id comes with `turn/started` (`turn`
  # is `:compact` until then). A fresh thread has no history yet. No instructions. It
  # keeps the thread's prompt; a stored thread opens with the empty one.
  def request({:compact, turn_id, _text}, from, %State{turn_id: nil} = state)
      when state.thread == nil and state.resume == nil,
      do: {:ok, [{:reply, from, :ok}, {:event, turn_id, HarnessIO.no_history()}], state}

  def request({:compact, turn_id, _text}, from, %State{turn_id: nil} = state) do
    state = %{state | turn_id: turn_id, from: from, turn: :compact}
    actions(thread(state, state.system || ""))
  end

  # An open command, and a child thread's work, outlive `turn/interrupt`
  # (#198, #226), so the abort stops the program instead.
  def request({:interrupt, turn_id}, from, %State{turn_id: turn_id} = state) do
    state =
      cond do
        command?(state) -> reply(state, from, {:error, :command_running})
        agent?(state) -> reply(state, from, {:error, :agent_running})
        true -> send_interrupt(%{state | interrupt: {:pending, from}})
      end

    actions(state)
  end

  # The turn already ended.
  def request({:interrupt, _turn_id}, from, state), do: actions(reply(state, from, :ok))

  # A steer of the running turn goes out as `turn/steer`; the server checks
  # `expectedTurnId`. After `turn/completed` nothing goes out.
  def request({:steer, turn_id, steer_id, text}, from, %State{turn_id: turn_id} = state)
      when is_binary(state.turn) do
    {id, state} = open(state, "turn/steer")

    send_line(state, %{
      id: id,
      method: "turn/steer",
      params: %{
        threadId: state.thread,
        expectedTurnId: state.turn,
        input: [%{type: "text", text: text}],
        clientUserMessageId: steer_id
      }
    })

    actions(%{state | asked: Map.put(state.asked, id, from)})
  end

  def request({:steer, _turn_id, _steer_id, _text}, from, state),
    do: actions(reply(state, from, :rejected))

  # No tool item outlives a turn; a child thread's work belongs to the program.
  def request(:idle_close, from, %State{agents: agents} = state)
      when map_size(agents) > 0,
      do: actions(reply(state, from, :busy))

  def request(:idle_close, from, state), do: request(:close, from, state)

  # The result of a Helyx tool call. Core gives a result only for a call
  # that this provider requested, once.
  def request({:tool_result, _turn_id, call_id, {status, text}}, from, state) do
    {rpc_id, requests} = Map.pop!(state.tools.requests, call_id)
    tool_answer(state, rpc_id, status, text)
    actions(reply(%{state | tools: %{state.tools | requests: requests}}, from, :ok))
  end

  def request(:close, from, state), do: actions(HarnessIO.close(state, from))

  @impl true
  def info(message, state) do
    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, _, %State{terminal: {:error, reason}} = state} -> stop(reason, state)
      {:lines, _, state} -> actions(state)
      {:closed, from} -> actions(reply(state, from, :ok))
      {:exit, status} -> {:stop, {:codex_exit, status}, state}
      :other -> actions(state)
    end
  end

  # Output

  # At `turn/completed`: the terminal, the answer to an interrupt, and the
  # fields of a turn back to idle. A tool item still open outlives its turn
  # (#198), whatever the status, and so does a child thread of an aborted
  # turn, so the provider process stops instead: the release TERMs the
  # program, which ends its commands, before a next turn starts.
  defp end_turn(state, terminal) do
    if reason = outlives(state) do
      %{state | terminal: {:error, reason}}
    else
      state = interrupted(push(state, [terminal]))
      %{state | turn_id: nil, turn: nil, items: Items.next(terminal, state.items)}
    end
  end

  # The interrupt ends with the turn. A later answer to a sent request is
  # not due, and is dropped.
  defp interrupted(%State{interrupt: {:pending, from}} = state),
    do: reply(%{state | interrupt: nil}, from, :ok)

  defp interrupted(%State{interrupt: {:sent, from, id}} = state),
    do: reply(%{state | interrupt: nil, due: Map.delete(state.due, id)}, from, :ok)

  defp interrupted(state), do: state

  # Why the turn's work can outlive its end, or nil.
  defp outlives(state) do
    cond do
      command?(state) -> :command_running
      map_size(state.items.open) > 0 -> :tool_running
      state.interrupt != nil and agent?(state) -> :agent_running
      true -> nil
    end
  end

  defp command?(state), do: "commandExecution" in Map.values(state.items.open)

  # A child thread of the running turn has open work. Every turn id in
  # `agents` is a string (`Check`), so a turn with no id has none.
  defp agent?(state), do: state.turn in Map.values(state.agents)

  # Puts the line's events in `out`, in order with the replies of the same
  # chunk; the events list of `HarnessIO.lines/3` stays empty.
  defp translate(object, state) do
    case Check.malformed(object, state) do
      nil ->
        {events, state} = dispatch(object, state)
        {[], push(state, events)}

      what ->
        {[], %{state | terminal: {:error, {:malformed, what}}}}
    end
  end

  # A Helyx tool call. The request only runs the tool, so it goes out at once.
  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call", "params" => params}, state)
       when is_map(params) do
    case Tools.call(state, rpc_id, params) do
      {{:ok, request}, tools} -> {[], push(%{state | tools: tools}, [request])}
      {{:error, text}, tools} -> {[], tool_answer(%{state | tools: tools}, rpc_id, :error, text)}
    end
  end

  # A request of the server (it has an id and a method) gets an error. The
  # thread runs with `approvalPolicy: "never"`, so an approval request is refused too (ADR 0007).
  defp dispatch(%{"id" => id, "method" => _method}, state) do
    send_line(state, %{id: id, error: %{code: -32_601, message: "not supported by Helyx"}})
    {[], state}
  end

  defp dispatch(%{"id" => id} = response, %State{due: due} = state) when is_map_key(due, id) do
    {method, due} = Map.pop(due, id)
    answered(method, response, %{state | due: due})
  end

  defp dispatch(%{"method" => "thread/tokenUsage/updated"} = line, state),
    do: {[], %{state | items: Items.usage(line, state.thread, state.turn, state.items)}}

  # Only this program's thread counts: a sub-agent's stays in the harness.
  defp dispatch(%{"method" => method, "params" => %{"threadId" => thread} = params}, state)
       when thread == state.thread and is_binary(thread),
       do: turn_notification(method, params, state)

  defp dispatch(_object, state), do: {[], state}

  # A program of a prompt change has a waiting request: its thread opens now.
  defp answered("initialize", %{"result" => _}, state) do
    send_line(state, %{method: "initialized"})
    {[], if(state.turn_id, do: Program.open_thread(state), else: state)}
  end

  # The program has no such thread: a fresh one starts on the same run.
  defp answered("thread/resume", %{"error" => _}, state),
    do: {[], Program.open_thread(%{state | resume: nil})}

  # The thread's digest is the session's (`HarnessIO.resumable/2`).
  defp answered("thread/resume", _response, state),
    do: {[], opened(%{state | thread: state.resume})}

  defp answered("thread/start", %{"result" => %{"thread" => %{"id" => thread}}}, state),
    do: {[], opened(%{state | thread: thread, fresh?: true})}

  defp answered(method, response, state)
       when method in [
              "thread/inject_items",
              "turn/start",
              "turn/interrupt",
              "thread/compact/start"
            ],
       do: {[], answer(method, response, state)}

  # Only the exact error of a steer that crossed the turn's end confirms
  # that the program did not take it (research note). The error of a turn
  # id mismatch has no verified exact form, so it is unknown, as any other.
  defp answered("turn/steer", %{"id" => id} = response, state) do
    {from, asked} = Map.pop!(state.asked, id)
    state = %{state | asked: asked}

    case response do
      %{"result" => _} ->
        {[], reply(state, from, :ok)}

      %{"error" => %{"code" => -32_600, "message" => "no active turn to steer"}} ->
        {[], reply(state, from, :rejected)}

      _error ->
        {[], reply(state, from, {:error, failure("turn/steer", response)})}
    end
  end

  defp answered(method, response, state),
    do: {[], %{state | terminal: {:error, failure(method, response)}}}

  # The program's turn id comes with the answer, before `turn/started`
  # (research note); a pending interrupt goes out then.
  defp answer("turn/start", %{"result" => %{"turn" => %{"id" => turn}}}, state),
    do: send_interrupt(reply(%{state | from: nil, turn: turn}, state.from, :ok))

  defp answer("thread/inject_items", %{"result" => _}, state), do: start_turn(state)

  defp answer("thread/compact/start", %{"result" => _}, state),
    do: reply(%{state | from: nil}, state.from, :ok)

  defp answer(
         "turn/interrupt",
         %{"id" => id, "error" => _} = response,
         %{interrupt: {:sent, from, id}} = state
       ),
       do: reply(%{state | interrupt: nil}, from, {:error, failure("turn/interrupt", response)})

  # The turn's end, not this answer, ends an interrupt. An error after the
  # turn's end, such as `no active turn to interrupt` (research note),
  # belongs to no interrupt, also when a later turn's interrupt is sent.
  defp answer("turn/interrupt", _response, state), do: state

  # An error answer to `turn/start` or `thread/inject_items` fails the turn,
  # and the provider process stops.
  defp answer(method, response, state),
    do: reply(%{state | from: nil}, state.from, {:error, failure(method, response)})

  defp failure(method, response),
    do:
      {:codex, method,
       HarnessIO.cap_error(Items.error_message(response) || "unexpected response")}

  # Only the turn of the `turn/start` answer, which comes first.
  defp turn_notification("turn/started", %{"turn" => %{"id" => turn}}, %{turn: turn} = state)
       when is_binary(turn),
       do: {[], state}

  defp turn_notification("turn/started", %{"turn" => %{"id" => turn}}, %{turn: :compact} = state)
       when is_binary(turn),
       do: {[], send_interrupt(%{state | turn: turn})}

  defp turn_notification("turn/started", _params, state),
    do: {[], %{state | terminal: {:error, :turn_not_asked}}}

  defp turn_notification(
         "turn/completed",
         %{"turn" => %{"id" => turn} = result},
         %{turn: turn} = state
       ),
       do: {[], end_turn(state, Items.terminal(result, state.items))}

  # The end of a turn that did not start, or that already ended.
  defp turn_notification("turn/completed", _params, state),
    do: {[], %{state | terminal: {:error, :turn_not_asked}}}

  # A child thread's work outlives its turn: its `completed` item can come
  # with the id of an ended turn (#226), and only it confirms that the work
  # ended. An item of another kind belongs to the running turn; one of any
  # other turn stops the provider process as an item of an ended turn.
  defp turn_notification(
         method,
         %{"item" => %{"type" => "subAgentActivity", "kind" => "completed"} = item},
         state
       )
       when method in ["item/started", "item/completed"],
       do: {[], %{state | agents: Map.delete(state.agents, item["agentThreadId"])}}

  defp turn_notification(
         method,
         %{"turnId" => turn, "item" => %{"type" => "subAgentActivity"} = item},
         %{turn: turn} = state
       )
       when method in ["item/started", "item/completed"] and is_binary(turn) do
    agents = Map.put(state.agents, item["agentThreadId"], turn)
    {[], %{state | agents: agents, items: Items.sub_agent(state.items)}}
  end

  defp turn_notification(method, %{"turnId" => turn} = params, %{turn: turn} = state)
       when is_binary(turn),
       do: notification(method, params, state)

  # An item of a turn that is not the running one, such as the late
  # `item/completed` of a command that `turn/interrupt` left running.
  defp turn_notification("item/" <> _, %{"turnId" => turn}, state) when is_binary(turn),
    do: {[], %{state | terminal: {:error, :item_of_ended_turn}}}

  defp turn_notification(_method, _params, state), do: {[], state}

  # A pending interrupt goes out when the turn id is known.
  defp send_interrupt(%State{interrupt: {:pending, from}, turn: turn} = state)
       when is_binary(turn) do
    {id, state} = open(state, "turn/interrupt")
    params = %{threadId: state.thread, turnId: turn}
    send_line(state, %{id: id, method: "turn/interrupt", params: params})
    %{state | interrupt: {:sent, from, id}}
  end

  defp send_interrupt(state), do: state

  # The program took a steer: its `userMessage` item carries the steer id. The session
  # drops an id that is not a sent steer of its turn, and a repeated one
  # (`Helyx.Provider`). The prompt's item has `clientId` null (research note).
  defp notification(
         "item/started",
         %{"item" => %{"type" => "userMessage", "clientId" => id}},
         state
       )
       when is_binary(id),
       do: {[{:user_message, id}], state}

  defp notification(method, params, state) do
    {events, items} = Items.notification(method, params, state.items)
    {events, %{state | items: items}}
  end

  # Input

  # The thread of a request runs with the prompt `system`
  # (`docs/features/provider-parity.md`).
  defp thread(%State{thread: nil} = state, system),
    do: Program.open_thread(%{state | system: system})

  defp thread(%State{system: system} = state, system), do: opened(state)
  defp thread(state, system), do: Program.replace(state, system)

  # The thread is open: the waiting request goes on.
  defp opened(%State{turn: :compact, fresh?: true} = state) do
    # An interrupt of the compaction waits for its turn, and none comes.
    state = interrupted(push(reply(state, state.from, :ok), [HarnessIO.no_history()]))
    %{state | turn_id: nil, turn: nil, from: nil}
  end

  defp opened(%State{turn: :compact} = state) do
    state = %{state | items: %{state.items | compact?: true}}
    rpc(state, "thread/compact/start", %{threadId: state.thread})
  end

  defp opened(%State{fresh?: true} = state),
    do: replay(state.history, %{state | fresh?: false, history: nil})

  defp opened(state), do: start_turn(%{state | history: nil})

  defp tool_answer(state, rpc_id, status, text) do
    result = %{contentItems: [%{type: "inputText", text: text}], success: status == :ok}
    send_line(state, %{id: rpc_id, result: result})
    state
  end

  # The first turn of a fresh thread: its id and cut, then the replay, if
  # any. The turn's `turn/start` waits for the replay's answer.
  defp replay(history, state) do
    {items, cut} = Replay.items(history)

    state =
      push(state, [
        {:resume_id, Program.stored_id(state.thread, state.tools.specs), cut}
      ])

    if items == [] do
      start_turn(state)
    else
      {id, state} = open(state, "thread/inject_items")

      # The items are JSON already: the line is joined from them.
      send_line(state, [
        ~s({"id":#{id},"method":"thread/inject_items","params":{"threadId":),
        JSON.encode!(state.thread),
        ~s(,"items":[),
        Enum.intersperse(items, ","),
        "]}}"
      ])

      state
    end
  end

  defp start_turn(%State{prompt: prompt} = state) do
    input =
      for %Message{content: blocks} <- prompt,
          %Message.Text{text: text} <- blocks,
          text != "",
          do: %{type: "text", text: text}

    rpc(%{state | prompt: nil}, "turn/start", %{threadId: state.thread, input: input})
  end
end
