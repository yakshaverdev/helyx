defmodule Helyx.Provider.ClaudeCode do
  # The TERM grace of the watchdog and the release: claude ends its own
  # commands on TERM, but a KILL leaves them running (research note).
  @term_grace_ms 5_000

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
  tool, and uses its own tools; Helyx tools are not offered. An approval
  request of the program is allowed at once, and any other control
  request gets an error answer at once. Its stderr is
  dropped: the `result` line carries the errors.

  A turn is one user line with a `uuid`. The turn ends at a `result` line
  with `queued_turn_count` 0. After a replay, the provider skips each
  `result` before the start of the turn's line. This needs
  `msg_lifecycle_v1` in `init.capabilities`: without it, the provider
  stops the program with an error at a `result` before the start of the
  turn's line.

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
  stops the harness process.

  With the `:harness_session_id` option the program resumes that harness
  session, and each turn sends only the new prompt: the user messages at
  the end of the transcript. Without it, or when the program no longer has
  that session, the program starts a fresh harness session with an id of
  its own (`--session-id`), and its first turn first sends the rest of the
  transcript as lines that start no model call. The replay keeps the
  newest messages within #{HarnessIO.replay_max_bytes()} bytes of lines,
  and it never starts at a tool result, so no result loses its call. The
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

  defmodule Turn do
    @moduledoc false
    # The running turn. `uuid` is the `uuid` of its user line. `messages`
    # is its transcript until the program started the line: a lost session
    # sends it again to a fresh one. `replay?` is true from the write of a
    # replay before its line until the program started the line.
    # `interrupt` is nil, or the pending `Interrupt`.
    @enforce_keys [:id, :uuid, :messages]
    defstruct [
      :id,
      :uuid,
      :messages,
      :interrupt,
      replay?: false,
      open?: false,
      calls?: false,
      usage: %{}
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
    # of stdout: `:lost` or a line over the cap (`Helyx.HarnessIO.lines/3`).
    # `deadline` and `done?` are only for `Helyx.HarnessIO`, which writes
    # them; this module does not read them.
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
      :deadline,
      buffer: [],
      size: 0,
      init?: false,
      sent?: false,
      done?: false
    ]
  end

  @lost "No conversation found with session ID"

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
  def harness_init(model, _tools, opts) do
    with {:ok, exe} <- HarnessIO.find("claude") do
      state = %State{
        exe: exe,
        model: model,
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

  @impl true
  def harness_request(
        {:turn, id, %Helyx.Context{messages: messages}},
        from,
        %State{turn: nil} = state
      ) do
    turn = %Turn{id: id, uuid: uuid(), messages: messages}
    {events, state} = write_turn(%{state | turn: turn})
    {:ok, [{:reply, from, :ok} | events], state}
  end

  def harness_request({:interrupt, id}, from, %State{turn: %Turn{id: id} = turn} = state) do
    {actions, state} = interrupt(%{state | turn: %{turn | interrupt: %Interrupt{from: from}}})
    {:ok, actions, state}
  end

  # The turn already ended.
  def harness_request({:interrupt, _id}, from, state), do: {:ok, [{:reply, from, :ok}], state}

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
        ["--model=" <> state.model, session]

    argv = ["/bin/sh", "-c", ~S(exec "$0" "$@" 2>/dev/null), state.exe | flags]

    argv
    |> HarnessIO.start(state.cwd, :open, %{state | session_id: id}, grace_ms: @term_grace_ms)
    |> HarnessIO.keep_port()
  end

  # The program of a lost session exits by itself, with nothing run
  # (research note). A fresh program takes its place, and a turn that was
  # written to the lost one goes to the fresh one, with the replay.
  defp relaunch(actions, state) do
    HarnessIO.stop(state)

    fresh = %State{exe: state.exe, model: state.model, cwd: state.cwd, turn: state.turn}

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

    prompt_line =
      line(%{type: "user", uuid: turn.uuid, message: %{role: "user", content: content}})

    if state.resume || state.sent? do
      HarnessIO.write(state, prompt_line)
      {[], %{state | sent?: true}}
    else
      {lines, cut} = replay(history)
      HarnessIO.write(state, [lines, prompt_line])
      event = {:event, turn.id, {:harness_session, state.session_id, cut}}
      {[event], %{state | sent?: true, turn: %{turn | replay?: lines != []}}}
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

  # A sub-agent's own messages stay inside the harness.
  defp translate(%{"parent_tool_use_id" => parent}, state) when parent != nil, do: {[], state}

  # Each query of the program repeats the init line.
  defp translate(%{"type" => "system", "subtype" => "init"} = init, state) do
    caps = if is_list(init["capabilities"]), do: init["capabilities"], else: []
    resume_interrupt(%{state | init?: true, caps: caps})
  end

  defp translate(
         %{"type" => "command_lifecycle", "state" => "started", "command_uuid" => uuid},
         %State{turn: %Turn{uuid: uuid} = turn} = state
       ),
       do: resume_interrupt(%{state | turn: %{turn | messages: nil, replay?: false}})

  defp translate(
         %{"type" => "control_response", "response" => %{"request_id" => id} = response},
         %State{turn: %Turn{uuid: uuid, interrupt: %Interrupt{request_id: id}}} = state
       )
       when is_binary(id) do
    case response do
      %{"subtype" => "success", "response" => %{"still_queued" => [_ | _]}} ->
        answer_interrupt(state, {:error, :still_queued})

      %{"subtype" => "success"} ->
        if cancelled?(response["response"], uuid),
          do: answer_interrupt(state, :ok),
          else: interrupt_progress(state, :response?)

      _error ->
        answer_interrupt(state, {:error, {:interrupt, HarnessIO.cap_error(response["error"])}})
    end
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

  # After a replay, the provider skips each result until `started` of the
  # turn's line. A result of the turn's own line before its `started` is
  # skipped too. The skip needs the program to list `msg_lifecycle_v1` in
  # an earlier `init` line; without it the provider stops the program,
  # because `started` can fail to come. A resumed program never replays,
  # so the result of a lost session does not come here.
  defp translate(%{"type" => "result"}, %State{turn: %Turn{replay?: true}} = state) do
    if "msg_lifecycle_v1" in (state.caps || []),
      do: {[], state},
      else: {[], %{state | terminal: {:error, :no_msg_lifecycle}}}
  end

  defp translate(%{"type" => "result"} = result, state) do
    cond do
      lost?(result, state) ->
        {[], %{state | terminal: :lost}}

      state.turn == nil ->
        {[], state}

      state.turn.interrupt ->
        interrupt_progress(state, :result?)

      match?(%{"queued_turn_count" => n} when is_integer(n) and n > 0, result) ->
        {[], state}

      # The session closes the open assistant message at the terminal.
      true ->
        {emit(state, [terminal(result, state.turn)]), %{state | turn: nil}}
    end
  end

  defp translate(_object, %State{turn: nil} = state), do: {[], state}

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

  defp emit(%State{turn: turn}, events), do: for(event <- events, do: {:event, turn.id, event})

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
  # then kept too.
  defp replay(history) do
    entries =
      history
      |> Enum.chunk_by(&(&1.role == :assistant))
      |> Enum.flat_map(fn
        [%Message{role: :assistant} | _] = messages -> Enum.map(messages, &assistant_entry/1)
        messages -> [user_entry(messages)]
      end)

    HarnessIO.cap_replay(entries, length(history))
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

  # A random version 4 UUID: `--session-id` takes only a UUID.
  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
