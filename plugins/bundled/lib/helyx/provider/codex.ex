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
  alias Helyx.Provider.Codex.{Check, Order}

  defmodule Tools do
    @moduledoc false
    # `specs` are the Helyx tool specs to offer, `[]` when the program did
    # not take `experimentalApi`; `notice` is the text for the next turn,
    # or nil. `requests` maps the call id of each open `item/tool/call` to
    # its request id; `used` holds every call id of the running turn's
    # `item/tool/call` requests, answered or not.
    defstruct specs: [], notice: nil, requests: %{}, used: MapSet.new()
  end

  defmodule State do
    @moduledoc false
    # The program of one provider process. `resume` is the thread id to
    # resume, or nil; `thread` the thread's id, and `fresh?` whether it
    # still waits for its replay. `turn_id` is the Helyx turn, `turn` the
    # program's turn id, `from` the `{:turn, ...}` without an answer,
    # `interrupt` an interrupt without an answer (`{:pending, from}` before
    # the turn id is known or while an earlier `turn/interrupt` answer is
    # due, `{:sent, from}` after `turn/interrupt`),
    # `due` maps the id of each request without an answer to its method,
    # `next_id` is the id of the next request, `closing` the close without an
    # answer, `prompt` the prompt of a turn whose `turn/start`
    # waits for an answer in `due`, and `out` the actions to return,
    # newest first.
    # `terminal` set means the provider process must stop, with that error.
    #
    # `agents` maps each child thread with open work to the program's turn
    # id of its first `subAgentActivity` item, or of the last one that came
    # with the running turn's id. It belongs to the program and stays
    # between turns.
    #
    # Of the running turn: `open` maps the open tool items to their types,
    # `started` holds the ids of the tool items that have a tool call, and
    # `streamed` the ids of the messages whose text came as deltas.
    # `calls` holds the ids of the tool calls of the message that no
    # `message_end` closed yet; `order` the events that wait for the results
    # of the calls of sent messages (`Order`).
    # `steers` maps the id of each steer sent in the running turn with no
    # `userMessage` item yet to its text. `asked` maps the request id of each
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
      usage: %{},
      calls: [],
      open: %{},
      agents: %{},
      order: %Order{},
      started: MapSet.new(),
      streamed: MapSet.new(),
      steers: %{},
      asked: %{}
    ]
  end

  # The fields of a turn, set back to their defaults between turns.
  @turn_fields ~w(turn_id turn from usage calls open order started streamed steers)a

  # Each request gets a new id, and `due` holds it until its answer. An
  # answer with an id that is not due (a late or duplicate answer) is
  # dropped, so it never answers a later request. A `turn/interrupt` goes
  # out only when no `turn/interrupt` answer is due, and a `turn/start` only
  # when no `turn/start` or `thread/inject_items` answer is due: a turn can
  # complete before the answer to its `turn/start` or `turn/interrupt`, and
  # that late answer then belongs to no turn.

  # Item types that run something (see the research note).
  @tool_item_types Check.tool_item_types()
  @trust %{approvalPolicy: "never", sandbox: "danger-full-access"}
  # The error of a `dynamicTools` field with no `experimentalApi` (research
  # note).
  @no_experimental "thread/start.dynamicTools requires experimentalApi capability"
  @tools_off "the Helyx tools are off for Codex: the program did not accept the experimental API"
  @unmapped "the call does not map to a tool use"

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
        resume: resumable(opts[:resume_id], tools)
      }

      case HarnessIO.launch(exe, ["app-server"], state.cwd, state) do
        %State{terminal: {:error, reason}} -> {:error, reason}
        state -> handshake(rpc(state, "initialize", initialize_params(tools)))
      end
    end
  end

  defp initialize_params([]), do: %{clientInfo: %{name: "helyx", version: "0"}}

  defp initialize_params(_tools),
    do: Map.put(initialize_params([]), :capabilities, %{experimentalApi: true})

  # The stored id names the thread and the digest of its Helyx tools. A
  # thread whose tool set is not the session's is not resumed: its tool
  # set is fixed (research note), so a new thread starts with the replay.
  defp resumable(nil, _tools), do: nil

  defp resumable(id, tools) do
    case String.split(id, "#", parts: 2) do
      [thread, digest] -> if digest == digest(tools), do: thread
      [thread] -> if tools == [], do: thread
    end
  end

  defp digest([]), do: nil

  defp digest(tools), do: HarnessIO.hex_digest(JSON.encode!(specs(tools)), Check.digest_hex())

  defp specs(tools) do
    for tool <- tools,
        do: %{
          type: "function",
          name: tool.name,
          description: tool.description,
          inputSchema: tool.parameters
        }
  end

  defp session_id(%State{thread: thread, tools: %Tools{specs: []}}), do: thread
  defp session_id(%State{thread: thread, tools: tools}), do: thread <> "#" <> digest(tools.specs)

  # Reads the program's lines until the thread is ready. The connect kill
  # of Core bounds the wait. Only the port's messages are taken: any
  # other stays for the provider loop.
  defp handshake(%State{port: port} = state) do
    message =
      receive do
        {^port, _} = message -> message
        {:DOWN, _ref, :port, ^port, _reason} = message -> message
      end

    case HarnessIO.port_message(message, state, &in_order/2) do
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

    state =
      case state.tools.notice do
        nil -> state
        text -> %{push(state, [{:notice, text}]) | tools: %{state.tools | notice: nil}}
      end

    state = if state.fresh?, do: replay(history, %{state | fresh?: false}), else: state

    actions(start_turn(state))
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
      | steers: Map.put(state.steers, steer_id, text),
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
    case HarnessIO.port_message(message, state, &in_order/2) do
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

  # Translates a line and puts its events in order (`Order`). An event
  # over the held cap stops the provider process, as a line over the cap
  # does; the events after it are not read.
  defp in_order(object, state) do
    case translate(object, state) do
      {_events, %{terminal: {:error, _}} = state} ->
        {[], state}

      {events, state} ->
        {out, order, stop} = Order.put(events, state.order)
        state = push(%{state | order: order}, out)
        {[], if(stop, do: %{state | terminal: {:error, stop}}, else: state)}
    end
  end

  # At `turn/completed`: the answer to the turn if its `turn/start` answer
  # did not come yet, the terminal, the answer to an interrupt, and the
  # fields of a turn back to idle. A tool item still
  # open outlives its turn (#198), whatever the status, and so does a child
  # thread of an aborted turn, so the provider process stops instead: the
  # release TERMs the program, which ends its commands, before a next turn
  # starts.
  defp end_turn(state, terminal) do
    if reason = outlives(state) do
      %{state | terminal: {:error, reason}}
    else
      state = if state.from, do: reply(%{state | from: nil}, state.from, :ok), else: state

      # A held event waits for an open tool item (see `Order`).
      true = Order.empty?(state.order)
      state = push(state, [terminal])

      state =
        case state.interrupt do
          {_pending_or_sent, from} -> reply(%{state | interrupt: nil}, from, :ok)
          nil -> state
        end

      state = %{state | tools: %{state.tools | used: MapSet.new()}}
      Map.merge(state, Map.take(%State{model: nil, cwd: nil}, @turn_fields))
    end
  end

  # Why the turn's work can outlive its end, or nil.
  defp outlives(state) do
    cond do
      command?(state) -> :command_running
      map_size(state.open) > 0 -> :tool_running
      state.interrupt != nil and agent?(state) -> :agent_running
      true -> nil
    end
  end

  defp command?(state), do: "commandExecution" in Map.values(state.open)

  # A child thread of the running turn has open work. Every turn id in
  # `agents` is a string (`Check`), so a turn with no id has none.
  defp agent?(state), do: state.turn in Map.values(state.agents)

  defp translate(object, state) do
    case Check.malformed(object, state) do
      nil -> dispatch(object, state)
      what -> {[], %{state | terminal: {:error, {:malformed, what}}}}
    end
  end

  # A Helyx tool call. The call id of the running turn is recorded in
  # `used` before any check that answers it, so an id that got any answer
  # never runs later in the turn. The request only runs the tool, so it
  # goes out at once, never held.
  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call", "params" => params}, state)
       when is_map(params) do
    case {state.turn_id, params["callId"]} do
      {nil, _call_id} ->
        {[], tool_answer(state, rpc_id, :error, "no Helyx turn is running")}

      {_turn_id, call_id} when is_binary(call_id) ->
        tools = state.tools
        used? = MapSet.member?(tools.used, call_id)
        state = %{state | tools: %{tools | used: MapSet.put(tools.used, call_id)}}

        cond do
          used? ->
            {[], tool_answer(state, rpc_id, :error, "the call id was used before in this turn")}

          tool_call?(params, state) ->
            request = {:tool_request, call_id, params["tool"], params["arguments"]}
            tools = %{state.tools | requests: Map.put(tools.requests, call_id, rpc_id)}
            {[], %{push(state, [request]) | tools: tools}}

          true ->
            {[], tool_answer(state, rpc_id, :error, @unmapped)}
        end

      _unmapped ->
        {[], tool_answer(state, rpc_id, :error, @unmapped)}
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

  # The program did not take `experimentalApi`: it runs without the Helyx
  # tools. The exact error is not known, so any error answer counts.
  defp answered("initialize", %{"error" => _}, %State{tools: %Tools{specs: [_ | _]}} = state),
    do: {[], rpc(tools_off(state), "initialize", initialize_params([]))}

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

  # The thread's digest is the session's (`resumable/2`), and its tools
  # work with no `experimentalApi` (research note), so no notice.
  defp answered("thread/resume", _response, state),
    do: {[], %{state | thread: state.resume, tools: %{state.tools | notice: nil}}}

  defp answered("thread/start", %{"result" => %{"thread" => %{"id" => thread}}}, state),
    do: {[], %{state | thread: thread, fresh?: true}}

  defp answered(
         "thread/start",
         %{"error" => %{"code" => -32_600, "message" => @no_experimental}},
         %State{tools: %Tools{specs: [_ | _]}} = state
       ),
       do: {[], start_thread(tools_off(state))}

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

  # A turn that completed before this answer has its reply already, so
  # the answer belongs to no turn; a turn that waits for it starts now.
  defp answer("turn/start", _response, %State{from: from, prompt: prompt} = state)
       when from == nil or prompt != nil,
       do: start_turn(state)

  defp answer("turn/start", %{"result" => %{"turn" => %{"id" => turn}}}, state),
    do: turn_started(turn, reply(%{state | from: nil}, state.from, :ok), true)

  defp answer("thread/inject_items", %{"result" => _}, state), do: start_turn(state)

  defp answer("turn/interrupt", %{"error" => _} = response, %{interrupt: {:sent, from}} = state),
    do: reply(%{state | interrupt: nil}, from, {:error, failure("turn/interrupt", response)})

  # The turn's end, not this answer, ends an interrupt; a pending one goes
  # out now.
  defp answer("turn/interrupt", _response, state), do: send_interrupt(state)

  # An error answer to `turn/start` or `thread/inject_items` fails the turn,
  # and the provider process stops.
  defp answer(method, response, state),
    do: reply(%{state | from: nil}, state.from, {:error, failure(method, response)})

  defp failure(method, response),
    do: {:codex, method, HarnessIO.cap_error(error_message(response) || "unexpected response")}

  defp turn_notification("turn/started", %{"turn" => %{"id" => turn}}, state),
    do: {[], turn_started(turn, state, due?(state, "turn/start") and state.prompt == nil)}

  defp turn_notification(
         "turn/completed",
         %{"turn" => %{"id" => turn} = result},
         %{turn: turn} = state
       ),
       do: {[], end_turn(state, terminal(result, state))}

  # The end of a turn that did not start, or that already ended.
  defp turn_notification("turn/completed", _params, state),
    do: {[], %{state | terminal: {:error, :turn_not_asked}}}

  # A child thread's work outlives its turn: the item can come with the id
  # of an ended turn (#226). Only `completed` confirms that the work ended.
  # A known child moves only to the running turn, so a late item with
  # another turn id never takes it from its turn (#244).
  defp turn_notification(
         method,
         %{"turnId" => turn, "item" => %{"type" => "subAgentActivity"} = item},
         state
       )
       when method in ["item/started", "item/completed"] do
    agents =
      case item do
        %{"kind" => "completed", "agentThreadId" => child} ->
          Map.delete(state.agents, child)

        %{"agentThreadId" => child} when turn == state.turn ->
          Map.put(state.agents, child, turn)

        %{"agentThreadId" => child} ->
          Map.put_new(state.agents, child, turn)
      end

    {[], %{state | agents: agents}}
  end

  defp turn_notification(method, %{"turnId" => turn} = params, %{turn: turn} = state)
       when is_binary(turn),
       do: notification(method, params, state)

  # An item of a turn that is not the running one, such as the late
  # `item/completed` of a command that `turn/interrupt` left running.
  defp turn_notification("item/" <> _, %{"turnId" => turn}, state) when is_binary(turn),
    do: {[], %{state | terminal: {:error, :item_of_ended_turn}}}

  defp turn_notification(_method, _params, state), do: {[], state}

  # The running Helyx turn learns its program turn id from the `turn/start`
  # answer or from `turn/started`, from the first of the two; a pending
  # interrupt goes out then. A new id from `turn/started` counts only while
  # the turn's own `turn/start` is open (`asked?`). Any other turn is one
  # that Helyx did not ask for.
  defp turn_started(turn, %State{turn_id: turn_id, turn: known} = state, asked?)
       when turn_id != nil and (known == turn or (known == nil and asked?)) do
    send_interrupt(%{state | turn: turn})
  end

  defp turn_started(_turn, state, _asked?),
    do: %{state | terminal: {:error, :turn_not_asked}}

  # A pending interrupt goes out when the turn id is known and no
  # `turn/interrupt` answer is due.
  defp send_interrupt(%State{interrupt: {:pending, from}, turn: turn} = state)
       when turn != nil do
    if due?(state, "turn/interrupt") do
      state
    else
      rpc(%{state | interrupt: {:sent, from}}, "turn/interrupt", %{
        threadId: state.thread,
        turnId: turn
      })
    end
  end

  defp send_interrupt(state), do: state

  defp notification("item/agentMessage/delta", %{"delta" => text, "itemId" => id}, state)
       when is_binary(text) and text != "" do
    {[{:text_delta, text}], %{state | streamed: MapSet.put(state.streamed, id)}}
  end

  defp notification(method, %{"delta" => text}, state)
       when method in ["item/reasoning/summaryTextDelta", "item/reasoning/textDelta"] and
              is_binary(text) and text != "",
       do: {[{:thinking_delta, text}], state}

  # The `userMessage` item of a sent steer, once: the program took it.
  defp notification(
         method,
         %{"item" => %{"type" => "userMessage", "clientId" => id}},
         %State{steers: steers} = state
       )
       when method in ["item/started", "item/completed"] and is_map_key(steers, id) do
    {text, steers} = Map.pop!(steers, id)
    {[{:user_message, id, text}], %{state | steers: steers}}
  end

  defp notification("item/started", %{"item" => %{"type" => type, "id" => id} = item}, state)
       when type in @tool_item_types do
    state = %{
      state
      | started: MapSet.put(state.started, id),
        calls: [id | state.calls],
        open: Map.put(state.open, id, type)
    }

    {[tool_call(item)], state}
  end

  # A message whose text came with no delta gives it whole.
  defp notification(
         "item/completed",
         %{"item" => %{"type" => "agentMessage", "id" => id, "text" => text}},
         state
       )
       when is_binary(text) and text != "" do
    if MapSet.member?(state.streamed, id),
      do: {[], state},
      else: {[{:text_delta, text}], state}
  end

  # The first result of a message's calls closes it; the results of its
  # other calls follow. A tool item that completes with no start gets its
  # call first.
  defp notification("item/completed", %{"item" => %{"type" => type, "id" => id} = item}, state)
       when type in @tool_item_types do
    state = %{state | open: Map.delete(state.open, id)}

    {calls, state} =
      if MapSet.member?(state.started, id),
        do: {[], state},
        else:
          {[tool_call(item)],
           %{state | started: MapSet.put(state.started, id), calls: [id | state.calls]}}

    result = {:tool_result, id, tool_result(item)}

    if id in state.calls do
      close = {:close, state.calls, {:message_end, :tool_use, state.usage}}
      {calls ++ [close, result], %{state | calls: []}}
    else
      {[result], state}
    end
  end

  defp notification("thread/tokenUsage/updated", %{"tokenUsage" => %{"last" => usage}}, state)
       when is_map(usage),
       do: {[], %{state | usage: usage}}

  defp notification(_method, _params, state), do: {[], state}

  defp terminal(%{"status" => "completed"}, state),
    do: {:done, %{stop_reason: :end_turn, usage: state.usage}}

  defp terminal(%{"status" => status} = result, _state),
    do: {:error, {:codex, status, HarnessIO.cap_error(error_message(result))}}

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(_map), do: nil

  defp tool_call(%{"type" => type, "id" => id} = item),
    do: {:tool_call, %Message.ToolCall{id: id, name: type, arguments: arguments(item)}}

  defp arguments(%{"type" => "commandExecution"} = item), do: Map.take(item, ["command", "cwd"])

  defp arguments(item),
    do:
      item
      |> Map.drop(["id", "type", "status"])
      |> Map.reject(fn {_key, value} -> value == nil end)

  # A command gives its output; any other tool item gives its fields as
  # JSON.
  defp tool_result(item) do
    text =
      case item do
        %{"type" => "commandExecution", "aggregatedOutput" => out} when is_binary(out) -> out
        %{"type" => "commandExecution"} -> ""
        _ -> JSON.encode!(Map.drop(item, ["id", "type"]))
      end

    failed? =
      item["status"] in ["failed", "declined"] or item["error"] != nil or
        (is_integer(item["exitCode"]) and item["exitCode"] != 0)

    {if(failed?, do: :error, else: :ok), Helyx.Text.truncate(text, :tail)}
  end

  # Input

  defp thread_params(state), do: Map.merge(@trust, %{model: state.model, cwd: state.cwd})

  defp start_thread(%State{tools: %Tools{specs: []}} = state),
    do: rpc(state, "thread/start", thread_params(state))

  defp start_thread(state) do
    params = Map.put(thread_params(state), :dynamicTools, specs(state.tools.specs))
    rpc(state, "thread/start", params)
  end

  defp tools_off(state), do: %{state | tools: %Tools{notice: @tools_off}}

  # The call maps to an open `dynamicToolCall` item of the running turn,
  # which puts it in the transcript, and has the shape of the schema.
  defp tool_call?(%{"threadId" => thread, "turnId" => turn, "callId" => id} = params, state),
    do:
      thread == state.thread and turn == state.turn and state.open[id] == "dynamicToolCall" and
        is_binary(params["tool"]) and is_map(params["arguments"])

  defp tool_call?(_params, _state), do: false

  defp tool_answer(state, rpc_id, status, text) do
    result = %{contentItems: [%{type: "inputText", text: text}], success: status == :ok}
    send_line(state, %{id: rpc_id, result: result})
    state
  end

  # The first turn of a fresh thread: its id and cut, then the replay, if
  # any. The turn's `turn/start` waits for the replay's answer.
  defp replay(history, state) do
    {items, cut} = replay_items(history)
    state = push(state, [{:resume, session_id(state), cut}])

    if items == [] do
      state
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

  # The `turn/start` of a turn that waits, when neither its replay's answer
  # nor the answer to the last `turn/start` is due.
  defp start_turn(%State{prompt: prompt, turn_id: turn_id} = state)
       when prompt != nil and turn_id != nil do
    if due?(state, "thread/inject_items") or due?(state, "turn/start") do
      state
    else
      input =
        for %Message{content: blocks} <- prompt,
            %Message.Text{text: text} <- blocks,
            text != "",
            do: %{type: "text", text: text}

      rpc(%{state | prompt: nil}, "turn/start", %{threadId: state.thread, input: input})
    end
  end

  defp start_turn(state), do: state

  defp rpc(state, method, params) do
    {id, state} = open(state, method)
    send_line(state, %{id: id, method: method, params: params})
    state
  end

  # A new request id, due until its answer.
  defp open(%State{next_id: id} = state, method),
    do: {id, %{state | next_id: id + 1, due: Map.put(state.due, id, method)}}

  defp due?(state, method), do: method in Map.values(state.due)

  defp send_line(state, %{} = map), do: send_line(state, JSON.encode!(map))
  defp send_line(state, line), do: HarnessIO.write(state, [line, "\n"])

  # One entry per message, with its Responses API items: an assistant
  # message gives a message item per text and a `function_call` per tool
  # call (thinking is not replayed), a user message a message item, and a
  # tool result a `function_call_output`. The replay may start at any
  # message but a tool result, so every kept result keeps its call.
  defp replay_items(history) do
    entries =
      for message <- history do
        items = items(message)
        {items != [] && items, 1, message.role != :tool_result}
      end

    {kept, cut} = HarnessIO.cap_replay(entries, length(history))
    {List.flatten(kept), cut}
  end

  defp items(%Message{role: :tool_result} = message) do
    [
      item(%{
        type: "function_call_output",
        call_id: HarnessIO.wire_id(message.tool_call_id),
        output: Message.text(message)
      })
    ]
  end

  defp items(%Message{role: role, content: blocks}) do
    for block <- blocks, item = block_item(role, block), do: item(item)
  end

  defp block_item(:user, %Message.Text{text: text}) when text != "",
    do: %{type: "message", role: "user", content: [%{type: "input_text", text: text}]}

  defp block_item(:assistant, %Message.Text{text: text}) when text != "",
    do: %{type: "message", role: "assistant", content: [%{type: "output_text", text: text}]}

  defp block_item(:assistant, %Message.ToolCall{} = call) do
    %{
      type: "function_call",
      call_id: HarnessIO.wire_id(call.id),
      name: tool_name(call.name),
      arguments: JSON.encode!(call.arguments)
    }
  end

  defp block_item(_role, _block), do: nil

  # Each item is encoded once, so the cap counts its bytes.
  defp item(map), do: JSON.encode!(map)

  # The model API takes a tool name of `[a-zA-Z0-9_-]` only; the cut at 64
  # is the function name limit of the Chat Completions API, not verified for
  # `thread/inject_items` (see the research note).
  defp tool_name(name) do
    case String.replace(name, ~r/[^a-zA-Z0-9_-]/u, "_") do
      "" -> "_"
      name -> binary_part(name, 0, min(byte_size(name), 64))
    end
  end
end
