defmodule Helyx.Provider.Codex do
  @moduledoc """
  A connected harness provider (ADR 0007) that drives the unmodified Codex
  program through `codex app-server`, with JSON-RPC lines over stdio. The
  model ref is `codex/<model>`, where `<model>` is a model id of `codex`.

  One program serves the session's provider process. `init/3` returns when
  its thread is ready: `thread/resume` with `:resume_id`, or `thread/start`.
  A `{:turn, ...}` is `turn/start`, a steer is `turn/steer`, and an
  interrupt is `turn/interrupt`, or `{:error, :command_running}` or
  `{:error, :agent_running}` when open work would outlive it. The Helyx
  tools go to the thread as `dynamicTools`. A line that fails the shape
  check, a turn that Helyx did not ask for, and the program's exit stop the
  provider process.

  The full contract is in `docs/features/long-lived-harness.md`, section
  "Codex". The protocol facts are in `docs/research/codex-app-server.md`.
  """

  @behaviour Helyx.Provider

  alias Helyx.HarnessIO
  alias Helyx.Message
  alias Helyx.Provider.Codex.{Check, Items, Replay, Tools}

  defmodule State do
    @moduledoc false
    # The program of one provider process. `resume` is the thread id to
    # resume, or nil; `thread` the thread's id, and `fresh?` whether it
    # still waits for its replay. `turn_id` is the Helyx turn, `turn` the
    # program's turn id, `from` the `{:turn, ...}` without an answer,
    # `interrupt` an interrupt without an answer (`{:pending, from}` before
    # the turn id is known, `{:sent, from, id}` after the `turn/interrupt`
    # with the request id `id`), `due` maps the id of each request without
    # an answer to its method (an answer with an id that is not due is
    # dropped), `next_id` is the id of the next request, `closing` the close
    # without an answer, `prompt` the prompt of a turn whose `turn/start`
    # waits for the `thread/inject_items` answer, and `out` the actions to
    # return, newest first.
    # `terminal` set means the provider process must stop, with that error.
    #
    # `agents` maps each child thread with open work to the program's turn
    # id of its last `subAgentActivity` item. It belongs to the program and
    # stays between turns.
    #
    # Of the running turn: `items` the state of its items (`Items`).
    # `steers` has a key for the id of each steer sent in the running turn
    # with no `userMessage` item yet. `asked` maps the request id of each
    # `turn/steer` with no answer yet to `{from, steer_id}`; it outlives the
    # turn, because the answer can come after `turn/completed`.
    #
    # `tools` holds the state of the Helyx tools (`Tools`).
    @enforce_keys [:model, :cwd]
    defstruct [
      :model,
      :cwd,
      :resume,
      :port,
      :thread,
      :terminal,
      :turn_id,
      :turn,
      :from,
      :interrupt,
      :closing,
      :prompt,
      tools: %Tools{},
      fresh?: false,
      due: %{},
      next_id: 1,
      out: [],
      buffer: [],
      size: 0,
      items: %Items{},
      agents: %{},
      steers: %{},
      asked: %{}
    ]
  end

  # The fields of a turn, set back to their defaults between turns.
  @turn_fields ~w(turn_id turn items steers)a

  @trust %{approvalPolicy: "never", sandbox: "danger-full-access"}

  @impl true
  def id, do: "codex"

  @impl true
  defdelegate release(handles, mode, deadline), to: HarnessIO

  @impl true
  def init(model, tools, opts) do
    with {:ok, exe} <- HarnessIO.find("codex") do
      state = %State{
        model: model,
        tools: %Tools{specs: tools},
        cwd: Keyword.fetch!(opts, :cwd),
        resume: Tools.resumable(opts[:resume_id], tools)
      }

      case HarnessIO.launch(exe, ["app-server"], state.cwd, state) do
        %State{terminal: {:error, reason}} -> {:error, reason}
        state -> handshake(rpc(state, "initialize", Tools.initialize_params(tools)))
      end
    end
  end

  # Reads the program's lines until the thread is ready. The connect kill
  # of Core bounds the wait. Only the port's messages are taken: any
  # other stays for the provider loop.
  defp handshake(%State{port: port} = state) do
    message =
      receive do
        {^port, _} = message -> message
        {:DOWN, _ref, :port, ^port, _reason} = message -> message
      end

    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, _, %State{terminal: {:error, reason}}} -> {:error, reason}
      {:lines, _, %State{thread: nil} = state} -> handshake(state)
      {:lines, _, state} -> {:ok, state}
      {:exit, status} -> {:error, {:codex_exit, status}}
      :other -> handshake(state)
    end
  end

  @impl true
  def request(
        {:turn, turn_id, %Helyx.Context{messages: messages}},
        from,
        %State{
          turn_id: nil
        } = state
      ) do
    {prompt, history} = HarnessIO.split_prompt(messages)
    state = %{state | turn_id: turn_id, from: from, prompt: prompt}

    actions(
      if state.fresh?, do: replay(history, %{state | fresh?: false}), else: start_turn(state)
    )
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

    actions(%{
      state
      | steers: Map.put(state.steers, steer_id, true),
        asked: Map.put(state.asked, id, {from, steer_id})
    })
  end

  def request({:steer, _turn_id, _steer_id, _text}, from, state),
    do: actions(reply(state, from, :rejected))

  # No tool item outlives a turn; a child thread's work belongs to the
  # program.
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

  def request(:close, from, state) do
    HarnessIO.write(state, <<0>>)
    actions(%{state | closing: from})
  end

  @impl true
  def info(message, state) do
    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, _, %State{terminal: {:error, reason}} = state} -> {:stop, reason, state}
      {:lines, _, state} -> actions(state)
      {:closed, from} -> actions(reply(state, from, :ok))
      {:exit, status} -> {:stop, {:codex_exit, status}, state}
      :other -> actions(state)
    end
  end

  defp actions(state), do: {:ok, Enum.reverse(state.out), %{state | out: []}}

  defp reply(state, from, value), do: %{state | out: [{:reply, from, value} | state.out]}

  # `events` in order; `out` is newest first.
  defp push(state, events),
    do: %{state | out: Enum.reverse(Enum.map(events, &{:event, state.turn_id, &1}), state.out)}

  # Output

  # At `turn/completed`: the terminal, the answer to an interrupt, and the
  # fields of a turn back to idle. A tool item still
  # open outlives its turn (#198), whatever the status, and so does a child
  # thread of an aborted turn, so the provider process stops instead: the
  # release TERMs the program, which ends its commands, before a next turn
  # starts.
  defp end_turn(state, terminal) do
    if reason = outlives(state) do
      %{state | terminal: {:error, reason}}
    else
      state = push(state, [terminal])

      state =
        case state.interrupt do
          {:pending, from} -> reply(%{state | interrupt: nil}, from, :ok)
          {:sent, from, _id} -> reply(%{state | interrupt: nil}, from, :ok)
          nil -> state
        end

      Map.merge(state, Map.take(%State{model: nil, cwd: nil}, @turn_fields))
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

  # A Helyx tool call. The request only runs the tool, so it goes out at
  # once.
  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call", "params" => params}, state)
       when is_map(params) do
    case Tools.call(state, rpc_id, params) do
      {{:ok, request}, tools} -> {[], push(%{state | tools: tools}, [request])}
      {{:error, text}, tools} -> {[], tool_answer(%{state | tools: tools}, rpc_id, :error, text)}
    end
  end

  # A request of the server (it has an id and a method).
  defp dispatch(%{"id" => id, "method" => method}, state) do
    answer =
      if method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"],
        do: %{result: %{decision: "accept"}},
        else: %{error: %{code: -32_601, message: "not supported by Helyx"}}

    send_line(state, Map.put(answer, :id, id))
    {[], state}
  end

  defp dispatch(%{"id" => id} = response, %State{due: due} = state) when is_map_key(due, id) do
    {method, due} = Map.pop(due, id)
    answered(method, response, %{state | due: due})
  end

  # Only the notifications of this program's thread count: a sub-agent's
  # thread stays inside the harness.
  defp dispatch(%{"method" => method, "params" => %{"threadId" => thread} = params}, state)
       when thread == state.thread and is_binary(thread),
       do: turn_notification(method, params, state)

  defp dispatch(_object, state), do: {[], state}

  defp answered("initialize", %{"result" => _}, state) do
    send_line(state, %{method: "initialized"})

    if state.resume do
      params = Map.merge(thread_params(state), %{threadId: state.resume, excludeTurns: true})
      {[], rpc(state, "thread/resume", params)}
    else
      {[], start_thread(state)}
    end
  end

  # The program has no such thread: a fresh one starts on the same run.
  defp answered("thread/resume", %{"error" => _}, state), do: {[], start_thread(state)}

  # The thread's digest is the session's (`Tools.resumable/2`).
  defp answered("thread/resume", _response, state), do: {[], %{state | thread: state.resume}}

  defp answered("thread/start", %{"result" => %{"thread" => %{"id" => thread}}}, state),
    do: {[], %{state | thread: thread, fresh?: true}}

  defp answered(method, response, state)
       when method in ["thread/inject_items", "turn/start", "turn/interrupt"],
       do: {[], answer(method, response, state)}

  # Only the exact error of a steer that crossed the turn's end confirms
  # that the program did not take it (research note). The error of a turn
  # id mismatch has no verified exact form, so it is unknown, as any other.
  defp answered("turn/steer", %{"id" => id} = response, state) do
    {{from, steer_id}, asked} = Map.pop!(state.asked, id)
    state = %{state | asked: asked}

    case response do
      %{"result" => _} ->
        {[], reply(state, from, :ok)}

      %{"error" => %{"code" => -32_600, "message" => "no active turn to steer"}} ->
        {[], reply(%{state | steers: Map.delete(state.steers, steer_id)}, from, :rejected)}

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
       when method in ["item/started", "item/completed"] and is_binary(turn),
       do: {[], %{state | agents: Map.put(state.agents, item["agentThreadId"], turn)}}

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
       when turn != nil do
    {id, state} = open(state, "turn/interrupt")
    params = %{threadId: state.thread, turnId: turn}
    send_line(state, %{id: id, method: "turn/interrupt", params: params})
    %{state | interrupt: {:sent, from, id}}
  end

  defp send_interrupt(state), do: state

  # The `userMessage` item of a sent steer, once: the program took it.
  defp notification(
         method,
         %{"item" => %{"type" => "userMessage", "clientId" => id}},
         %State{steers: steers} = state
       )
       when method in ["item/started", "item/completed"] and is_map_key(steers, id) do
    {[{:user_message, id}], %{state | steers: Map.delete(steers, id)}}
  end

  defp notification(method, params, state) do
    {events, items} = Items.notification(method, params, state.items)
    {events, %{state | items: items}}
  end

  # Input

  defp thread_params(state), do: Map.merge(@trust, %{model: state.model, cwd: state.cwd})

  defp start_thread(%State{tools: %Tools{specs: []}} = state),
    do: rpc(state, "thread/start", thread_params(state))

  defp start_thread(state) do
    params = Map.put(thread_params(state), :dynamicTools, Tools.specs(state.tools.specs))
    rpc(state, "thread/start", params)
  end

  defp tool_answer(state, rpc_id, status, text) do
    result = %{contentItems: [%{type: "inputText", text: text}], success: status == :ok}
    send_line(state, %{id: rpc_id, result: result})
    state
  end

  # The first turn of a fresh thread: its id and cut, then the replay, if
  # any. The turn's `turn/start` waits for the replay's answer.
  defp replay(history, state) do
    {items, cut} = Replay.items(history)
    state = push(state, [{:resume, Tools.session_id(state.thread, state.tools.specs), cut}])

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

  defp rpc(state, method, params) do
    {id, state} = open(state, method)
    send_line(state, %{id: id, method: method, params: params})
    state
  end

  # A new request id, due until its answer.
  defp open(%State{next_id: id} = state, method),
    do: {id, %{state | next_id: id + 1, due: Map.put(state.due, id, method)}}

  defp send_line(state, %{} = map), do: send_line(state, JSON.encode!(map))
  defp send_line(state, line), do: HarnessIO.write(state, [line, "\n"])
end
