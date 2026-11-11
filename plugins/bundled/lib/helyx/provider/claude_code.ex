defmodule Helyx.Provider.ClaudeCode do
  @moduledoc """
  A connected harness provider (ADR 0007) that drives the unmodified
  Claude Code program, `claude`, with stream-json input and output. The
  model ref is `claude-code/<model>`, where `<model>` is what `claude
  --model` takes.

  One `claude` at a time serves the session. A turn is one user line with a
  `uuid`, and a steer is one more user line. The model gets the turn's
  system prompt in place of the program's own, and exactly the session's
  tools, as an SDK MCP server named `helyx`; the program's tools and the
  user's config are off, except the managed settings (ADR 0002).

  The full contract is in `docs/features/long-lived-harness.md`, section
  "Claude Code", and `docs/features/provider-parity.md`. The protocol facts
  are in `docs/research/claude-code-stream-json.md`.
  """

  @behaviour Helyx.Provider

  # The wait for the start of an unresolved steer after a `result` that
  # could not end the turn (`docs/features/long-lived-harness.md`,
  # "Bounds"). Observed: 0 to 10 ms.
  @steer_wait_ms 5_000

  alias Helyx.{HarnessIO, Message, ModelInfo, ProviderError}
  alias Helyx.Provider.ClaudeCode.{Mcp, Meter, Program, Replay, State, Turn}

  import Turn, only: [started?: 1]
  import Program, only: [uuid: 0]

  @lost "No conversation found with session ID"

  # Every observed `init` lists both (research note): the interrupt needs
  # `cancel_queued`, and the turn needs `command_lifecycle` `started`.
  @required_caps ["interrupt_cancel_queued_v1", "msg_lifecycle_v1"]

  @impl true
  def id, do: "claude-code"

  @impl true
  defdelegate release(handles, mode, deadline), to: HarnessIO

  # The program starts at the first turn: it needs the turn's prompt.
  @impl true
  def init(model, tools, opts) do
    with {:ok, info} <- ModelInfo.lookup(id(), "anthropic", model),
         {:ok, options, resume} <- Program.resume(opts),
         {:ok, exe} <- HarnessIO.find("claude") do
      # A stored session that is not resumed gives no cost mark.
      state = %State{
        exe: exe,
        model: model,
        tools: tools,
        cwd: Keyword.fetch!(opts, :cwd),
        resume: resume,
        meter: Meter.start(resume && opts[:resume_usage], info.context_window)
      }

      {:ok, struct!(state, options)}
    end
  end

  # A program turn that the session did not open gives way: the program
  # queues the turn's line after it, and drops its lines as before a start.
  @impl true
  def request({kind, id, arg}, from, %State{turn: turn} = state)
      when kind in [:turn, :compact] and (turn.phase == :idle or turn.phase == :program) do
    case program(state, kind, arg) do
      %State{stream: %{terminal: nil}} = state ->
        case write_turn(%{state | turn: Turn.new(kind, id, uuid(), arg)}) do
          {:ok, events, state} -> {:ok, [{:reply, from, :ok} | events], state}
          {:error, reason} -> {:ok, [{:reply, from, {:error, reason}}], state}
        end

      %State{stream: %{terminal: {:error, reason}}} = state ->
        {:ok, [{:reply, from, {:error, reason}}], state}
    end
  end

  # A steer is a user line with a `uuid` of its own. `claude` never
  # refuses a user line, so the answer is `:ok` at the write, and the steer
  # is unresolved until the start of its line.
  def request({:steer, id, steer_id, text}, from, %State{turn: %Turn{id: id} = turn} = state) do
    uuid = uuid()
    steer = Replay.user_line(uuid, Replay.user_content(Message.user(text)))

    # A steer during a held replay goes out after the turn's line.
    {write?, turn} = Turn.steer(turn, steer)
    if write?, do: HarnessIO.write(state, steer)

    turn = %{turn | steers: Map.put(turn.steers, uuid, steer_id)}
    {:ok, [{:reply, from, :ok}], %{state | turn: turn}}
  end

  # The terminal of the turn went out first: nothing reached the program.
  def request({:steer, _id, _steer_id, _text}, from, state),
    do: {:ok, [{:reply, from, :rejected}], state}

  # A `result` that the turn holds for an unresolved steer counts as the
  # turn's `result` for the interrupt, until a steer starts.
  def request({:interrupt, id}, from, %State{turn: %Turn{id: id} = turn} = state) do
    {actions, state} = interrupt(%{state | turn: Turn.interrupt(turn, from)})
    {:ok, actions, state}
  end

  # The turn already ended.
  def request({:interrupt, _id}, from, state), do: {:ok, [{:reply, from, :ok}], state}

  def request({:tool_result, _id, call_id, {status, text}}, from, state),
    do: {:ok, [{:reply, from, :ok}], Mcp.result(state, call_id, status, text)}

  def request(:idle_close, from, %State{tasks: [], notified?: false, turn: turn} = state)
      when turn.phase == :idle,
      do: request(:close, from, state)

  # A program turn starts 100 to 150 ms after the `task_notification`, with
  # `tasks` already empty (research note): one `:busy` waits for it. A
  # program turn that runs, which the session did not open, also keeps the
  # program: the session is idle, so no Helyx turn is open here.
  def request(:idle_close, from, state),
    do: {:ok, [{:reply, from, :busy}], %{state | notified?: false}}

  def request(:close, from, %State{stream: %{port: nil}} = state),
    do: {:ok, [{:reply, from, :ok}], state}

  def request(:close, from, state), do: {:ok, [], HarnessIO.close(state, from)}

  # Helyx does not know whether the program will start the steer, so the
  # program stops.
  @impl true
  def info({:timeout, ref, :steer_wait}, %State{turn: %Turn{phase: {:steer_wait, ref}}} = state),
    do: {:stop, :steer_not_started, state}

  def info(message, state) do
    case HarnessIO.port_message(message, state, &translate/2) do
      {:lines, actions, state} -> read(actions, state)
      {:closed, from} -> {:ok, [{:reply, from, :ok}], HarnessIO.update(state, port: nil)}
      {:exit, status} -> {:stop, {:claude_code_exit, status}, state}
      # A message of a closed port, such as the port of a lost session.
      :other -> {:ok, [], state}
    end
  end

  defp read(actions, %State{stream: %{terminal: nil}} = state), do: {:ok, actions, state}
  # A close waits for the lost program's exit, which answers it.
  defp read(actions, %State{stream: %{terminal: :lost, closing: nil}} = state),
    do: relaunch(actions, state)

  defp read(actions, %State{stream: %{terminal: :lost}} = state), do: {:ok, actions, state}

  defp read(actions, %State{stream: %{terminal: {:error, reason}}} = state),
    do: {:stop, reason, actions, state}

  # A turn's program has its prompt and no commands; a compaction's has the
  # commands for `/compact`. A differing one is replaced by one that resumes the
  # harness session; a fresh one, or one with no state, has nothing to compact.
  defp program(%State{resume: nil, sent?: false} = state, :compact, _text), do: state
  defp program(%State{persist?: false} = state, :compact, _text), do: state
  defp program(state, :compact, _text), do: Program.compaction(state)
  defp program(state, :turn, context), do: Program.turn(state, context)

  # The program of a lost session exits by itself, with nothing run (research
  # note). A fresh one takes its place, and a turn written to the lost one goes
  # to it with the replay. The steers are dropped, not written again, and each
  # gets a notice; the new session starts a meter with the window of config.
  defp relaunch(actions, state) do
    turn = %{state.turn | steers: %{}}
    fresh = Program.replace(state, turn: turn, meter: Meter.start(nil, state.meter.config_window))

    case Program.start(fresh, state.system) do
      %State{stream: %{terminal: {:error, reason}}} = state ->
        {:stop, reason, actions, state}

      %State{turn: %Turn{phase: :idle}} = state ->
        {:ok, actions, state}

      state ->
        case write_turn(state) do
          {:ok, events, state} -> {:ok, actions ++ events, state}
          {:error, reason} -> {:stop, reason, actions, state}
        end
    end
  end

  # A compaction with no program of its own (`program/3`) fails and writes nothing.
  defp write_turn(%State{turn: %Turn{compact: :asked}, commands?: false} = state),
    do: {:ok, [{:event, state.turn.id, Program.no_compaction(state)}], %{state | turn: %Turn{}}}

  # The prompt is the user messages at the end of the transcript; a resumed
  # harness session, or one that took a turn, has the rest. An open turn over
  # the replay bound fails the turn with a typed error, not a silent cut.
  defp write_turn(%State{turn: %Turn{phase: {:queued, messages, _, _}} = turn} = state) do
    {prompt, history} = HarnessIO.split_prompt(messages)
    content = Enum.flat_map(prompt, &Replay.user_content/1)
    prompt_line = Replay.user_line(turn.uuid, content)

    if state.resume || state.sent? do
      HarnessIO.write(state, prompt_line)
      {:ok, [], %{state | sent?: true}}
    else
      with {:ok, [first | chunks], cut, replay?} <- Replay.chunks(history, prompt_line, id()) do
        HarnessIO.write(state, first)
        turn = %{turn | phase: {:queued, messages, chunks, replay?}}
        {:ok, Program.resume_events(state, turn.id, cut), %{state | sent?: true, turn: turn}}
      end
    end
  end

  # Interrupt

  # A fresh program lists its capabilities only in the `init` line of its
  # first query, after the start of the turn's line: the interrupt waits
  # for it, within the interrupt bound. After a replay it also waits for the
  # start of the turn's line, because `cancel_queued` could drop replay lines
  # and leave a harness session with part of the history
  # (docs/features/long-lived-harness.md, "The interrupt").
  defp interrupt(%State{init?: false} = state), do: {[], state}
  defp interrupt(%State{turn: %Turn{phase: {:queued, _, _, true}}} = state), do: {[], state}

  defp interrupt(%State{turn: %Turn{interrupt: {:pending, from, seen}} = turn} = state) do
    id = "interrupt_" <> turn.uuid
    request = %{subtype: "interrupt", cancel_queued: true}

    HarnessIO.write(
      state,
      Replay.line(%{type: "control_request", request_id: id, request: request})
    )

    {[], %{state | turn: %{turn | interrupt: {:sent, from, id, seen}}}}
  end

  # The interrupt is done when both its control response and the turn's
  # `result` came, in either order: a turn that ended just before the
  # interrupt gives its `result` first. A response that cancelled the
  # turn's line is the end of the turn: no `result` comes for a cancelled
  # line (research note).
  defp interrupt_progress(%State{turn: turn} = state, key) do
    turn = Turn.interrupt_seen(turn, key)

    # A turn that ended before Helyx wrote the interrupt gets no interrupt.
    if Turn.interrupt_done?(turn),
      do: answer_interrupt(%{state | turn: turn}, :ok),
      else: {[], %{state | turn: turn}}
  end

  defp resume_interrupt(%State{turn: %Turn{interrupt: {:pending, _from, _seen}}} = state),
    do: interrupt(state)

  defp resume_interrupt(state), do: {[], state}

  defp answer_interrupt(%State{turn: turn} = state, answer),
    do: {[{:reply, Turn.interrupt_from(turn), answer}], %{state | turn: %Turn{}}}

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
  # query by itself.
  defp translate(%{"type" => "system", "subtype" => "init"} = init, state) do
    caps = if is_list(init["capabilities"]), do: init["capabilities"], else: []
    missing = @required_caps -- caps
    state = %{state | init?: true, notified?: false}

    cond do
      missing != [] ->
        {[], HarnessIO.update(state, terminal: {:error, {:missing_capabilities, missing}})}

      state.turn.phase == :idle ->
        id = uuid()
        turn = %Turn{id: id, uuid: id, phase: :program}
        {[{:event, id, :turn_start}], %{state | turn: turn}}

      true ->
        resume_interrupt(state)
    end
  end

  defp translate(
         %{"type" => "command_lifecycle", "state" => "started", "command_uuid" => uuid},
         %State{turn: %Turn{uuid: uuid} = turn} = state
       ),
       do: resume_interrupt(%{state | turn: Turn.start(turn)})

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

  # The answer to the prompt (`Program.start/2`). With an error the program would
  # run without the product's prompt, so the provider process stops.
  defp translate(
         %{
           "type" => "control_response",
           "response" => %{"request_id" => "initialize"} = response
         },
         state
       ) do
    if response["subtype"] == "success" do
      {[], state}
    else
      error = ProviderError.reason(id(), :initialize, response["error"], {:initialize, ""})
      {[], HarnessIO.update(state, terminal: {:error, error})}
    end
  end

  defp translate(
         %{"type" => "control_response", "response" => %{"request_id" => id} = response},
         %State{turn: %Turn{uuid: uuid, interrupt: {:sent, _from, id, _seen}}} = state
       )
       when is_binary(id) do
    # Only `still_queued` exactly `[]` confirms that no queued work
    # remains; a missing or other value answers an error (ADR 0007). A
    # `cancelled` that is not a list stops the provider.
    case response do
      %{"subtype" => "success", "response" => %{"still_queued" => []} = body} ->
        if :lists.member(uuid, body["cancelled"]),
          do: answer_interrupt(state, :ok),
          else: interrupt_progress(state, :response)

      %{"subtype" => "success"} ->
        answer_interrupt(state, {:error, :still_queued})

      _error ->
        error = ProviderError.reason(id(), :interrupt, response["error"], {:interrupt, ""})
        answer_interrupt(state, {:error, error})
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

  # Every other request gets an error. The program runs with
  # `bypassPermissions` and no `--permission-prompt-tool`, so no approval
  # comes (research note); one that comes is refused (ADR 0007).
  defp translate(%{"type" => "control_request", "request_id" => id}, state)
       when is_binary(id) do
    response = %{subtype: "error", request_id: id, error: "not supported by Helyx"}
    HarnessIO.write(state, Replay.line(%{type: "control_response", response: response}))
    {[], state}
  end

  # A result before `started` of the turn's line is not the turn's: the
  # result of a replayed line, of a program turn that the program started
  # by itself, or of the turn's own line (#246). The result of a lost
  # session comes before any `init` and before `started`.
  defp translate(%{"type" => "result"} = result, state) do
    state = %{state | meter: Meter.result(state.meter, result)}

    cond do
      lost?(result, state) -> {[], HarnessIO.update(state, terminal: :lost)}
      state.turn.phase == :idle -> {[], state}
      started?(state.turn) -> turn_result(result, state)
      true -> release(result, state)
    end
  end

  # The model lines before `started` of the turn's line belong to no Helyx
  # turn, as between turns: a program turn has no `command_lifecycle`. The
  # meter still reads them: their calls are in the program's totals.
  defp translate(object, %State{turn: turn} = state) when not started?(turn),
    do: {[], %{state | meter: Meter.line(state.meter, object)}}

  # Compaction lines; a compaction turn's model lines stay in the program.
  defp translate(%{"type" => type} = line, %State{turn: turn} = state)
       when type == "system" or (turn.compact != nil and type in ~w(stream_event assistant user)),
       do: emit(state, Turn.compaction(turn, line))

  defp translate(
         %{
           "type" => "stream_event",
           "event" => %{"type" => "content_block_delta", "delta" => delta}
         },
         %State{turn: turn} = state
       ),
       do: emit(state, {Turn.delta(delta), turn})

  defp translate(
         %{"type" => "assistant", "message" => %{"content" => blocks}} = line,
         %State{turn: turn, meter: meter} = state
       )
       when is_list(blocks),
       do: emit(%{state | meter: Meter.line(meter, line)}, {Turn.assistant(blocks), turn})

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
  defp release(
         %{"num_turns" => 0},
         %State{turn: %Turn{phase: {:queued, messages, [next | chunks], replay?}} = turn} = state
       ) do
    HarnessIO.write(state, next)
    {[], %{state | turn: %{turn | phase: {:queued, messages, chunks, replay?}}}}
  end

  defp release(_result, state), do: {[], state}

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
         %State{turn: %Turn{interrupt: interrupt}} = state
       )
       when is_tuple(interrupt),
       do: interrupt_progress(state, :result)

  # An unresolved steer keeps the turn: `claude` reads a line that came
  # before this `result` after it and runs it as a turn of its own
  # (research note). The turn waits #{@steer_wait_ms} ms for its start,
  # then for the next `result`.
  defp turn_result(
         %{"queued_turn_count" => 0},
         %State{turn: %Turn{steers: steers, phase: phase} = turn} = state
       )
       when map_size(steers) > 0 do
    phase =
      case phase do
        {:steer_wait, _ref} -> phase
        _ -> {:steer_wait, :erlang.start_timer(@steer_wait_ms, self(), :steer_wait)}
      end

    {[], %{state | turn: %{turn | phase: phase}}}
  end

  # The session closes the open assistant message at the terminal.
  defp turn_result(%{"queued_turn_count" => 0} = result, state) do
    {terminal, meter} = Turn.terminal(result, state.turn, state.meter)
    {[{:event, state.turn.id, terminal}], %{state | turn: %Turn{}, meter: meter}}
  end

  defp turn_result(_result, state),
    do: {[], HarnessIO.update(state, terminal: {:error, :no_queued_turn_count})}

  # Only the first line of a resumed program can say that the session is
  # lost; it comes before any `init`.
  defp lost?(result, state) do
    state.resume != nil and not state.init? and
      Enum.any?(Turn.errors(result), &String.starts_with?(&1, @lost))
  end
end
