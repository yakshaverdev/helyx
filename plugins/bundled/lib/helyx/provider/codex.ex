defmodule Helyx.Provider.Codex do
  # The TERM grace of the release: codex ends its commands itself on TERM.
  @term_grace_ms 5_000
  # The most events held at once (see `in_order/2`).
  @held_max 10_000

  alias Helyx.HarnessIO

  @moduledoc """
  A connected harness provider (ADR 0007) that drives the unmodified Codex
  program through its app server, `codex app-server`, with JSON-RPC lines
  over stdio. The model ref is `codex/<model>`, where `<model>` is a model
  id of `codex`, such as `gpt-6-luna`.

  One program serves the session's harness process
  (`docs/features/long-lived-harness.md`, section "Codex"). It runs from
  `PATH` in the session's working directory, in its own process group under
  the watchdog of `Helyx.Watchdog`, with open input. `harness_init/3`
  holds its groups with `Helyx.Tool.hold/1`, moves the port's link to a
  keeper (`Helyx.HarnessIO.keep_port/1`), sends `initialize`, and returns
  when the thread is ready: `thread/resume` with `:harness_session_id`, or
  `thread/start` when there is no id or the program has no such thread.
  Threads run with the approval policy `never` and the sandbox
  `danger-full-access`, the same trust as the bash tool, sent again on
  every resume. The harness process does not trap exits.

  Each `{:turn, ...}` sends `turn/start` with the prompt: the user messages
  at the end of the context. The first turn of a fresh thread first gives
  it the rest of the transcript with `thread/inject_items` and emits
  `{:harness_session, id, cut}`. The replay keeps the newest messages
  within #{HarnessIO.replay_max_bytes()} bytes of items, and it never starts
  at a tool result. The answer is `:ok` at the `turn/start` result, which
  carries the program's turn id, or at `turn/completed` when that comes
  first.

  A steer of the running turn is `turn/steer` with `expectedTurnId` and
  `clientUserMessageId` set to the steer id; after `turn/completed` it
  answers `:rejected` and sends nothing. A result answers `:ok`, the exact
  error `no active turn to steer` (code -32600) answers `:rejected`, and
  any other error answers `{:error, reason}`. The `userMessage` item whose
  `clientId` is the steer id gives `{:user_message, steer_id, text}`.

  `{:interrupt, ...}` on a turn with an open `commandExecution` item
  answers `{:error, :command_running}` at once, because `turn/interrupt`
  does not end a running command; the loop then ends, and the watchdog
  TERMs the group, on which codex ends its commands. A child thread of the
  turn with open work (a sub-agent) answers `{:error, :agent_running}` the
  same way. Otherwise it sends
  `turn/interrupt`, when the program's turn id is known and no answer to
  an earlier `turn/interrupt` is due, and answers at `turn/completed`. An
  interrupt of a turn that already ended answers `:ok`. A turn that ends
  with an open tool item, whatever its status, stops the harness process,
  so that no next turn starts while the item runs; the turn and a pending
  interrupt then fail with the stop. So does a turn that ends while an
  interrupt waits and a child thread of the turn has open work. A child
  thread with open work at a normal end of its turn belongs to the program.
  A child thread has open work from its `subAgentActivity` item until one
  of kind `completed`, whatever turn id that item has. A `turn/started`
  with a new id while no `turn/start` of the running turn is open, a
  `turn/completed` of a turn whose id is not known, and an item of a turn
  that is not the running one stop the harness process. Every line that
  changes turn or thread state (`turn/started`, `turn/completed`,
  `item/started`, `item/completed`, and the answers to the requests)
  passes one check of its full shape before any state changes; `turn/completed` must have the status
  `completed`, `failed`, or `interrupted`, and a tool item's
  `item/completed` must keep its type and have a status that ends the item. An `item/started` of the
  running turn with the id of an item that has a tool call already fails
  the check. An answer is an error or a
  result, never both, and a turn or item notification has no request id.
  Each request has a new id, and an answer counts only for the request
  with its id that has no answer yet; any other answer (a late or
  duplicate one) is dropped. The `thread/resume` answer needs the asked
  thread id or the exact lost-thread error, and the `thread/start` answer
  a string thread id. Any other such line stops the
  harness process with `{:malformed, method}` (in the handshake, the
  connect fails with it). A turn or item line with no string `threadId`
  stops it the same way. `:close` ends the input and answers `:ok` at the
  exit. `:idle_close` does the same when no child thread has open work, and
  answers `:busy` otherwise: no tool item outlives a turn.

  A command or file change approval request is accepted; every other
  request from the server gets a JSON-RPC error. The program uses its own
  tools; Helyx tools are not offered. Its stderr is dropped.

  Assistant text and reasoning stream as deltas. A tool item (a command,
  a file change, a tool of an MCP server, or another tool item type of
  `docs/research/codex-app-server.md`) is a tool call
  when it starts and a tool result when it completes, and a `message_end`
  closes the assistant message before the result. A stdout line over
  #{HarnessIO.line_max_bytes()} bytes, more than #{@held_max} held events,
  and the program's exit stop the harness process. The protocol facts are
  in `docs/research/codex-app-server.md`.
  """

  @behaviour Helyx.Provider

  alias Helyx.Message

  defmodule State do
    @moduledoc false
    # The program of one harness process. `resume` is the thread id to
    # resume, or nil; `thread` the thread's id, and `fresh?` whether it
    # still waits for its replay. `turn_id` is the Helyx turn, `turn` the
    # program's turn id, `from` the `{:turn, ...}` without an answer,
    # `interrupt` an interrupt without an answer (`{:pending, from}` before
    # the turn id is known or while an earlier `turn/interrupt` answer is
    # due, `{:sent, from}` after `turn/interrupt`),
    # `due` maps the id of each request without an answer to its method,
    # `next_id` is the id of the next request, `close` the close without an
    # answer, `prompt` the prompt of a turn whose `turn/start`
    # waits for an answer in `due`, and `out` the actions to return,
    # newest first.
    # `terminal` set means the harness process must stop, with that error.
    #
    # `agents` maps each child thread with open work to the program's turn
    # id of its last `subAgentActivity` item. It belongs to the program and
    # stays between turns.
    #
    # Of the running turn: `open` maps the open tool items to their types,
    # `started` holds the ids of the tool items that have a tool call, and
    # `streamed` the ids of the messages whose text came as deltas.
    # `calls` holds the ids of the tool calls of the message that no
    # `message_end` closed yet; `waiting` the ids of the calls of sent
    # messages with no result yet; `held` the events that wait for those
    # results (see `in_order/2`).
    # `steers` maps the id of each steer sent in the running turn with no
    # `userMessage` item yet to its text. `asked` maps the request id of each
    # `turn/steer` with no answer yet to `{from, steer_id}`; it outlives the
    # turn, because the answer can come after `turn/completed`.
    @enforce_keys [:model, :cwd]
    defstruct [
      :model,
      :cwd,
      :resume,
      :port,
      :thread,
      :terminal,
      :deadline,
      :turn_id,
      :turn,
      :from,
      :interrupt,
      :close,
      :prompt,
      fresh?: false,
      due: %{},
      next_id: 1,
      out: [],
      buffer: [],
      size: 0,
      done?: false,
      usage: %{},
      calls: [],
      open: %{},
      agents: %{},
      waiting: MapSet.new(),
      held: :queue.new(),
      started: MapSet.new(),
      streamed: MapSet.new(),
      steers: %{},
      asked: %{}
    ]
  end

  # The fields of a turn, set back to their defaults between turns.
  @turn_fields ~w(turn_id turn from usage calls open waiting held started streamed steers)a

  # Each request gets a new id, and `due` holds it until its answer. An
  # answer with an id that is not due (a late or duplicate answer) is
  # dropped, so it never answers a later request. A `turn/interrupt` goes
  # out only when no `turn/interrupt` answer is due, and a `turn/start` only
  # when no `turn/start` or `thread/inject_items` answer is due: a turn can
  # complete before the answer to its `turn/start` or `turn/interrupt`, and
  # that late answer then belongs to no turn.

  @lost "no rollout found for thread id "
  # Item types that run something (see the research note).
  @tool_item_types ~w(commandExecution fileChange mcpToolCall dynamicToolCall collabAgentToolCall
            webSearch imageView imageGeneration)
  # The statuses that end a tool item, from the schema of codex 0.157.1
  # (research note). `imageGeneration` has a free string: every value but
  # `inProgress` ends it. A type with no status ends at its `item/completed`.
  @ended %{
    "commandExecution" => ~w(completed failed declined),
    "fileChange" => ~w(completed failed declined),
    "mcpToolCall" => ~w(completed failed),
    "dynamicToolCall" => ~w(completed failed),
    "collabAgentToolCall" => ~w(completed failed interrupted)
  }
  # The notifications that clear or confirm turn state, and the statuses
  # that end a turn.
  @turn_lines ~w(turn/started turn/completed item/started item/completed)
  @turn_ends ~w(completed failed interrupted)
  # The kinds of a `subAgentActivity` item in the schema of codex 0.157.1.
  @agent_kinds ~w(started interacted interrupted completed)
  @trust %{approvalPolicy: "never", sandbox: "danger-full-access"}

  @impl true
  def id, do: "codex"

  # `Helyx.Provider.turn/1` makes this `:connected`, because the module
  # exports `harness_init/3`.
  @impl true
  def turn, do: :external

  # A delivery TERMs first too: the harness process can end (a line over
  # the cap, a stop) while codex still runs a command.
  @impl true
  def release(handles, :deliver, deadline), do: release(handles, :cancel, deadline)

  def release(handles, mode, deadline),
    do: HarnessIO.release(handles, mode, deadline, grace_ms: @term_grace_ms)

  # The session calls the harness callbacks of a connected provider, never
  # this one.
  @impl true
  def stream(_model, _context, _opts), do: {:error, :connected}

  @impl true
  def harness_init(model, _tools, opts) do
    with {:ok, exe} <- HarnessIO.find("codex") do
      state = %State{
        model: model,
        cwd: Keyword.fetch!(opts, :cwd),
        resume: opts[:harness_session_id]
      }

      argv = ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), exe, "app-server"]

      case HarnessIO.start(argv, state.cwd, :open, state, grace_ms: @term_grace_ms) do
        %State{terminal: {:error, reason}} ->
          {:error, reason}

        state ->
          state = HarnessIO.keep_port(state)
          handshake(request(state, "initialize", %{clientInfo: %{name: "helyx", version: "0"}}))
      end
    end
  end

  # Reads the program's lines until the thread is ready. The connect kill
  # of Core bounds the wait.
  defp handshake(%State{port: port} = state) do
    receive do
      {^port, {:data, data}} ->
        case HarnessIO.lines(data, state, &in_order/2) do
          {_, %State{terminal: {:error, reason}}} -> {:error, reason}
          {_, %State{thread: nil} = state} -> handshake(state)
          {_, state} -> {:ok, state}
        end

      {^port, {:exit_status, status}} ->
        {:error, {:codex_exit, status}}

      {:DOWN, _ref, :port, ^port, reason} ->
        {:error, {:codex_exit, reason}}
    end
  end

  @impl true
  def harness_request(
        {:turn, turn_id, %Helyx.Context{messages: messages}},
        from,
        %State{
          turn_id: nil
        } = state
      ) do
    {prompt, history} = HarnessIO.split_prompt(messages)
    state = %{state | turn_id: turn_id, from: from, prompt: prompt}
    state = if state.fresh?, do: replay(history, %{state | fresh?: false}), else: state

    actions(start_turn(state))
  end

  # An open command, and a child thread's work, outlive `turn/interrupt`
  # (#198, #226), so the abort stops the program instead.
  def harness_request({:interrupt, turn_id}, from, %State{turn_id: turn_id} = state) do
    state =
      cond do
        command?(state) -> reply(state, from, {:error, :command_running})
        agent?(state) -> reply(state, from, {:error, :agent_running})
        true -> send_interrupt(%{state | interrupt: {:pending, from}})
      end

    actions(state)
  end

  # The turn already ended.
  def harness_request({:interrupt, _turn_id}, from, state), do: actions(reply(state, from, :ok))

  # A steer of the running turn goes out as `turn/steer`; the server checks
  # `expectedTurnId`. After `turn/completed` nothing goes out.
  def harness_request({:steer, turn_id, steer_id, text}, from, %State{turn_id: turn_id} = state)
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

  def harness_request({:steer, _turn_id, _steer_id, _text}, from, state),
    do: actions(reply(state, from, :rejected))

  # No tool item outlives a turn; a child thread's work belongs to the
  # program.
  def harness_request(:idle_close, from, %State{agents: agents} = state)
      when map_size(agents) > 0,
      do: actions(reply(state, from, :busy))

  def harness_request(:idle_close, from, state), do: harness_request(:close, from, state)

  def harness_request(:close, from, state) do
    HarnessIO.write(state, <<0>>)
    actions(%{state | close: from})
  end

  @impl true
  def harness_info({port, {:data, data}}, %State{port: port} = state) do
    case HarnessIO.lines(data, state, &in_order/2) do
      {_, %State{terminal: {:error, reason}} = state} -> {:stop, reason, state}
      {_, state} -> actions(state)
    end
  end

  def harness_info({port, {:exit_status, _status}}, %State{port: port, close: from} = state)
      when from != nil,
      do: actions(reply(state, from, :ok))

  def harness_info({port, {:exit_status, status}}, %State{port: port} = state),
    do: {:stop, {:codex_exit, status}, state}

  def harness_info({:DOWN, _ref, :port, port, reason}, %State{port: port} = state),
    do: {:stop, {:codex_exit, reason}, state}

  def harness_info(_message, state), do: actions(state)

  defp actions(state), do: {:ok, Enum.reverse(state.out), %{state | out: []}}

  defp reply(state, from, value), do: %{state | out: [{:reply, from, value} | state.out]}

  # `events` in order; `out` is newest first.
  defp push(state, events),
    do: %{state | out: Enum.reverse(Enum.map(events, &{:event, state.turn_id, &1}), state.out)}

  # Output

  # Codex runs tool items side by side, and the session gives every call
  # that is still open an `aborted` result at a `message_end`
  # (`Helyx.Provider`), so a call of a sent message can still run when the
  # next message closes. Such a `message_end`, and every event after it, is
  # held until the results of the sent calls are out; a result of a sent
  # call goes out at once. An event waits only for an open tool item, and a
  # turn that ends with one stops the harness process, so a turn that ends
  # holds nothing. An event over `@held_max` held events stops
  # the harness process, as a line over the cap does; the events after it
  # are not read.
  defp in_order(object, state) do
    {events, state} = translate(object, state)
    {out, state} = Enum.reduce(events, {[], state}, &order_one/2)
    {[], push(state, Enum.reverse(out))}
  end

  defp order_one(_event, {out, %{terminal: {:error, _}} = state}), do: {out, state}

  # `:queue.len/1` costs O(held), as a held result's insert does; the cap
  # bounds both.
  defp order_one(event, {out, state}) do
    cond do
      waiting_result?(event, state) ->
        flush(emit(event, {out, state}))

      :queue.is_empty(state.held) and not blocked?(event, state) ->
        emit(event, {out, state})

      :queue.len(state.held) >= @held_max ->
        {out, %{state | done?: true, terminal: {:error, {:held_over_limit, @held_max}}}}

      true ->
        {out, %{state | held: hold(event, state.held)}}
    end
  end

  # A held result goes right after its own `message_end` and the results
  # there, so a later `message_end` cannot hold it back. A result with no
  # held `message_end`, such as a repeat, goes to the end. Each insert
  # costs O(held), and `@held_max` bounds the held events.
  defp hold({:tool_result, id, _result} = event, held) do
    {before, rest} = Enum.split_while(:queue.to_list(held), &(not closes?(&1, id)))

    case rest do
      [close | tail] ->
        {results, later} = Enum.split_while(tail, &match?({:tool_result, _, _}, &1))
        :queue.from_list(before ++ [close | results] ++ [event | later])

      [] ->
        :queue.in(event, held)
    end
  end

  defp hold(event, held), do: :queue.in(event, held)

  defp closes?({:close, ids, _event}, id), do: id in ids
  defp closes?(_event, _id), do: false

  defp waiting_result?({:tool_result, id, _result}, state), do: MapSet.member?(state.waiting, id)
  defp waiting_result?(_event, _state), do: false

  # A `user_message` also closes the message in the session, and gives its
  # open calls an `aborted` result, so it waits as a `message_end` does.
  defp blocked?({:close, _ids, _event}, state), do: MapSet.size(state.waiting) > 0
  defp blocked?({:user_message, _id, _text}, state), do: MapSet.size(state.waiting) > 0
  defp blocked?(_event, _state), do: false

  defp emit({:close, ids, event}, {out, state}),
    do: {[event | out], %{state | waiting: MapSet.new(ids)}}

  defp emit({:tool_result, id, _result} = event, {out, state}),
    do: {[event | out], %{state | waiting: MapSet.delete(state.waiting, id)}}

  defp emit(event, {out, state}), do: {[event | out], state}

  # Sends the held events from the front up to a `message_end` that waits.
  defp flush({out, state}) do
    case :queue.out(state.held) do
      {{:value, event}, rest} ->
        if blocked?(event, state),
          do: {out, state},
          else: flush(emit(event, {out, %{state | held: rest}}))

      {:empty, _rest} ->
        {out, state}
    end
  end

  # At `turn/completed`: the answer to the turn if its `turn/start` answer
  # did not come yet, the terminal, the answer to an interrupt, and the
  # fields of a turn back to idle. A tool item still
  # open outlives its turn (#198), whatever the status, and so does a child
  # thread of an aborted turn, so the harness process stops instead: the
  # release TERMs the program, which ends its commands, before a next turn
  # starts.
  defp end_turn(state, terminal) do
    if reason = outlives(state) do
      %{state | done?: true, terminal: {:error, reason}}
    else
      state = if state.from, do: reply(%{state | from: nil}, state.from, :ok), else: state

      # A held event waits for an open tool item (see `in_order/2`).
      true = :queue.is_empty(state.held)
      state = push(state, [terminal])

      state =
        case state.interrupt do
          {_pending_or_sent, from} -> reply(%{state | interrupt: nil}, from, :ok)
          nil -> state
        end

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
  # `agents` is a string (`line?/2`), so a turn with no id has none.
  defp agent?(state), do: state.turn in Map.values(state.agents)

  defp translate(object, state) do
    case malformed(object, state) do
      nil -> dispatch(object, state)
      what -> {[], %{state | done?: true, terminal: {:error, {:malformed, what}}}}
    end
  end

  # The one check of every line that changes turn or thread state, before
  # any state changes: the answers to the due requests, and the turn and
  # item notifications of this program's thread. Gives nil, or the method of a
  # line without its full shape (the schema of codex 0.157.1, research
  # note); that line stops the harness process.
  # A turn or item notification is never a request, on any thread: such a
  # line is a protocol fault of the program.
  defp malformed(%{"id" => _, "method" => method}, _state) when method in @turn_lines,
    do: method

  defp malformed(%{"id" => _, "method" => _}, _state), do: nil

  # An answer to a due request. Any other answer is dropped.
  defp malformed(%{"id" => id} = answer, %State{due: due} = state) when is_map_key(due, id),
    do: if(answer?(due[id], answer, state), do: nil, else: due[id])

  defp malformed(%{"method" => method, "params" => %{"threadId" => thread} = params}, state)
       when method in @turn_lines and thread == state.thread and is_binary(thread),
       do: if(line?(method, params) and not again?(method, params, state), do: nil, else: method)

  # A turn or item line of another thread. With no string thread id (the
  # schema requires one), it can be a line of this thread.
  defp malformed(%{"method" => method, "params" => %{"threadId" => thread}}, _state)
       when method in @turn_lines and is_binary(thread),
       do: nil

  defp malformed(%{"method" => method}, _state) when method in @turn_lines, do: method

  defp malformed(_object, _state), do: nil

  # An `item/started` of the running turn with the id of an item that has
  # a tool call would add that tool call again. Only tool items are in
  # `started`. An `item/completed` of the running turn with the id of an
  # open tool item of another type would clear that item while it runs.
  defp again?(
         "item/started",
         %{"turnId" => turn, "item" => %{"id" => id}},
         %State{turn: turn} = state
       ),
       do: MapSet.member?(state.started, id)

  defp again?(
         "item/completed",
         %{"turnId" => turn, "item" => %{"id" => id, "type" => type}},
         %State{turn: turn} = state
       ),
       do: is_map_key(state.open, id) and state.open[id] != type

  defp again?(_method, _params, _state), do: false

  # An answer is an error object or a result, never both. A resume fails
  # only with the lost-thread error of the research note, and succeeds only
  # for the thread it asked for.
  defp answer?(_method, %{"error" => _, "result" => _}, _state), do: false

  defp answer?("thread/resume", %{"error" => %{"code" => -32_600, "message" => message}}, state),
    do: message == @lost <> state.resume

  defp answer?("thread/resume", %{"result" => %{"thread" => %{"id" => thread}}}, state),
    do: thread == state.resume

  defp answer?("thread/resume", _answer, _state), do: false

  defp answer?("thread/start", %{"result" => %{"thread" => %{"id" => thread}}}, _state),
    do: is_binary(thread)

  defp answer?("turn/start", %{"result" => %{"turn" => %{"id" => turn}}}, _state),
    do: is_binary(turn)

  defp answer?(method, %{"result" => _}, _state) when method in ["thread/start", "turn/start"],
    do: false

  defp answer?(_method, %{"error" => error}, _state), do: is_map(error)
  defp answer?(_method, %{"result" => result}, _state), do: is_map(result)
  defp answer?(_method, _answer, _state), do: false

  defp line?("turn/started", %{"turn" => %{"id" => turn}}), do: is_binary(turn)

  defp line?("turn/completed", %{"turn" => %{"id" => turn, "status" => status}}),
    do: is_binary(turn) and status in @turn_ends

  defp line?(method, %{
         "turnId" => turn,
         "item" => %{"type" => "subAgentActivity", "id" => id, "agentThreadId" => child} = item
       })
       when method in ["item/started", "item/completed"] and is_binary(turn) and is_binary(id) and
              is_binary(child),
       do: item["kind"] in @agent_kinds

  defp line?(_method, %{"item" => %{"type" => "subAgentActivity"}}), do: false

  # A tool item leaves the open work only with a status that ends it.
  defp line?(method, %{"turnId" => turn, "item" => %{"type" => type, "id" => id} = item})
       when method in ["item/started", "item/completed"] and is_binary(turn) and is_binary(type) and
              is_binary(id),
       do: method == "item/started" or type not in @tool_item_types or ended?(item)

  defp line?(_method, _params), do: false

  defp ended?(%{"type" => type, "status" => status}) when is_map_key(@ended, type),
    do: status in @ended[type]

  defp ended?(%{"type" => "imageGeneration", "status" => status}),
    do: is_binary(status) and status != "inProgress"

  defp ended?(%{"type" => type}) when is_map_key(@ended, type) or type == "imageGeneration",
    do: false

  defp ended?(_item), do: true

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
      {[], request(state, "thread/resume", params)}
    else
      {[], request(state, "thread/start", thread_params(state))}
    end
  end

  # The program has no such thread: a fresh one starts on the same run.
  defp answered("thread/resume", %{"error" => _}, state),
    do: {[], request(state, "thread/start", thread_params(state))}

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
    do: {[], %{state | done?: true, terminal: {:error, failure(method, response)}}}

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
  # and the harness process stops.
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
    do: {[], %{state | done?: true, terminal: {:error, :turn_not_asked}}}

  # A child thread's work outlives its turn: the item can come with the id
  # of an ended turn (#226). Only `completed` confirms that the work ended.
  defp turn_notification(
         method,
         %{"turnId" => turn, "item" => %{"type" => "subAgentActivity"} = item},
         state
       )
       when method in ["item/started", "item/completed"] do
    agents =
      case item do
        %{"kind" => "completed", "agentThreadId" => child} -> Map.delete(state.agents, child)
        %{"agentThreadId" => child} -> Map.put(state.agents, child, turn)
      end

    {[], %{state | agents: agents}}
  end

  defp turn_notification(method, %{"turnId" => turn} = params, %{turn: turn} = state)
       when is_binary(turn),
       do: notification(method, params, state)

  # An item of a turn that is not the running one, such as the late
  # `item/completed` of a command that `turn/interrupt` left running.
  defp turn_notification("item/" <> _, %{"turnId" => turn}, state) when is_binary(turn),
    do: {[], %{state | done?: true, terminal: {:error, :item_of_ended_turn}}}

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
    do: %{state | done?: true, terminal: {:error, :turn_not_asked}}

  # A pending interrupt goes out when the turn id is known and no
  # `turn/interrupt` answer is due.
  defp send_interrupt(%State{interrupt: {:pending, from}, turn: turn} = state)
       when turn != nil do
    if due?(state, "turn/interrupt") do
      state
    else
      request(%{state | interrupt: {:sent, from}}, "turn/interrupt", %{
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

  # The first turn of a fresh thread: its id and cut, then the replay, if
  # any. The turn's `turn/start` waits for the replay's answer.
  defp replay(history, state) do
    {items, cut} = replay_items(history)
    state = push(state, [{:harness_session, state.thread, cut}])

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

      request(%{state | prompt: nil}, "turn/start", %{threadId: state.thread, input: input})
    end
  end

  defp start_turn(state), do: state

  defp request(state, method, params) do
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
        call_id: call_id(message.tool_call_id),
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
      call_id: call_id(call.id),
      name: tool_name(call.name),
      arguments: JSON.encode!(call.arguments)
    }
  end

  defp block_item(_role, _block), do: nil

  # Each item is encoded once, so the cap counts its bytes.
  defp item(map), do: JSON.encode!(map)

  # The model API takes a call id of at most 64 characters; a longer id,
  # or one with a character outside `[a-zA-Z0-9_-]`, becomes a digest, the
  # same for a call and its result.
  defp call_id(id) do
    if id =~ ~r/\A[a-zA-Z0-9_-]{1,64}\z/,
      do: id,
      else: "h_" <> binary_part(Base.encode16(:crypto.hash(:sha256, id), case: :lower), 0, 62)
  end

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
