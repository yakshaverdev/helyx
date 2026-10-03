defmodule Helyx.Test.ClaudeCodeFake do
  # A fake `claude` in `bin` reads stream-json lines, as the long-lived
  # program does, and answers in the shapes that
  # `docs/research/claude-code-stream-json.md` records. Program N saves its
  # arguments to `args.N` and each input line to `stdin.N`. It runs
  # `start.N` first; for the K-th user line that starts a query it runs
  # `turn.N.K`, for the Q-th `shouldQuery: false` line `quiet.N.Q` (by
  # default it writes `out.quiet`: an `init` and the replay result), for a
  # control request `ctl.N`, for a control response `resp.N`, and at the
  # end of input `eof.N`. In their output `@U@` is the `uuid` and `@R@` the
  # `request_id` of the line read. The dispatcher of `test_helper.exs` runs
  # it from `bin` next to the session's working directory, so no test
  # changes PATH. The tests that do are in `Helyx.HarnessIO.PathTest`.
  @moduledoc false

  import ExUnit.Callbacks, only: [start_supervised!: 1]
  import Helyx.Test.Events
  import Helyx.Test.HarnessDriver

  alias Helyx.{Message, Session}
  alias Helyx.Provider.{ClaudeCode, Fake}

  @sid "4b3c2d1e-0000-4000-8000-000000000001"

  def sid, do: @sid

  @fake """
  #!/bin/sh
  d=$(dirname "$0")
  n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
  echo $n > "$d/count"
  for a in "$@"; do printf '%s\\n' "$a"; done > "$d/args.$n"
  : > "$d/stdin.$n"
  out() { sed "s/@U@/$u/g; s/@R@/$r/g" "$d/$1"; }
  u=; r=
  [ -f "$d/start.$n" ] && . "$d/start.$n"
  k=0; q=0
  while IFS= read -r line; do
    printf '%s\\n' "$line" >> "$d/stdin.$n"
    v=$(printf '%s\\n' "$line" | sed -n 's/.*"uuid":"\\([^"]*\\)".*/\\1/p')
    [ -n "$v" ] && u=$v
    r=$(printf '%s\\n' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    case "$line" in
      *'"type":"control_response"'*) [ -f "$d/resp.$n" ] && . "$d/resp.$n" ;;
      *'"shouldQuery":false'*) q=$((q+1))
        if [ -f "$d/quiet.$n.$q" ]; then . "$d/quiet.$n.$q"; else out out.quiet; fi ;;
      *'"type":"assistant"'*) ;;
      *'"type":"control_request"'*) [ -f "$d/ctl.$n" ] && . "$d/ctl.$n" ;;
      *'"type":"user"'*) k=$((k+1)); [ -f "$d/turn.$n.$k" ] && . "$d/turn.$n.$k" ;;
    esac
  done
  [ -f "$d/eof.$n" ] && . "$d/eof.$n"
  """

  def setup_fake(%{tmp_dir: tmp}) do
    bin = Path.join(tmp, "bin")
    File.mkdir_p!(bin)
    File.write!(Path.join(bin, "claude"), @fake)
    File.chmod!(Path.join(bin, "claude"), 0o755)
    File.write!(Path.join(bin, "out.quiet"), [init(), "\n", replayed(), "\n"])

    core = :"core_#{System.unique_integer([:positive])}"
    start_supervised!({Helyx.Core, name: core, plugins: [ClaudeCode, Fake]})
    work = Path.join(tmp, "work")
    File.mkdir_p!(work)
    %{core: core, bin: bin, work: work, sessions: Path.join(tmp, "sessions")}
  end

  # Stream-json lines

  def j(map), do: JSON.encode!(map)

  @caps ["interrupt_receipt_v1", "interrupt_cancel_queued_v1", "msg_lifecycle_v1"]

  def init(caps \\ @caps) do
    j(%{
      type: "system",
      subtype: "init",
      session_id: @sid,
      cwd: "/work",
      model: "claude-haiku-4-5-20251001",
      tools: ["Bash", "Read"],
      capabilities: caps,
      uuid: "u1"
    })
  end

  def lifecycle(state),
    do: j(%{type: "command_lifecycle", state: state, command_uuid: "@U@", session_id: @sid})

  def delta(text) do
    j(%{
      type: "stream_event",
      event: %{type: "content_block_delta", index: 0, delta: %{type: "text_delta", text: text}},
      session_id: @sid,
      parent_tool_use_id: nil,
      uuid: "u2"
    })
  end

  def assistant(block) do
    j(%{
      type: "assistant",
      message: %{
        id: "msg_1",
        type: "message",
        role: "assistant",
        model: "claude-haiku-4-5-20251001",
        content: [block],
        stop_reason: nil,
        usage: %{input_tokens: 12, output_tokens: 7}
      },
      parent_tool_use_id: nil,
      session_id: @sid,
      uuid: "u3"
    })
  end

  def tool_use(id, input), do: assistant(%{type: "tool_use", id: id, name: "Bash", input: input})

  def tool_result(id, content) do
    j(%{
      type: "user",
      message: %{
        role: "user",
        content: [%{tool_use_id: id, type: "tool_result", content: content}]
      },
      parent_tool_use_id: nil,
      session_id: @sid,
      uuid: "u4",
      tool_use_result: %{stdout: content}
    })
  end

  def result(text, num_turns \\ 1) do
    j(%{
      type: "result",
      subtype: "success",
      is_error: false,
      result: text,
      stop_reason: if(num_turns > 0, do: "end_turn"),
      num_turns: num_turns,
      terminal_reason: "completed",
      queued_turn_count: 0,
      usage: %{input_tokens: 12, output_tokens: 7},
      session_id: @sid
    })
  end

  # The result of a replayed line: no model call and no `terminal_reason`.
  def replayed do
    j(%{
      type: "result",
      subtype: "success",
      is_error: false,
      result: "",
      num_turns: 0,
      session_id: @sid
    })
  end

  def replay_failed,
    do: j(%{type: "result", subtype: "error_during_execution", is_error: true, num_turns: 0})

  # A history that the first turn of a fresh program replays before "x".
  def replay_history do
    [
      Message.user("a"),
      %Message{role: :assistant, content: [%Message.Text{text: "b"}]},
      Message.user("x")
    ]
  end

  def aborted do
    j(%{
      type: "result",
      subtype: "error_during_execution",
      is_error: true,
      num_turns: 2,
      terminal_reason: "aborted_tools",
      queued_turn_count: 0,
      errors: [],
      session_id: @sid
    })
  end

  def lost(sid) do
    j(%{
      type: "result",
      subtype: "error_during_execution",
      is_error: true,
      num_turns: 0,
      session_id: sid,
      errors: ["No conversation found with session ID: #{sid}"]
    })
  end

  def interrupted(still_queued \\ [], cancelled \\ []) do
    j(%{
      type: "control_response",
      response: %{
        subtype: "success",
        request_id: "@R@",
        response: %{still_queued: still_queued, cancelled: cancelled}
      }
    })
  end

  # The start of a turn: the program took the line.
  def begin, do: [lifecycle("queued"), lifecycle("started"), init()]

  # A reply of one text, as the program streams it.
  def reply(text),
    do: begin() ++ [delta(text), assistant(%{type: "text", text: text}), result(text)]

  # The fake's scripts: output lines, then `tail` as shell code.
  def script(bin, name, lines, tail \\ "") do
    File.write!(Path.join(bin, "out.#{name}"), Enum.map(lines, &[&1, "\n"]))
    File.write!(Path.join(bin, name), "out out.#{name}\n" <> tail)
  end

  def turn(bin, n, k, lines, tail \\ ""), do: script(bin, "turn.#{n}.#{k}", lines, tail)

  def args(bin, n),
    do: bin |> Path.join("args.#{n}") |> File.read!() |> String.split("\n", trim: true)

  def stdin(bin, n) do
    bin
    |> Path.join("stdin.#{n}")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  def programs(bin), do: bin |> Path.join("count") |> File.read!() |> String.trim()

  # The provider without a session: the test process runs the callbacks,
  # as the provider loop does.

  def harness(work, opts \\ []) do
    {:ok, state} = ClaudeCode.init("haiku", [], [cwd: work] ++ opts)
    state
  end

  def request(state, request) do
    from = make_ref()
    {:ok, actions, state} = ClaudeCode.request(request, from, state)
    {from, actions, state}
  end

  def ended?(actions) do
    Enum.any?(actions, fn
      {:event, _turn, {kind, _}} -> kind in [:done, :error]
      {:stop, _reason} -> true
      _ -> false
    end)
  end

  # One turn of a new program: its actions, with its stop, if any, last.
  def run_direct(messages, work) do
    {_from, actions, state} =
      request(harness(work), {:turn, "t1", %Helyx.Context{messages: messages}})

    {actions, _state} = pump(ClaudeCode, state, actions, &ended?/1)
    actions
  end

  def events_of(actions), do: for({:event, _turn, event} <- actions, do: event)

  # Sessions

  def start(ctx, model \\ "claude-code/haiku") do
    {:ok, session} =
      Session.start(ctx.core, model: model, cwd: ctx.work, sessions_dir: ctx.sessions)

    {:ok, _, _} = Session.subscribe(session)
    session
  end

  def prompt(session, text) do
    :ok = Session.prompt(session, text)
    collect_until(:turn_end)
  end

  # Starts a turn on a new program and gives it the program's output
  # until `ready?` holds for the state.
  def running(work, ready?), do: settle(ClaudeCode, start_turn(work), ready?)

  # Starts a turn on a new program and gives it the program's output
  # until the provider sent `event`.
  def running_to(work, event), do: sent_to(start_turn(work), event)

  defp start_turn(work) do
    {_from, _actions, state} =
      request(harness(work), {:turn, "t1", %Helyx.Context{messages: [Message.user("x")]}})

    state
  end

  # Gives the program's output until the provider sent `event`.
  def sent_to(state, event) do
    {_actions, state} = pump(ClaudeCode, state, [], &(event in events_of(&1)))
    state
  end

  def interrupt(state) do
    {from, [], state} = request(state, {:interrupt, "t1"})
    {actions, _state} = pump(ClaudeCode, state, [], replied?(from))
    {:reply, ^from, answer} = List.last(actions)
    {answer, actions}
  end

  # A program turn: the program starts a turn by itself when a background
  # task ends. It has no `command_lifecycle`, and its `result` has `origin`
  # and a null `user_message_uuid` (research note, "Program turns").
  def program_result(text) do
    line = JSON.decode!(result(text))
    origin = %{kind: "task-notification", producer: "session-task"}
    j(Map.merge(line, %{"origin" => origin, "user_message_uuid" => nil}))
  end

  def mcp_request(request_id, message) do
    request = %{subtype: "mcp_message", server_name: "helyx", message: message}
    j(%{type: "control_request", request_id: request_id, request: request})
  end

  def tools_call(request_id, id, meta) do
    params = %{name: "read", arguments: %{path: "a.txt"}, _meta: meta}
    mcp_request(request_id, %{jsonrpc: "2.0", id: id, method: "tools/call", params: params})
  end

  def call(request_id, id, use_id),
    do: tools_call(request_id, id, %{"claudecode/toolUseId" => use_id, progressToken: id})

  # The answers the provider wrote, by control request id.
  def answers(bin, n) do
    for %{"type" => "control_response", "response" => r} <- stdin(bin, n),
        into: %{},
        do: {r["request_id"], r["response"]["mcp_response"] || r}
  end

  def closed(state) do
    {from, [], state} = request(state, :close)
    {_actions, _state} = pump(ClaudeCode, state, [], replied?(from))
    :ok
  end
end
