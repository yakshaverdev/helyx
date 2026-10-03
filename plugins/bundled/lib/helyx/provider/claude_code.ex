defmodule Helyx.Provider.ClaudeCode do
  @moduledoc """
  A connected harness provider (ADR 0007) that drives the unmodified
  Claude Code program, `claude`, with stream-json input and output. The
  model ref is `claude-code/<model>`, where `<model>` is what `claude
  --model` takes.

  One `claude` at a time serves the session. A turn is one user
  line with a `uuid`, and it ends at a `result` with `queued_turn_count` 0
  and no unresolved steer. A steer is one more user line, and an interrupt
  is the control request `interrupt` with `cancel_queued: true`. An `init`
  line with no Helyx turn starts a program turn. The Helyx tools are an SDK
  MCP server named `helyx`. A fresh harness session gets the rest of the
  transcript as a replay before the first turn's line.

  The full contract is in `docs/features/long-lived-harness.md`, section
  "Claude Code". The protocol facts are in
  `docs/research/claude-code-stream-json.md`.
  """

  @behaviour Helyx.Provider

  # The wait for the start of an unresolved steer after a `result` that
  # could not end the turn (`docs/features/long-lived-harness.md`,
  # "Bounds"). Observed: 0 to 10 ms.
  @steer_wait_ms 5_000

  alias Helyx.HarnessIO
  alias Helyx.Message
  alias Helyx.Provider.ClaudeCode.{Mcp, Replay, Turn}

  import Turn, only: [started?: 1]

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
    # written to it. `init?` is true from its first `init` line. `closing`
    # is the `from` of a close. `terminal` stops the read of stdout:
    # `:lost`, a program that did not start (`Helyx.HarnessIO.start/5`), an
    # `init` without the needed capabilities, or a line over the cap
    # (`Helyx.HarnessIO.lines/3`). `tasks` is the `tasks` value of the last
    # `background_tasks_changed` line: only `[]` lets an idle close stop
    # the program.
    # `notified?` is true from a `task_notification` line until the next
    # `init` or `:busy` answer: a program turn can follow it (#240).
    # `tools` are the Helyx tool specs, and `calls` the open `tools/call`
    # requests of `Mcp`.
    @enforce_keys [:exe, :model, :cwd]
    defstruct [
      :exe,
      :model,
      :cwd,
      :resume,
      :session_id,
      :port,
      :turn,
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

  # Every observed `init` lists both (research note): the interrupt needs
  # `cancel_queued`, and the turn needs `command_lifecycle` `started`.
  @required_caps ["interrupt_cancel_queued_v1", "msg_lifecycle_v1"]

  @impl true
  def id, do: "claude-code"

  @impl true
  defdelegate release(handles, mode, deadline), to: HarnessIO

  @impl true
  def init(model, tools, opts) do
    with {:ok, exe} <- HarnessIO.find("claude") do
      state = %State{
        exe: exe,
        model: model,
        tools: tools,
        cwd: Keyword.fetch!(opts, :cwd),
        resume: opts[:resume_id]
      }

      # A program that did not start has no port: `Helyx.Watchdog.start/4`
      # closed it.
      case launch(state) do
        %State{terminal: nil} = state -> {:ok, state}
        %State{terminal: {:error, reason}} -> {:error, reason}
      end
    end
  end

  # A program turn that the session did not open gives way: the program
  # queues the turn's line after it, and drops its lines as before a start.
  @impl true
  def request(
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
  def request(
        {:steer, id, steer_id, text},
        from,
        %State{turn: %Turn{id: id} = turn} = state
      ) do
    uuid = uuid()
    steer = Replay.user_line(uuid, Replay.user_content(Message.user(text)))

    # A steer during a held replay goes out after the turn's line.
    chunks =
      case turn.chunks do
        [] ->
          HarnessIO.write(state, steer)
          []

        chunks ->
          List.update_at(chunks, -1, &[&1, steer])
      end

    turn = %{turn | chunks: chunks, steers: Map.put(turn.steers, uuid, steer_id)}
    {:ok, [{:reply, from, :ok}], %{state | turn: turn}}
  end

  # The terminal of the turn went out first: nothing reached the program.
  def request({:steer, _id, _steer_id, _text}, from, state),
    do: {:ok, [{:reply, from, :rejected}], state}

  # A `result` that the turn holds for an unresolved steer counts as the
  # turn's `result` for the interrupt, until a steer starts.
  def request({:interrupt, id}, from, %State{turn: %Turn{id: id} = turn} = state) do
    interrupt = %Interrupt{from: from, result?: turn.wait != nil}
    {actions, state} = interrupt(%{state | turn: %{turn | interrupt: interrupt}})
    {:ok, actions, state}
  end

  # The turn already ended.
  def request({:interrupt, _id}, from, state), do: {:ok, [{:reply, from, :ok}], state}

  def request({:tool_result, _id, call_id, {status, text}}, from, state),
    do: {:ok, [{:reply, from, :ok}], Mcp.result(state, call_id, status, text)}

  def request(:idle_close, from, %State{tasks: [], notified?: false, turn: nil} = state),
    do: request(:close, from, state)

  # A program turn starts 100 to 150 ms after the `task_notification`, with
  # `tasks` already empty (research note): one `:busy` waits for it. A
  # program turn that runs, which the session did not open, also keeps the
  # program: the session is idle, so no Helyx turn is open here.
  def request(:idle_close, from, state),
    do: {:ok, [{:reply, from, :busy}], %{state | notified?: false}}

  def request(:close, from, state), do: {:ok, [], HarnessIO.close(state, from)}

  # Helyx does not know whether the program will start the steer, so the
  # program stops.
  @impl true
  def info({:timeout, ref, :steer_wait}, %State{turn: %Turn{wait: ref}} = state),
    do: {:stop, :steer_not_started, state}

  def info(message, state) do
    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, actions, state} ->
        read(actions, state)

      {:closed, from} ->
        {:ok, [{:reply, from, :ok}], %{state | port: nil}}

      {:exit, status} ->
        {:stop, {:claude_code_exit, status}, state}

      # A message of a closed port, such as the port of a lost session.
      :other ->
        {:ok, [], state}
    end
  end

  defp read(actions, %State{terminal: nil} = state), do: {:ok, actions, state}
  # A close waits for the lost program's exit, which answers it.
  defp read(actions, %State{terminal: :lost, closing: nil} = state), do: relaunch(actions, state)
  defp read(actions, %State{terminal: :lost} = state), do: {:ok, actions, state}
  defp read(_actions, %State{terminal: {:error, reason}} = state), do: {:stop, reason, state}

  # `--model=`, `--resume=`, and `--session-id=` keep a value that starts
  # with a dash a value.
  defp launch(state) do
    id = state.resume || uuid()
    session = if state.resume, do: "--resume=" <> id, else: "--session-id=" <> id

    flags =
      ~w(--output-format stream-json --verbose --include-partial-messages
         --input-format stream-json --permission-mode bypassPermissions) ++
        ["--model=" <> state.model, session, "--mcp-config", Mcp.config()]

    HarnessIO.launch(state.exe, flags, state.cwd, %{state | session_id: id})
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
    content = Enum.flat_map(prompt, &Replay.user_content/1)

    prompt_line = Replay.user_line(turn.uuid, content)

    if state.resume || state.sent? do
      HarnessIO.write(state, prompt_line)
      {[], %{state | sent?: true}}
    else
      {[first | chunks], cut, replay?} = Replay.chunks(history, prompt_line)
      HarnessIO.write(state, first)
      event = {:event, turn.id, {:resume, state.session_id, cut}}
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
  defp interrupt(%State{init?: false} = state), do: {[], state}
  defp interrupt(%State{turn: %Turn{replay?: true}} = state), do: {[], state}

  defp interrupt(%State{turn: %Turn{interrupt: interrupt} = turn} = state) do
    id = "interrupt_" <> turn.uuid
    request = %{subtype: "interrupt", cancel_queued: true}

    HarnessIO.write(
      state,
      Replay.line(%{type: "control_request", request_id: id, request: request})
    )

    {[], %{state | turn: %{turn | interrupt: %{interrupt | request_id: id}}}}
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
  # between turns (research note).
  defp translate(%{"type" => "system", "subtype" => "background_tasks_changed"} = line, state),
    do: {[], %{state | tasks: line["tasks"]}}

  defp translate(%{"type" => "system", "subtype" => "task_notification"}, state),
    do: {[], %{state | notified?: true}}

  # A sub-agent's own messages stay inside the harness.
  defp translate(%{"parent_tool_use_id" => parent}, state) when parent != nil, do: {[], state}

  # Each query of the program repeats the init line. An `init` with no
  # Helyx turn starts a program turn (#240): every user line that Helyx
  # writes belongs to a turn until its start, so the program started this
  # query by itself. A program turn has no `command_lifecycle`, so it counts
  # at once, and its `result` ends it as a turn's does. An `init` without
  # `@required_caps` stops the provider process.
  defp translate(%{"type" => "system", "subtype" => "init"} = init, state) do
    caps = if is_list(init["capabilities"]), do: init["capabilities"], else: []
    missing = @required_caps -- caps
    state = %{state | init?: true, notified?: false}

    cond do
      missing != [] ->
        {[], %{state | terminal: {:error, {:missing_capabilities, missing}}}}

      state.turn == nil ->
        id = uuid()
        turn = %Turn{id: id, uuid: id, messages: nil, program?: true}
        {[{:event, id, :turn_start}], %{state | turn: turn}}

      true ->
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
       when is_map_key(steers, uuid),
       do: emit(state, Turn.steer_start(turn, uuid))

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
       do: Mcp.message(message, request_id, state)

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

    HarnessIO.write(state, Replay.line(%{type: "control_response", response: response}))
    {[], state}
  end

  # A result before `started` of the turn's line is not the turn's: the
  # result of a replayed line, of a program turn that the program started
  # by itself, or of the turn's own line (#246). The result of a lost
  # session comes before any `init` and before `started`. A skipped result
  # can also write the next held replay chunk.
  defp translate(%{"type" => "result"} = result, state) do
    cond do
      lost?(result, state) -> {[], %{state | terminal: :lost}}
      state.turn == nil -> {[], state}
      started?(state.turn) -> turn_result(result, state)
      true -> release(result, state)
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
       ),
       do: emit(state, {Turn.delta(delta), turn})

  defp translate(
         %{"type" => "assistant", "message" => %{"content" => blocks} = message},
         %State{turn: turn} = state
       )
       when is_list(blocks),
       do: emit(state, Turn.assistant(turn, message))

  defp translate(
         %{"type" => "user", "message" => %{"content" => blocks}},
         %State{turn: turn} = state
       )
       when is_list(blocks),
       do: emit(state, {Turn.results(blocks), turn})

  defp translate(_object, state), do: {[], state}

  # A result before `started` while replay chunks are held answers the
  # replayed user line that ends the last written chunk, so the next chunk
  # goes out. Only a result with `num_turns` exactly 0 can be one: a
  # replayed line makes no model call, and a program turn makes one
  # (research note, "Program turns").
  defp release(%{"num_turns" => 0}, %State{turn: %Turn{chunks: [next | chunks]} = turn} = state) do
    HarnessIO.write(state, next)
    {[], %{state | turn: %{turn | chunks: chunks}}}
  end

  defp release(_result, state), do: {[], state}

  # The turn's events with its id, and the state with the new turn.
  defp emit(state, {events, turn}),
    do: {for(event <- events, do: {:event, turn.id, event}), %{state | turn: turn}}

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
         %{"queued_turn_count" => 0},
         %State{turn: %Turn{steers: steers} = turn} = state
       )
       when map_size(steers) > 0 do
    wait = turn.wait || :erlang.start_timer(@steer_wait_ms, self(), :steer_wait)
    {[], %{state | turn: %{turn | wait: wait}}}
  end

  # The session closes the open assistant message at the terminal.
  defp turn_result(%{"queued_turn_count" => 0} = result, state),
    do: {[{:event, state.turn.id, Turn.terminal(result, state.turn)}], %{state | turn: nil}}

  defp turn_result(_result, state),
    do: {[], %{state | terminal: {:error, :no_queued_turn_count}}}

  # Only the first line of a resumed program can say that the session is
  # lost; it comes before any `init`.
  defp lost?(result, state) do
    state.resume != nil and not state.init? and
      Enum.any?(Turn.errors(result), &String.starts_with?(&1, @lost))
  end

  # A random version 4 UUID: `--session-id` takes only a UUID.
  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
