defmodule Helyx.Provider.Codex do
  @moduledoc """
  A connected harness provider (ADR 0007) that drives the unmodified Codex
  program, with its shell off, by JSON-RPC lines of `codex app-server` on stdio.
  The model ref is `codex/<model>`, where `<model>` is a model id of `codex`.

  One program serves the session's provider process. `init/3` returns when it answered
  `initialize`. The first request opens the thread with the turn's system prompt as
  `baseInstructions`: `thread/resume` with `:resume_id`, or `thread/start`; a later prompt
  change starts a new program that resumes the thread; other tools, or `persist: false`,
  start one with a fresh thread and the replay. A `{:turn, ...}` is `turn/start`, a steer is
  `turn/steer`, and an interrupt is `turn/interrupt`, or `{:error, :command_running}` or
  `{:error, :agent_running}` when open work would outlive it. The session's tools go to the
  thread as `dynamicTools`, and the user's config is off where the program lets it be. The
  options `codex_sandbox` and `codex_approval_policy` are the thread's sandbox and approval
  policy, by default `danger-full-access` and `never`. A line that fails the shape check, a
  turn that Helyx did not ask for, and the program's exit stop the provider process.

  The full contract is in `docs/features/long-lived-harness.md`, section
  "Codex", and `docs/features/provider-parity.md`. The protocol facts are in
  `docs/research/codex-app-server.md`.
  """

  @behaviour Helyx.Provider

  alias Helyx.{HarnessIO, ModelInfo}
  alias Helyx.Provider.Codex.{Approvals, Check, Items, Program, State, Tools, Turn}

  import Helyx.Provider.Codex.Wire

  @impl true
  def id, do: "codex"

  @impl true
  defdelegate release(handles, mode, deadline), to: HarnessIO

  @impl true
  def init(model, tools, opts) do
    with {:ok, info} <- ModelInfo.lookup(id(), "openai", model),
         {:ok, options} <- Program.options(opts),
         {:ok, exe} <- HarnessIO.find("codex") do
      state = %State{
        exe: exe,
        model: model,
        items: %Items{info: info},
        tools: %Tools{specs: tools},
        cwd: Keyword.fetch!(opts, :cwd),
        resume: Program.resumable(opts[:resume_id], tools)
      }

      case Program.launch(struct!(state, options)) do
        %State{stream: %{terminal: {:error, reason}}} -> {:error, reason}
        state -> handshake(state)
      end
    end
  end

  # Reads the program's lines until `initialize` has its answer. The connect kill of Core
  # bounds the wait. Only the port's messages are taken: any other stays for the provider
  # loop.
  defp handshake(%State{stream: %{port: port}} = state) do
    message =
      receive do
        {^port, _} = message -> message
      end

    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, _, %State{stream: %{terminal: {:error, reason}}}} -> {:error, reason}
      {:lines, _, %State{due: due} = state} when map_size(due) > 0 -> handshake(state)
      {:lines, _, state} -> {:ok, state}
      {:exit, status} -> {:error, {:codex_exit, status}}
    end
  end

  @impl true
  def request(
        {:turn, id, %Helyx.Context{messages: messages, system: system, tools: tools}},
        from,
        %State{phase: :idle} = state
      ) do
    {prompt, history} = HarnessIO.split_prompt(messages)
    state = %{state | phase: {:opening, id, from, prompt, history}}
    actions(thread(state, system || "", tools))
  end

  # A compaction is `thread/compact/start`; its phase lasts until its
  # `turn/started`, which gives the program turn id. A fresh thread has no
  # history yet. No instructions: it keeps the thread's prompt, and a
  # stored thread opens with the empty one.
  def request({:compact, id, _text}, from, %State{phase: :idle} = state)
      when state.thread == nil and state.resume == nil,
      do: {:ok, [{:reply, from, :ok}, {:event, id, HarnessIO.no_history(id())}], state}

  def request({:compact, id, _text}, from, %State{phase: :idle} = state) do
    state = %{state | phase: {:compacting, id, from}}
    actions(thread(state, state.system || "", state.tools.specs))
  end

  # An open command, and a child thread's work, outlive `turn/interrupt`
  # (#198, #226), so the abort stops the program instead.
  def request({:interrupt, id}, from, state) do
    if State.turn_id(state) == id,
      do: interrupt(state, from),
      else: actions(reply(state, from, :ok))
  end

  # A steer of the running turn goes out as `turn/steer`; the server checks
  # `expectedTurnId`. After `turn/completed` nothing goes out.
  def request(
        {:steer, id, steer_id, text},
        from,
        %State{phase: {:running, id, turn, _mode}} = state
      ) do
    {rpc_id, state} = open(state, "turn/steer")

    send_line(state, %{
      id: rpc_id,
      method: "turn/steer",
      params: %{
        threadId: state.thread,
        expectedTurnId: turn,
        input: [%{type: "text", text: text}],
        clientUserMessageId: steer_id
      }
    })

    actions(%{state | asked: Map.put(state.asked, rpc_id, from)})
  end

  def request({:steer, _id, _steer_id, _text}, from, state),
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

  def request({:approval, _turn_id, approval_id, decision}, from, state),
    do: actions(reply(Approvals.answer(state, approval_id, decision), from, :ok))

  def request(:close, from, state), do: actions(HarnessIO.close(state, from))

  @impl true
  def info(message, state) do
    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, _, %State{stream: %{terminal: {:error, reason}}} = state} -> stop(reason, state)
      {:lines, _, state} -> actions(state)
      {:closed, from} -> actions(reply(state, from, :ok))
      {:exit, status} -> {:stop, {:codex_exit, status}, state}
      :other -> actions(state)
    end
  end

  # Output

  # At `turn/completed`: the terminal, the answer to an interrupt, and the
  # phase back to idle. A tool item still open outlives its turn (#198),
  # whatever the status, and so does a child thread of an aborted turn, so
  # the provider process stops instead: the release TERMs the program, which
  # ends its commands, before a next turn starts.
  defp end_turn(%State{} = state, result) do
    compact? = State.compaction?(state)

    if reason = outlives(state) do
      HarnessIO.update(state, terminal: {:error, reason})
    else
      terminal = Items.terminal(result, state.items, compact?)
      state = Turn.interrupted(push(state, [terminal]))
      %{state | phase: :idle, items: Items.next(terminal, state.items, compact?)}
    end
  end

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
  # `agents` is a string (`Check`), so a turn with no program turn has none.
  defp agent?(state), do: State.program(state) in Map.values(state.agents)

  # Puts the line's events in `out`, in order with the replies of the same
  # chunk; the events list of `HarnessIO.lines/3` stays empty.
  defp translate(object, state) do
    case Check.malformed(object, state) do
      nil ->
        {events, state} = dispatch(object, state)
        {[], push(state, events)}

      what ->
        {[], HarnessIO.update(state, terminal: {:error, {:malformed, what}})}
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

  # A request of the server (it has an id and a method): an approval goes to Core (`Approvals`).
  defp dispatch(%{"id" => _, "method" => _} = request, state),
    do: Approvals.dispatch(request, state)

  defp dispatch(%{"id" => id} = response, %State{due: due} = state) when is_map_key(due, id) do
    {method, due} = Map.pop(due, id)
    answered(method, response, %{state | due: due})
  end

  defp dispatch(%{"method" => "thread/tokenUsage/updated"} = line, state),
    do: {[], %{state | items: Items.usage(line, state.thread, State.program(state), state.items)}}

  # Only this program's thread counts: a sub-agent's stays in the harness.
  defp dispatch(%{"method" => method, "params" => %{"threadId" => thread} = params}, state)
       when thread == state.thread and is_binary(thread),
       do: turn_notification(method, params, state)

  defp dispatch(_object, state), do: {[], state}

  # A program of a prompt change has a waiting request: its thread opens now.
  defp answered("initialize", %{"result" => _}, state) do
    send_line(state, %{method: "initialized"})
    {[], if(State.turn_id(state), do: Program.open_thread(state), else: state)}
  end

  # The program has no such thread: a fresh one starts on the same run.
  defp answered("thread/resume", %{"error" => _}, state),
    do: {[], Program.open_thread(%{state | resume: nil})}

  # The thread's digest is the session's (`HarnessIO.resumable/2`).
  defp answered("thread/resume", _response, state),
    do: {[], Turn.opened(%{state | thread: state.resume})}

  defp answered("thread/start", %{"result" => %{"thread" => %{"id" => thread}}}, state),
    do: {[], Turn.opened(%{state | thread: thread, fresh?: true})}

  defp answered(method, response, state)
       when method in [
              "thread/inject_items",
              "turn/start",
              "turn/interrupt",
              "thread/compact/start"
            ],
       do: {[], Turn.answer(method, response, state)}

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
        {[], reply(state, from, {:error, Turn.failure("turn/steer", response)})}
    end
  end

  defp answered(method, response, state),
    do: {[], HarnessIO.update(state, terminal: {:error, Turn.failure(method, response)})}

  # Only the turn of the `turn/start` answer, which comes first.
  defp turn_notification(
         "turn/started",
         %{"turn" => %{"id" => turn}},
         %State{phase: {:running, _id, turn, _mode}} = state
       )
       when is_binary(turn),
       do: {[], state}

  defp turn_notification(
         "turn/started",
         %{"turn" => %{"id" => turn}},
         %State{phase: {:compacting, id, _from}} = state
       )
       when is_binary(turn),
       do: {[], Turn.send_interrupt(%{state | phase: {:running, id, turn, :compact}})}

  defp turn_notification("turn/started", _params, state),
    do: {[], HarnessIO.update(state, terminal: {:error, :turn_not_asked})}

  defp turn_notification(
         "turn/completed",
         %{"turn" => %{"id" => turn} = result},
         %State{phase: {:running, _id, turn, _mode}} = state
       ),
       do: {[], end_turn(state, result)}

  # The end of a turn that did not start, or that already ended.
  defp turn_notification("turn/completed", _params, state),
    do: {[], HarnessIO.update(state, terminal: {:error, :turn_not_asked})}

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
         %State{phase: {:running, _id, turn, _mode}} = state
       )
       when method in ["item/started", "item/completed"] and is_binary(turn) do
    agents = Map.put(state.agents, item["agentThreadId"], turn)
    {[], %{state | agents: agents, items: Items.sub_agent(state.items)}}
  end

  defp turn_notification(
         method,
         %{"turnId" => turn} = params,
         %State{phase: {:running, _id, turn, _mode}} = state
       )
       when is_binary(turn),
       do: notification(method, params, state)

  # An item of a turn that is not the running one, such as the late
  # `item/completed` of a command that `turn/interrupt` left running.
  defp turn_notification("item/" <> _, %{"turnId" => turn}, state) when is_binary(turn),
    do: {[], HarnessIO.update(state, terminal: {:error, :item_of_ended_turn})}

  defp turn_notification(_method, _params, state), do: {[], state}

  # The interrupt of the open turn: an open command or a child thread's work
  # answers an error, and Core then stops the program.
  defp interrupt(state, from) do
    cond do
      command?(state) -> actions(reply(state, from, {:error, :command_running}))
      agent?(state) -> actions(reply(state, from, {:error, :agent_running}))
      true -> actions(Turn.send_interrupt(%{state | interrupt: {:pending, from}}))
    end
  end

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

  # The thread of a request runs with its prompt and its tools
  # (`docs/features/provider-parity.md`, `mcp-client.md` decision 10).
  defp thread(%State{thread: nil, tools: %{specs: specs}} = state, system, specs),
    do: Program.open_thread(%{state | system: system})

  defp thread(%{system: system, tools: %{specs: specs}} = state, system, specs),
    do: Turn.opened(state)

  defp thread(state, system, specs), do: Program.replace(state, system, specs)

  defp tool_answer(state, rpc_id, status, text) do
    result = %{contentItems: [%{type: "inputText", text: text}], success: status == :ok}
    send_line(state, %{id: rpc_id, result: result})
    state
  end
end
