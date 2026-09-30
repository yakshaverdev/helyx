defmodule Helyx.Provider.ClaudeCode do
  # The TERM grace of the watchdog and the release: claude ends its own
  # commands on TERM, but a KILL leaves them running (research note).
  @term_grace_ms 5_000
  # The wait for the start of an unresolved steer after a `result` that
  # could not end the turn (`docs/features/long-lived-harness.md`,
  # "Bounds"). Observed: 0 to 10 ms.
  @steer_wait_ms 5_000

  alias Helyx.HarnessIO

  @moduledoc """
  A connected harness provider (ADR 0007) that drives the unmodified
  Claude Code program, `claude`, with stream-json input and output. The
  model ref is `claude-code/<model>`, where `<model>` is what `claude
  --model` takes: an alias such as `haiku`, `sonnet`, or `opus`, or a full
  model name.

  One `claude` serves the whole session: `harness_init/3` starts it from
  `PATH` in the session's working directory, with no `-p` and with open
  input, in its own process group under the watchdog of `Helyx.Watchdog`.
  The harness process holds its groups with `Helyx.Tool.hold/1`, and the
  hands release them through `release/3` (ADR 0004). The watchdog, when
  the port closes, and every release TERM the program's group and wait up
  to #{@term_grace_ms} ms for it to go before the KILL. The program runs
  with `--permission-mode bypassPermissions`, the same trust as the bash
  tool, and uses its own tools. The Helyx tools are an SDK MCP server
  named `helyx` next to them: the program sends its MCP messages in
  `mcp_message` control requests, and the model sees each tool as
  `mcp__helyx__<name>`. A `tools/call` whose `_meta["claudecode/toolUseId"]`
  names the `tool_use` block gives `{:tool_request, id, name, arguments}`;
  a call with no such id, or with no Helyx turn, gets an error result at
  once and runs nothing. The call and its result reach the transcript
  from the program's own lines. An approval request of the program is
  allowed at once, and any other control request gets an error answer at
  once. Its stderr is dropped: the `result` line carries the errors.

  A turn is one user line with a `uuid`. The turn ends at a `result` line
  with `queued_turn_count` 0. A positive count keeps it open, and any other
  value stops the program with an error. The lines and the `result` of a
  turn count only after the start of its line (`command_lifecycle`
  `started`): the provider drops the lines before it, such as those of a
  replay or of a turn that the program starts by itself, and a Helyx tool
  call there gets an error. This needs `msg_lifecycle_v1` in
  `init.capabilities`: without it, the provider stops the program with an
  error at a `result` before the start of the turn's line.

  A program turn is a turn that the program starts by itself, for example
  when a background task ends. An `init` line with no Helyx turn starts
  one: the provider makes a turn id and gives the event `:program_turn`,
  then the turn's events and its terminal as for any turn. A steer and an
  interrupt of it work as for any turn. A `{:turn, ...}` request while a
  program turn runs replaces it: the program runs the new line after the
  program turn, and the rest of the program turn is dropped.

  A steer is one more user line with a `uuid` of its own, written into the
  running turn; while a replay is held, it goes out after the turn's line.
  After the turn's terminal it answers `:rejected` and writes nothing. The
  start of its line (`command_lifecycle` `started`) gives
  `{:user_message, steer_id, text}`. While a steer is unresolved, a
  `result` does not end the turn: `claude` runs a line that it reads after
  a `result` as a turn of its own, and that turn stays in the Helyx turn.
  When the line does not start within #{@steer_wait_ms} ms of such a
  `result`, the harness process stops. A held error `result` goes out as
  `{:notice, text}` at the start of the steer.

  An interrupt is the control request `interrupt` with
  `cancel_queued: true`. It waits for the first `init` line of the
  program, and after a replay for the start of the turn's line. Without
  `interrupt_cancel_queued_v1` in `init.capabilities` it answers an
  error. It answers `:ok` after the control response, with an empty
  `still_queued`, and the `result` of the turn. It also answers `:ok`
  after a response that cancelled the turn's line. When the turn's
  `result` comes before Helyx writes the interrupt, the interrupt answers
  `:ok`, and Helyx writes no interrupt. Anything else answers an error,
  and the harness process ends, so the watchdog stops the program with no
  end of input.

  A close is the end of input, then the exit. An exit at any other time
  stops the harness process. An idle close is a close when the program has
  no background task and no program turn, and answers `:busy` otherwise.
  After a `task_notification` line, the next idle close also answers
  `:busy`, once, because a program turn can follow it; an `init` ends that
  wait. The program sends the
  full set of its live background tasks in a `system` line
  `background_tasks_changed` at each change; only a `tasks` list that is
  exactly empty counts as none, and a malformed line counts as a task until
  the next good one.

  With the `:harness_session_id` option the program resumes that harness
  session, and each turn sends only the new prompt: the user messages at
  the end of the transcript. Without it, or when the program no longer has
  that session, the program starts a fresh harness session with an id of
  its own (`--session-id`), and its first turn first sends the rest of the
  transcript as lines that start no model call. The replay keeps the
  newest messages within #{HarnessIO.replay_max_bytes()} bytes of lines,
  and it never starts at a tool result, so no result loses its call. The
  program writes an assistant line to its session when it reads it, but a
  user line when it takes it from its queue. So each line after a replayed
  user line waits for that line's `result`, and the model gets the
  transcript in its order (research note, "The order of a replay"). The
  `{:harness_session, id, cut}` event of that turn gives the id and the
  number of messages left out.

  Assistant text and thinking stream as deltas. Tool calls and their
  results arrive whole, and a `message_end` closes each assistant message
  whose tool calls the program ran. A stdout line over
  #{HarnessIO.line_max_bytes()} bytes stops the harness process. The
  protocol facts are in `docs/research/claude-code-stream-json.md`.
  """

  @behaviour Helyx.Provider

  alias Helyx.Message

  # The program started the turn's line (`command_lifecycle` `started`).
  defguardp started?(turn) when turn.messages == nil

  defmodule Turn do
    @moduledoc false
    # The running turn. `uuid` is the `uuid` of its user line. `messages`
    # is its transcript until the program started the line, and nil after:
    # a lost session sends it again to a fresh one. Only after the start do
    # the turn's lines and its `result` count (`started?/1`). `replay?` is
    # true from the write of a replay before its line until the program
    # started the line.
    # `interrupt` is nil, or the pending `Interrupt`. `steers` holds each
    # written steer line that the program did not start yet, by its `uuid`:
    # `{steer_id, text}`. `wait` is set from a `result` that could not end
    # the turn, because a steer was unresolved, until the start of a steer:
    # the ref of the timer of that wait. `held` is the text of the error
    # `result` that the wait holds, or nil: the start of a steer sends it
    # as a notice. `used` holds every Helyx call id of the turn's
    # `tools/call` requests, answered or not. `chunks` holds the replay
    # chunks not written yet: each goes out at the `result` of the
    # replayed user line that ends the chunk before it, and the last one
    # ends with the turn's line, then any steers. `program?` marks a
    # program turn (#240): its `id` and `uuid` are one new UUID.
    @enforce_keys [:id, :uuid, :messages]
    defstruct [
      :id,
      :uuid,
      :messages,
      :interrupt,
      :wait,
      :held,
      steers: %{},
      chunks: [],
      replay?: false,
      open?: false,
      calls?: false,
      program?: false,
      usage: %{},
      used: MapSet.new()
    ]
  end

  defmodule Interrupt do
    @moduledoc false
    # A pending interrupt: its `from`, its `request_id` once written, and
    # whether its control response and the turn's `result` came.
    @enforce_keys [:from]
    defstruct [:from, :request_id, response?: false, result?: false]
  end

  defmodule State do
    @moduledoc false
    # The program. `resume` is the harness session it resumed, or nil for
    # a fresh one with the id `session_id`. `sent?` is true once a turn was
    # written to it. `caps` is its `init.capabilities`, nil until an `init`
    # line. `closing` is the `from` of a close. `terminal` stops the read
    # of stdout: `:lost`, a program that did not start
    # (`Helyx.HarnessIO.start/5`), or a line over the cap
    # (`Helyx.HarnessIO.lines/3`). `tasks` is the last set of live
    # background tasks, or `:unknown` after a malformed line.
    # `notified?` is true from a `task_notification` line until the next
    # `init` or `:busy` answer: a program turn can follow it (#240).
    # `tools` are the Helyx tool specs, and `calls` the open `tools/call`
    # requests by call id: `{turn_id, control request_id, JSON-RPC id}`.
    @enforce_keys [:exe, :model, :cwd]
    defstruct [
      :exe,
      :model,
      :cwd,
      :resume,
      :session_id,
      :port,
      :turn,
      :caps,
      :closing,
      :terminal,
      buffer: [],
      tools: [],
      calls: %{},
      tasks: [],
      size: 0,
      init?: false,
      sent?: false,
      notified?: false
    ]
  end

  @lost "No conversation found with session ID"

  # The SDK MCP server of the Helyx tools (research note, "The SDK MCP
  # server shapes"). The user's own MCP servers stay: the Helyx tools add
  # to the harness tools.
  @mcp_config ~s({"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}})

  @impl true
  def id, do: "claude-code"

  @impl true
  def turn, do: :external

  # A delivery TERMs first too: the harness process ends normally after a
  # stop (an error answer, a line over the cap) while claude still runs a
  # command, and a KILL would leave the command running.
  @impl true
  def release(handles, :deliver, deadline), do: release(handles, :cancel, deadline)

  def release(handles, mode, deadline),
    do: HarnessIO.release(handles, mode, deadline, grace_ms: @term_grace_ms)

  # The session calls `stream/3` only for a provider that is not
  # connected.
  @impl true
  def stream(_model, _context, _opts), do: {:error, :connected}

  @impl true
  def harness_init(model, tools, opts) do
    with {:ok, exe} <- HarnessIO.find("claude") do
      state = %State{
        exe: exe,
        model: model,
        tools: tools,
        cwd: Keyword.fetch!(opts, :cwd),
        resume: opts[:harness_session_id]
      }

      # A program that did not start can still have its port open: the
      # keeper of `Helyx.HarnessIO.keep_port/1` closes it when the harness
      # process ends.
      case launch(state) do
        %State{terminal: nil} = state -> {:ok, state}
        %State{terminal: {:error, reason}} -> {:error, reason}
      end
    end
  end

  # A program turn that the session did not open gives way: the program
  # queues the turn's line after it, and drops its lines as before a start.
  @impl true
  def harness_request(
        {:turn, id, %Helyx.Context{messages: messages}},
        from,
        %State{turn: turn} = state
      )
      when turn == nil or turn.program? do
    turn = %Turn{id: id, uuid: uuid(), messages: messages}
    {events, state} = write_turn(%{state | turn: turn})
    {:ok, [{:reply, from, :ok} | events], state}
  end

  # A steer is a user line with a `uuid` of its own. `claude` never
  # refuses a user line, so the answer is `:ok` at the write, and the steer
  # is unresolved until the start of its line.
  def harness_request(
        {:steer, id, steer_id, text},
        from,
        %State{turn: %Turn{id: id} = turn} = state
      ) do
    uuid = uuid()
    steer = user_line(uuid, user_content(Message.user(text)))

    # A steer during a held replay goes out after the turn's line.
    chunks =
      case turn.chunks do
        [] ->
          HarnessIO.write(state, steer)
          []

        chunks ->
          List.update_at(chunks, -1, &[&1, steer])
      end

    turn = %{turn | chunks: chunks, steers: Map.put(turn.steers, uuid, {steer_id, text})}
    {:ok, [{:reply, from, :ok}], %{state | turn: turn}}
  end

  # The terminal of the turn went out first: nothing reached the program.
  def harness_request({:steer, _id, _steer_id, _text}, from, state),
    do: {:ok, [{:reply, from, :rejected}], state}

  # A `result` that the turn holds for an unresolved steer counts as the
  # turn's `result` for the interrupt, until a steer starts.
  def harness_request({:interrupt, id}, from, %State{turn: %Turn{id: id} = turn} = state) do
    interrupt = %Interrupt{from: from, result?: turn.wait != nil}
    {actions, state} = interrupt(%{state | turn: %{turn | interrupt: interrupt}})
    {:ok, actions, state}
  end

  # The turn already ended.
  def harness_request({:interrupt, _id}, from, state), do: {:ok, [{:reply, from, :ok}], state}

  # The result of a Helyx tool call. A call that the program withdrew has
  # no open request, and its result is not written.
  def harness_request({:tool_result, _id, call_id, {status, text}}, from, state) do
    case Map.pop(state.calls, call_id) do
      {{_turn_id, request_id, rpc_id}, calls} ->
        tool_answer(state, request_id, rpc_id, status, text)
        {:ok, [{:reply, from, :ok}], %{state | calls: calls}}

      {nil, _calls} ->
        {:ok, [{:reply, from, :ok}], state}
    end
  end

  def harness_request(:idle_close, from, %State{tasks: [], notified?: false, turn: nil} = state),
    do: harness_request(:close, from, state)

  # A program turn starts 100 to 150 ms after the `task_notification`, with
  # `tasks` already empty (research note): one `:busy` waits for it. A
  # program turn that runs, which the session did not open, also keeps the
  # program: the session is idle, so no Helyx turn is open here.
  def harness_request(:idle_close, from, state),
    do: {:ok, [{:reply, from, :busy}], %{state | notified?: false}}

  def harness_request(:close, from, state) do
    HarnessIO.write(state, <<0>>)
    {:ok, [], %{state | closing: from}}
  end

  @impl true
  def harness_info({port, {:data, data}}, %State{port: port} = state) do
    {actions, state} = HarnessIO.lines(data, state, &translate/2)

    case state.terminal do
      nil -> {:ok, actions, state}
      # A close waits for the lost program's exit, which answers it.
      :lost when state.closing != nil -> {:ok, actions, state}
      :lost -> relaunch(actions, state)
      {:error, reason} -> {:stop, reason, state}
    end
  end

  # A write to a watchdog that died closes the port with `:epipe` and no
  # exit status (#167), so the port's `:DOWN` is an exit too.
  def harness_info({port, {:exit_status, status}}, %State{port: port} = state),
    do: exited(status, state)

  def harness_info({:DOWN, _ref, :port, port, reason}, %State{port: port} = state),
    do: exited(reason, state)

  # Helyx does not know whether the program will start the steer, so the
  # program stops.
  def harness_info({:timeout, ref, :steer_wait}, %State{turn: %Turn{wait: ref}} = state),
    do: {:stop, :steer_not_started, state}

  # A message of a closed port, such as the port of a lost session.
  def harness_info(_message, state), do: {:ok, [], state}

  defp exited(_status, %State{closing: from} = state) when from != nil,
    do: {:ok, [{:reply, from, :ok}], %{state | port: nil}}

  defp exited(status, state), do: {:stop, {:claude_code_exit, status}, state}

  # `--model=`, `--resume=`, and `--session-id=` keep a value that starts
  # with a dash a value.
  defp launch(state) do
    id = state.resume || uuid()
    session = if state.resume, do: "--resume=" <> id, else: "--session-id=" <> id

    flags =
      ~w(--output-format stream-json --verbose --include-partial-messages
         --input-format stream-json --permission-mode bypassPermissions) ++
        ["--model=" <> state.model, session, "--mcp-config", @mcp_config]

    argv = ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), state.exe | flags]

    argv
    |> HarnessIO.start(state.cwd, :open, %{state | session_id: id}, grace_ms: @term_grace_ms)
    |> HarnessIO.keep_port()
  end

  # The program of a lost session exits by itself, with nothing run
  # (research note). A fresh program takes its place, and a turn that was
  # written to the lost one goes to the fresh one, with the replay.
  # The lost program ran no steer line either: the steers are dropped, not
  # written again, and the session gives each a notice.
  defp relaunch(actions, state) do
    HarnessIO.stop(state)
    turn = state.turn && %{state.turn | steers: %{}}

    fresh = %State{
      exe: state.exe,
      model: state.model,
      cwd: state.cwd,
      tools: state.tools,
      turn: turn
    }

    case launch(fresh) do
      %State{terminal: {:error, reason}} = state ->
        {:stop, reason, state}

      %State{turn: nil} = state ->
        {:ok, actions, state}

      state ->
        {events, state} = write_turn(state)
        {:ok, actions ++ events, state}
    end
  end

  # The prompt is the user messages at the end of the transcript. A resumed
  # harness session, or one that took a turn, has the rest; a fresh one
  # gets the rest first.
  defp write_turn(%State{turn: turn} = state) do
    {prompt, history} = HarnessIO.split_prompt(turn.messages)
    content = Enum.flat_map(prompt, &user_content/1)

    prompt_line = user_line(turn.uuid, content)

    if state.resume || state.sent? do
      HarnessIO.write(state, prompt_line)
      {[], %{state | sent?: true}}
    else
      {[first | chunks], cut, replay?} = replay(history, prompt_line)
      HarnessIO.write(state, first)
      event = {:event, turn.id, {:harness_session, state.session_id, cut}}
      turn = %{turn | replay?: replay?, chunks: chunks}
      {[event], %{state | sent?: true, turn: turn}}
    end
  end

  # Interrupt

  # A fresh program lists its capabilities only in the `init` line of its
  # first query, after the start of the turn's line: the interrupt waits
  # for it, within the interrupt bound. The line was written before the
  # interrupt, so the program has it, queued or started, when it reads the
  # interrupt.
  #
  # The replay lines are queued queries too. `cancel_queued` could drop
  # some of them (inferred), and the program would then keep a harness
  # session with part of the history. So after a replay the interrupt also
  # waits for the start of the turn's line, which comes after the replay
  # results (research note for one replay line; inferred for more).
  defp interrupt(%State{caps: nil} = state), do: {[], state}
  defp interrupt(%State{turn: %Turn{replay?: true}} = state), do: {[], state}

  defp interrupt(%State{turn: %Turn{interrupt: interrupt} = turn} = state) do
    if "interrupt_cancel_queued_v1" in state.caps do
      id = "interrupt_" <> turn.uuid
      request = %{subtype: "interrupt", cancel_queued: true}
      HarnessIO.write(state, line(%{type: "control_request", request_id: id, request: request}))
      {[], %{state | turn: %{turn | interrupt: %{interrupt | request_id: id}}}}
    else
      answer_interrupt(state, {:error, :no_cancel_queued})
    end
  end

  # The interrupt is done when both its control response and the turn's
  # `result` came, in either order: a turn that ended just before the
  # interrupt gives its `result` first. A response that cancelled the
  # turn's line is the end of the turn: no `result` comes for a cancelled
  # line (research note).
  defp interrupt_progress(%State{turn: %Turn{interrupt: interrupt} = turn} = state, key) do
    state = %{state | turn: %{turn | interrupt: struct!(interrupt, [{key, true}])}}

    # A turn that ended before Helyx wrote the interrupt gets no interrupt.
    case state.turn.interrupt do
      %Interrupt{request_id: nil, result?: true} -> answer_interrupt(state, :ok)
      %Interrupt{response?: true, result?: true} -> answer_interrupt(state, :ok)
      _ -> {[], state}
    end
  end

  defp cancelled?(%{"cancelled" => cancelled}, uuid) when is_list(cancelled),
    do: uuid in cancelled

  defp cancelled?(_response, _uuid), do: false

  # A pending interrupt that waited for the `init` line or the start.
  defp resume_interrupt(%State{turn: %Turn{interrupt: %Interrupt{request_id: nil}}} = state),
    do: interrupt(state)

  defp resume_interrupt(state), do: {[], state}

  defp answer_interrupt(%State{turn: turn} = state, answer),
    do: {[{:reply, turn.interrupt.from, answer}], %{state | turn: nil}}

  # Output

  # The set of live background tasks, sent whole at each change, also
  # between turns (research note). Only a list confirms a set.
  defp translate(%{"type" => "system", "subtype" => "background_tasks_changed"} = line, state) do
    tasks = if is_list(line["tasks"]), do: line["tasks"], else: :unknown
    {[], %{state | tasks: tasks}}
  end

  defp translate(%{"type" => "system", "subtype" => "task_notification"}, state),
    do: {[], %{state | notified?: true}}

  # A sub-agent's own messages stay inside the harness.
  defp translate(%{"parent_tool_use_id" => parent}, state) when parent != nil, do: {[], state}

  # Each query of the program repeats the init line. An `init` with no
  # Helyx turn starts a program turn (#240): every user line that Helyx
  # writes belongs to a turn until its start, so the program started this
  # query by itself. A program turn has no `command_lifecycle`, so it counts
  # at once, and its `result` ends it as a turn's does.
  defp translate(%{"type" => "system", "subtype" => "init"} = init, state) do
    caps = if is_list(init["capabilities"]), do: init["capabilities"], else: []
    state = %{state | init?: true, caps: caps, notified?: false}

    case state.turn do
      nil ->
        id = uuid()
        turn = %Turn{id: id, uuid: id, messages: nil, program?: true}
        {[{:event, id, :program_turn}], %{state | turn: turn}}

      _turn ->
        resume_interrupt(state)
    end
  end

  defp translate(
         %{"type" => "command_lifecycle", "state" => "started", "command_uuid" => uuid},
         %State{turn: %Turn{uuid: uuid} = turn} = state
       ),
       do: resume_interrupt(%{state | turn: %{turn | messages: nil, replay?: false}})

  # The program took a steer: in the running model call after a tool
  # result, or as a program turn of its own after a `result`. That turn
  # stays in the Helyx turn, so a pending interrupt now waits for its
  # `result`.
  defp translate(
         %{"type" => "command_lifecycle", "state" => "started", "command_uuid" => uuid},
         %State{turn: %Turn{steers: steers} = turn} = state
       )
       when is_map_key(steers, uuid) do
    {{steer_id, text}, steers} = Map.pop!(steers, uuid)
    if turn.wait, do: :erlang.cancel_timer(turn.wait)
    events = close_message(turn) ++ held_notice(turn.held) ++ [{:user_message, steer_id, text}]
    interrupt = turn.interrupt && %{turn.interrupt | result?: false}

    turn = %{
      turn
      | steers: steers,
        open?: false,
        calls?: false,
        wait: nil,
        held: nil,
        interrupt: interrupt
    }

    {emit(state, events), %{state | turn: turn}}
  end

  defp translate(
         %{"type" => "control_response", "response" => %{"request_id" => id} = response},
         %State{turn: %Turn{uuid: uuid, interrupt: %Interrupt{request_id: id}}} = state
       )
       when is_binary(id) do
    # Only `still_queued` exactly `[]` confirms that no queued work
    # remains; a missing or other value answers an error (ADR 0007).
    case response do
      %{"subtype" => "success", "response" => %{"still_queued" => []} = body} ->
        if cancelled?(body, uuid),
          do: answer_interrupt(state, :ok),
          else: interrupt_progress(state, :response?)

      %{"subtype" => "success"} ->
        answer_interrupt(state, {:error, :still_queued})

      _error ->
        answer_interrupt(state, {:error, {:interrupt, HarnessIO.cap_error(response["error"])}})
    end
  end

  # The Helyx MCP server (research note, "The SDK MCP server shapes").
  defp translate(
         %{
           "type" => "control_request",
           "request_id" => request_id,
           "request" => %{
             "subtype" => "mcp_message",
             "server_name" => "helyx",
             "message" => %{} = message
           }
         },
         state
       )
       when is_binary(request_id),
       do: mcp(message, request_id, state)

  # The program withdrew a control request; it waits for no answer
  # (source only).
  defp translate(%{"type" => "control_cancel_request", "request_id" => request_id}, state) do
    cancel_call(state, fn {_turn_id, id, _rpc_id} -> id == request_id end)
  end

  # An approval is allowed with its input unchanged, because the program
  # runs with `bypassPermissions`. With no `--permission-prompt-tool`, no
  # approval comes (research note). Every other request gets an error.
  defp translate(%{"type" => "control_request", "request_id" => id} = request, state)
       when is_binary(id) do
    response =
      case request["request"] do
        %{"subtype" => "can_use_tool", "input" => %{} = input} ->
          %{
            subtype: "success",
            request_id: id,
            response: %{behavior: "allow", updatedInput: input}
          }

        _ ->
          %{subtype: "error", request_id: id, error: "not supported by Helyx"}
      end

    HarnessIO.write(state, line(%{type: "control_response", response: response}))
    {[], state}
  end

  # A result before `started` of the turn's line is not the turn's: the
  # result of a replayed line, of a program turn that the program started
  # by itself, or of the turn's own line (#246). The skip needs the program
  # to list `msg_lifecycle_v1` in an earlier `init` line; without it the
  # provider stops the program, because `started` can fail to come. The
  # result of a lost session comes before any `init` and before `started`.
  # A skipped result can also write the next held replay chunk.
  defp translate(%{"type" => "result"} = result, state) do
    cond do
      lost?(result, state) ->
        {[], %{state | terminal: :lost}}

      state.turn == nil ->
        {[], state}

      started?(state.turn) ->
        turn_result(result, state)

      "msg_lifecycle_v1" in (state.caps || []) ->
        release(result, state)

      true ->
        {[], %{state | terminal: {:error, :no_msg_lifecycle}}}
    end
  end

  # The model lines before `started` of the turn's line belong to no Helyx
  # turn, as between turns: a program turn has no `command_lifecycle`.
  defp translate(_object, %State{turn: nil} = state), do: {[], state}
  defp translate(_object, %State{turn: turn} = state) when not started?(turn), do: {[], state}

  defp translate(
         %{
           "type" => "stream_event",
           "event" => %{"type" => "content_block_delta", "delta" => delta}
         },
         %State{turn: turn} = state
       ) do
    case delta do
      %{"type" => "text_delta", "text" => text} when is_binary(text) and text != "" ->
        {emit(state, [{:text_delta, text}]), %{state | turn: %{turn | open?: true}}}

      %{"type" => "thinking_delta", "thinking" => text} when is_binary(text) and text != "" ->
        {emit(state, [{:thinking_delta, text}]), %{state | turn: %{turn | open?: true}}}

      _ ->
        {[], state}
    end
  end

  # The text of an assistant line already came as deltas; only its tool
  # calls and its usage are new.
  defp translate(
         %{"type" => "assistant", "message" => %{"content" => blocks} = message},
         %State{turn: turn} = state
       )
       when is_list(blocks) do
    calls =
      for %{"type" => "tool_use", "id" => id, "name" => name, "input" => %{} = input} <- blocks,
          do: {:tool_call, %Message.ToolCall{id: id, name: name, arguments: input}}

    usage = if is_map(message["usage"]), do: message["usage"], else: turn.usage
    some? = calls != []
    turn = %{turn | open?: turn.open? or some?, calls?: turn.calls? or some?, usage: usage}
    {emit(state, calls), %{state | turn: turn}}
  end

  defp translate(
         %{"type" => "user", "message" => %{"content" => blocks}},
         %State{turn: turn} = state
       )
       when is_list(blocks) do
    results =
      for %{"type" => "tool_result", "tool_use_id" => id} = block <- blocks do
        status = if block["is_error"] == true, do: :error, else: :ok
        {:tool_result, id, {status, Helyx.Text.truncate(result_text(block["content"]), :tail)}}
      end

    case results do
      [] ->
        {[], state}

      _ ->
        {emit(state, close_message(turn) ++ results),
         %{state | turn: %{turn | open?: false, calls?: false}}}
    end
  end

  defp translate(_object, state), do: {[], state}

  # A result before `started` while replay chunks are held answers the
  # replayed user line that ends the last written chunk, so the next chunk
  # goes out. Only a result with `num_turns` exactly 0 and no or a null
  # `origin` can be one: a replayed line makes no model call, and the result of a
  # program turn has `origin` and a model call (research note, "Program
  # turns").
  defp release(%{"origin" => origin}, state) when origin != nil, do: {[], state}

  defp release(%{"num_turns" => 0}, %State{turn: %Turn{chunks: [next | chunks]} = turn} = state) do
    HarnessIO.write(state, next)
    {[], %{state | turn: %{turn | chunks: chunks}}}
  end

  defp release(_result, state), do: {[], state}

  defp emit(%State{turn: turn}, events), do: for(event <- events, do: {:event, turn.id, event})

  # MCP

  # A request has an `id`; a notification has none and gets the ack of the
  # SDK, which the program waits for (research note). `initialize` can come
  # again on one program, so it keeps no state.
  defp mcp(%{"method" => "initialize", "id" => id} = message, request_id, state) do
    version =
      case message["params"] do
        %{"protocolVersion" => version} when is_binary(version) -> version
        _other -> "2025-11-25"
      end

    result = %{
      protocolVersion: version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "helyx", version: "0.1.0"}
    }

    mcp_answer(state, request_id, %{id: id, result: result})
  end

  defp mcp(%{"method" => "tools/list", "id" => id}, request_id, state) do
    tools =
      for tool <- state.tools,
          do: %{name: tool.name, description: tool.description, inputSchema: tool.parameters}

    mcp_answer(state, request_id, %{id: id, result: %{tools: tools}})
  end

  # A call id of the turn is recorded in `used` before any check that
  # answers it, so an id that got any answer never runs later in the turn:
  # the provider's own errors do not reach the loop, which records the rest.
  defp mcp(%{"method" => "tools/call", "id" => id} = message, request_id, state) do
    params = message["params"]

    case {state.turn, tool_use_id(params)} do
      # A program turn can run before `started` of the turn's line.
      {turn, _call_id} when turn == nil or not started?(turn) ->
        tool_answer(state, request_id, id, :error, "no Helyx turn is running")

      {_turn, nil} ->
        tool_answer(state, request_id, id, :error, "the call does not map to a tool use")

      {%Turn{id: turn_id, used: used}, call_id} ->
        state = put_in(state.turn.used, MapSet.put(used, call_id))

        with false <- MapSet.member?(used, call_id),
             %{"name" => name} when is_binary(name) <- params,
             args when is_map(args) <- Map.get(params, "arguments", %{}) do
          calls = Map.put(state.calls, call_id, {turn_id, request_id, id})
          {[{:event, turn_id, {:tool_request, call_id, name, args}}], %{state | calls: calls}}
        else
          true ->
            tool_answer(state, request_id, id, :error, "the call id was used before in this turn")

          _unmapped ->
            tool_answer(state, request_id, id, :error, "the call does not map to a tool use")
        end
    end
  end

  defp mcp(
         %{"method" => "notifications/cancelled", "params" => %{"requestId" => rpc_id}},
         request_id,
         state
       ) do
    mcp_answer(state, request_id, %{result: %{}})
    cancel_call(state, fn {_turn_id, _request_id, id} -> id == rpc_id end)
  end

  defp mcp(%{"id" => id}, request_id, state) do
    error = %{code: -32_601, message: "method not found"}
    mcp_answer(state, request_id, %{id: id, error: error})
  end

  defp mcp(_notification, request_id, state),
    do: mcp_answer(state, request_id, %{result: %{}})

  defp tool_use_id(%{"_meta" => %{"claudecode/toolUseId" => call_id}}) when is_binary(call_id),
    do: call_id

  defp tool_use_id(_params), do: nil

  defp tool_answer(state, request_id, rpc_id, status, text) do
    result = %{content: [%{type: "text", text: text}], isError: status == :error}
    mcp_answer(state, request_id, %{id: rpc_id, result: result})
  end

  # Withdraws the open call that `match?` finds by its `{turn_id,
  # request_id, rpc_id}`, if any.
  defp cancel_call(state, match?) do
    case Enum.find(state.calls, fn {_call_id, call} -> match?.(call) end) do
      nil ->
        {[], state}

      {call_id, {turn_id, _request_id, _rpc_id}} ->
        {[{:cancel_tool, turn_id, call_id}], %{state | calls: Map.delete(state.calls, call_id)}}
    end
  end

  defp mcp_answer(state, request_id, message) do
    message = Map.put(message, :jsonrpc, "2.0")
    response = %{subtype: "success", request_id: request_id, response: %{mcp_response: message}}
    HarnessIO.write(state, line(%{type: "control_response", response: response}))
    {[], state}
  end

  # Only `queued_turn_count` exactly 0 ends the turn: a positive count keeps
  # it open, and any other value stops the program, because it does not
  # confirm that no queued work remains (ADR 0007). The count comes before
  # the interrupt, so a pending interrupt never answers `:ok` on it.
  defp turn_result(%{"queued_turn_count" => n}, state) when is_integer(n) and n > 0,
    do: {[], state}

  defp turn_result(
         %{"queued_turn_count" => 0},
         %State{turn: %Turn{interrupt: %Interrupt{}}} = state
       ),
       do: interrupt_progress(state, :result?)

  # An unresolved steer keeps the turn: `claude` reads a line that came
  # before this `result` after it and runs it as a turn of its own
  # (research note). The turn waits #{@steer_wait_ms} ms for its start,
  # then for the next `result`.
  defp turn_result(
         %{"queued_turn_count" => 0} = result,
         %State{turn: %Turn{steers: steers} = turn} = state
       )
       when map_size(steers) > 0 do
    wait = turn.wait || :erlang.start_timer(@steer_wait_ms, self(), :steer_wait)
    {[], %{state | turn: %{turn | wait: wait, held: held(result, turn)}}}
  end

  # The session closes the open assistant message at the terminal.
  defp turn_result(%{"queued_turn_count" => 0} = result, state),
    do: {emit(state, [terminal(result, state.turn)]), %{state | turn: nil}}

  defp turn_result(_result, state),
    do: {[], %{state | terminal: {:error, :no_queued_turn_count}}}

  # Only the first line of a resumed program can say that the session is
  # lost; it comes before any `init`.
  defp lost?(result, state) do
    state.resume != nil and not state.init? and
      Enum.any?(errors(result), &String.starts_with?(&1, @lost))
  end

  defp errors(%{"errors" => errors}) when is_list(errors), do: Enum.filter(errors, &is_binary/1)
  defp errors(_result), do: []

  defp close_message(%Turn{open?: false}), do: []

  defp close_message(turn),
    do: [{:message_end, if(turn.calls?, do: :tool_use, else: :end_turn), turn.usage}]

  defp terminal(%{"is_error" => false, "subtype" => "success"} = result, turn) do
    stop = if result["stop_reason"] == "max_tokens", do: :max_tokens, else: :end_turn
    {:done, %{stop_reason: stop, usage: turn.usage}}
  end

  defp terminal(result, _turn) do
    text = Enum.join(errors(result), "; ")
    text = if text == "" and is_binary(result["result"]), do: result["result"], else: text
    {:error, {:claude_code, HarnessIO.cap_error(result["subtype"]), HarnessIO.cap_error(text)}}
  end

  # Only a `result` of a Helyx line can be the held error: the `result` of
  # a program turn (research note, "Program turns") keeps `held`.
  defp held(%{"origin" => %{"kind" => "task-notification"}}, turn), do: turn.held

  defp held(result, turn) do
    case terminal(result, turn) do
      {:error, {:claude_code, subtype, text}} -> subtype <> ": " <> text
      {:done, _} -> nil
    end
  end

  defp held_notice(nil), do: []

  defp held_notice(text),
    do: [{:notice, HarnessIO.cap_error("the turn before the steer failed: " <> text)}]

  defp result_text(text) when is_binary(text), do: text

  defp result_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => type} when is_binary(type) -> "[#{type}]"
      _ -> ""
    end)
  end

  defp result_text(_content), do: ""

  # Input

  # One line per assistant message, and one `shouldQuery: false` user line
  # for each run of user messages and tool results between them. An entry
  # is {line or false, messages, start?}: the replay may start at an entry
  # whose line has no tool result, because the call of every kept result is
  # then kept too. The kept lines and `last` go out in chunks, each
  # ending at a user line; the last chunk ends with `last`.
  defp replay(history, last) do
    tagged =
      history
      |> Enum.chunk_by(&(&1.role == :assistant))
      |> Enum.flat_map(fn
        [%Message{role: :assistant} | _] = messages ->
          Enum.map(messages, &{:assistant, assistant_entry(&1)})

        messages ->
          [{:user, user_entry(messages)}]
      end)

    {lines, cut} = HarnessIO.cap_replay(Enum.map(tagged, &elem(&1, 1)), length(history))

    # `cap_replay` keeps a suffix of the lines that are not `false`.
    kinds = for {kind, {line, _n, _start?}} <- tagged, line, do: kind

    chunks =
      kinds
      |> Enum.take(-length(lines))
      |> Enum.zip(lines)
      |> Enum.chunk_while(
        [],
        fn
          {:user, line}, acc -> {:cont, Enum.reverse(acc, [line]), []}
          {:assistant, line}, acc -> {:cont, [line | acc]}
        end,
        &{:cont, Enum.reverse(&1, [last]), []}
      )

    {chunks, cut, lines != []}
  end

  defp assistant_entry(%Message{content: blocks}) do
    content =
      for block <- blocks, json = assistant_block(block), do: json

    {content != [] && line(%{type: "assistant", message: %{role: "assistant", content: content}}),
     1, true}
  end

  # Thinking is not replayed: its signature belongs to the model that made it.
  defp assistant_block(%Message.Text{text: text}) when text != "", do: %{type: "text", text: text}

  defp assistant_block(%Message.ToolCall{} = call),
    do: %{type: "tool_use", id: tool_id(call.id), name: call.name, input: call.arguments}

  defp assistant_block(_block), do: nil

  defp user_entry(messages) do
    content = Enum.flat_map(messages, &user_content/1)
    start? = not Enum.any?(messages, &(&1.role == :tool_result))
    message = %{role: "user", content: content}

    {content != [] && line(%{type: "user", shouldQuery: false, message: message}),
     length(messages), start?}
  end

  defp user_content(%Message{role: :tool_result} = message) do
    [
      %{
        type: "tool_result",
        tool_use_id: tool_id(message.tool_call_id),
        content: Message.text(message),
        is_error: message.is_error
      }
    ]
  end

  defp user_content(%Message{content: blocks}) do
    for %Message.Text{text: text} <- blocks, text != "", do: %{type: "text", text: text}
  end

  # The Messages API takes tool ids of `[a-zA-Z0-9_-]` only; another
  # provider's id can have other characters.
  defp tool_id(id), do: String.replace(id, ~r/[^a-zA-Z0-9_-]/, "_")

  defp line(map), do: [JSON.encode!(map), "\n"]

  defp user_line(uuid, content),
    do: line(%{type: "user", uuid: uuid, message: %{role: "user", content: content}})

  # A random version 4 UUID: `--session-id` takes only a UUID.
  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
