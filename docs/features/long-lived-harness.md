# Long-lived harness

Status: approved by the owner on 2026-09-27, ticket #192. Implementation waits for "Verify before implementation"; #196 is done.

## Goal

One harness program serves a whole Helyx session, not one turn. Today each external turn starts `claude` or `codex app-server`, resumes the harness session, sends the prompt, and ends the program. A steer aborts the turn and sends everything again, and an abort kills the program's group.

With this feature:

- A steer reaches the running turn. The harness takes it at its next model call, and the running command goes on.
- An abort stops the turn inside the program, and the program lives on for the next turn. A kill is the fallback, not the path.
- The harness sees the Helyx tools, next to its own tools.
- The start cost, the resume, and the replay happen once per program, not once per turn.

The protocol facts are in `docs/research/claude-code-stream-json.md` ("Long-lived session and the control protocol") and `docs/research/codex-app-server.md` ("Long-lived use, steering, approvals, and client tools"). How t3code keeps one process per session is in `docs/research/t3code-harness-adapters.md`. It does not use `turn/steer`, its Claude interrupt closes the session, and it gives tools through HTTP MCP, so this design differs from it in those parts. The owner's decisions are in #192, "Decision (2026-09-26)":

1. This comes before the UX tickets of #115.
2. Codex gets the Helyx tools through `dynamicTools`, behind a check. They survive a resume in a new process (verified). The tool set is fixed when the thread starts.
3. The Helyx tools add to the harness tools. They do not replace them.
4. Claude defers MCP tools behind `ToolSearch`. This is accepted.
5. Approvals stay "bypass all". The request and response path is built now, for tool calls.

## What changes and what does not

| | Today | With this feature |
|---|---|---|
| Program life | one turn | the session, or until a provider switch, a crash, or a failed interrupt |
| Steer on an external turn | abort, then a new turn with the steer | delivered to the running turn at most once; queued for the next turn only after a confirmed rejection |
| Abort | kill the stream Task, release the group | stop the Helyx tool calls, then interrupt in the program within a deadline; on a timeout, queued work left, or (Codex) a running command, stop the program with TERM |
| Resume and replay | every turn | when the program starts: the first turn, after a crash, after a provider switch |
| Helyx tools in the harness | not offered | Claude: an SDK MCP server over stdio. Codex: `dynamicTools` |
| Harness requests | Codex approvals: `accept`; all else: an error | Helyx tool calls run on the hands; approvals still `accept`; all else an error |
| Stream Task per external turn | yes: builds the context, calls the provider, checks the events | a prepare Task builds the context; the harness process checks and sends the events |
| Watchdog stdin buffer | a 16 MiB byte cap; over it the command is stopped (#196, a prerequisite) | as today |

These do not change:

- The session file format (ADR 0001). A steer that the harness takes becomes a user message in the transcript, which the format already allows.
- The event check of `Helyx.Session.Stream`. Each event passes it before it reaches the session.
- ADR 0004's rule that the death of an owner releases the resource. The watchdog, with the stdin cap of #196.
- The line caps, the parsing of the harness output, and the replay rules.

## Shape

```text
session ── hands ──┬── harness process (per session): a Task of the hands, runs Helyx.Session.Harness
                   │       └── port ── watchdog ── claude / codex app-server
                   ├── prepare Task (per turn, short): ModelContext.build, Compaction.compact
                   └── tool Tasks (per Helyx tool call), as in a local turn
```

- **The harness process** is a long-lived Task of the hands. It runs the Core loop `Helyx.Session.Harness` (`@moduledoc false`). The loop owns the `receive` and the event check. The provider callbacks run only inside this loop. A callback can block the loop, so the loop cannot enforce a deadline on itself. A kill armed at the OTP timer server enforces it (see "Deadlines").
- **Startup.** The hands start the Task inside a `handle_call`, so the Task is in `tasks` before the hands read the next message. A `Helyx.Tool.hold/1` from the first line of plugin code therefore finds its pid, as for a stream Task today. There is no transfer of ownership: the hands hold every handle from the first `hold/1`. The hands reply to the session with the pid of the harness process. The loop calls `harness_init/3`, then sends `{:harness_ready, pid}` to the session. The hands arm the connect kill when they start the Task, and the loop cancels it before `{:harness_ready, pid}` (see "Deadlines").
- **Context preparation.** For each connected turn the hands start a short prepare Task and reply to the session with its pid. It runs `ModelContext.build/2` and `Compaction.compact/2`, as `Helyx.Session.Stream.run/1` does today, and sends the context to the session. The session sends `{:turn, turn_id, context}` to the harness process (see "Turn states"). A raise, an exit, or the prepare bound fails the turn with today's rules, and the harness process stays. At the bound, its armed kill ends it (see "Deadlines"). So a plugin bug in preparation never stops the program, and a connected provider never skips the configured plugins.
- **No stream Task for a connected turn.** The loop checks each event with the checks of `Helyx.Session.Stream` and sends `{:stream_event, turn_id, event}` to the session, as the stream Task does today. At the end of a turn it sends the terminal. The session ends the turn on the terminal, not on a Task reply. Before each send the loop reads the session queue length, as the stream Task does: over 10,000 waiting messages the turn fails with `{:error, {:session_behind, length, 10000}}` (#197).
- **The session** keeps its rules. It never runs plugin code. It sends each request to the harness process as a message, with an armed kill (see "Deadlines"). The hands start and release processes; they do not carry requests.
- **A crash** of the harness process is a `:DOWN` in the hands. The turn fails through the turn cleanup below. There is no reconnect inside a turn. The next external turn starts a new harness process, which resumes or replays as today.
- An abort does not remove the harness process from `tasks`. The hands release it only on a close, a stop, or a crash.

### Turn cleanup

Every end of a connected turn that leaves Helyx work runs one path in the hands: an abort, a crash of the harness process, a bad action, a missed deadline, a failed `tool_result` delivery, a failed prepare Task, and a normal end with Helyx work left (see "Normal end").

1. Kill the turn's prepare Task and Helyx tool Tasks, and release their handles, as for a local turn today. Drop the queued tool requests of the turn.
2. When the harness process lives: answer its open tool requests of the turn with `aborted` (abort steps 3 to 5), or stop it (below).
3. The hands answer the session only after steps 1 and 2. Until then the session starts no turn, as during an abort today (`Helyx.Session` moduledoc). So a new turn never runs tools beside a command of the old turn.

**Stop** is the path for a harness process that failed or did not answer. The armed kill of a deadline ends the Task, or the loop ends itself after it sends an answer that needs a stop: an error answer to `{:turn, ...}` or to `{:interrupt, ...}`. Neither waits for the session. Its port closes at once, and the watchdog sends TERM to the program group, waits the grace, and sends KILL. So the program stops on time, even while the session and the hands are busy. The hands release its handles when they handle its `:DOWN`. A stop never sends end of input first: Claude runs its queued turns after end of input (`claude-code-stream-json.md`, "End of file on stdin"), and a stop must not run them. **Close** (end of input, the exit, then the release) is only for a normal end: the session ends or the provider changes, with no turn running.

### Deadlines

A deadline must stop the harness process on time, whatever the session and the hands do. Both can be late: the hands wait in `Task.yield_many/2` during a release for up to `release_ms`, 20,000 ms (`lib/helyx/session/hands.ex`), and the session writes the session file synchronously (`append_message/2` in `lib/helyx/session/server.ex`) and can have about 10,000 waiting messages in its mailbox before the stream fails (#197). So no timer message in either process can enforce a deadline.

The rule: **the kill is armed with the request, and the harness loop disarms it with the reply.**

1. The sender of a request (the session, or the hands for connect) arms `:timer.kill_after(bound, harness_pid)` and puts the timer ref in the request. A request is `{:turn, ...}`, `{:steer, ...}`, `{:interrupt, ...}`, `{:tool_result, ...}`, or `:close`.
2. The loop calls `:timer.cancel(tref)` when the provider gives the reply, and sends the reply after the cancel. For connect, the loop cancels before it sends `{:harness_ready, pid}`.
3. When the loop does not reply in time, the OTP timer server kills the harness process. The port closes, and the watchdog stops the program group (see "Stop"). Neither the session nor the hands take part in the kill.
4. The session and the hands learn it from the `:DOWN`, with reason `:killed`, whenever they read it. Then they run the turn cleanup and report "the harness did not answer in time". Helyx processing cannot delay the stop. The OTP timer itself is not exact: it fires at the bound or later (OTP `timer` documentation), so a bound is a lower limit of the wait, not an exact time.

- The deadline is measured at the harness: a reply that the loop made in time is never a timeout, even when the session reads it late. A late session cannot cause a false stop.
- The loop is the only process that can cancel. A blocked callback blocks the cancel too, so a blocked loop is always killed. The session cannot tell a blocked loop from a slow program, and does not need to.
- The OTP timer server is a process of the node, not of Helyx. It processes no Helyx event, writes no file, and waits on no release.
- A reply for a request whose kill fired cannot come: the process is dead.
- The prepare Task uses the same rule: the hands arm `:timer.kill_after/2` when they start it, and its Core code cancels the kill before it sends the context. Only one mechanism enforces a deadline in this feature.
- `:close` needs no cancel: the loop exits after the program exits, and a kill of a dead pid does nothing.

### Turn states

A connected turn has three states before its end. The line between them is the send of `{:turn, ...}`, not its answer: the harness can start the turn before its answer reaches the session.

| State | From | To | A steer | An abort |
| --- | --- | --- | --- | --- |
| `preparing` | the turn starts; the prepare Task runs | `submitting`, when the session sends `{:turn, ...}` | stays in the local steer queue of the session, as on a local turn | the session kills the prepare Task and ends the turn. The harness got nothing, so it is untouched |
| `submitting` | `{:turn, ...}` sent | `submitted`, when its answer is `:ok` | stays local | abort steps 1 to 6. The loop reads its messages in order, so it handles the interrupt after the turn request. The provider sends the program's interrupt when it has the program's turn id; the interrupt deadline covers that wait. Any answer but `:ok`, or the deadline, stops the harness |
| `submitted` | `{:turn, ...}` answered `:ok` | the end of the turn | goes to the harness (see "Steer") | abort steps 1 to 6 |

- An error answer to `{:turn, ...}` fails the turn, and the loop ends itself after it sends the answer (see "Stop"): Helyx does not know whether the program started the turn.
- When the session sends `{:turn, ...}`, the steers of the local queue go into its context as user messages, in order. They are part of the prompt, not steers. So the harness never gets a user line before the prompt of its turn.
- A steer that arrives in `submitting` stays local. When the answer is `:ok`, the session sends the local steers as steers, in order.
- A steer never starts a program turn outside an active Helyx turn. Claude starts a line that it reads while idle as a turn of its own, so the loop keeps that program turn inside the Helyx turn (see "Steer" and "Claude Code").

### Normal end

At the terminal of a normal end, the session checks for Helyx work of the turn: a running Helyx tool Task, a queued tool request, or an open tool request.

- With none, the turn ends as today.
- With some, the turn ends, and the session asks the hands for the turn cleanup, step 1. Each Helyx call with no result gets an `aborted` error result, as today at the end of an external call. The session starts no turn until the hands answer.

A harness can withdraw a tool request: at an interrupt, Claude sends the MCP notification `notifications/cancelled` in an `mcp_message` for an open `tools/call` (#198). The source also has `control_cancel_request`, which was never seen; the provider treats it the same way. Codex withdraws nothing: an open `item/tool/call` gets no `serverRequest/resolved`, so the abort answers it first (abort step 3). The provider gives the action `{:cancel_tool, turn_id, call_id}`. The session asks the hands to kill and release that one tool Task, or drops the request from the queue. Its result, if one comes, is dropped: the pair `{turn_id, call_id}` is no longer open.

## Interface changes

A sketch for review. The names are proposals.

`Helyx.Provider`, optional callbacks for a provider with an external turn. All three run in the harness process only.

```elixir
@type from :: reference()
# Each request reaches the loop with the ref of its armed kill; the loop
# cancels the kill before the reply. The provider never sees the ref.
@type request ::
        {:turn, turn_id :: String.t(), Helyx.Context.t()}
        | {:steer, turn_id :: String.t(), steer_id :: String.t(), text :: String.t()}
        | {:interrupt, turn_id :: String.t()}
        | {:tool_result, turn_id :: String.t(), call_id :: String.t(), {:ok | :error, String.t()}}
        | :close
@type action ::
        {:event, turn_id :: String.t(), Helyx.Provider.event()}
        | {:reply, from(), term()}
        | {:cancel_tool, turn_id :: String.t(), call_id :: String.t()}

# Starts the program and holds its handles with `Helyx.Tool.hold/1`.
# `tools` are the checked Helyx tool specs of session start.
@callback harness_init(model :: String.t(), tools :: [Helyx.Tool.spec()], opts :: keyword()) ::
            {:ok, state :: term()} | {:error, term()}

# A request from Core. The provider replies now or later with `{:reply, from, value}`.
@callback harness_request(request(), from(), state :: term()) :: {:ok, [action()], term()}

# A message to the harness process: port data, the watchdog, a timer.
@callback harness_info(msg :: term(), state :: term()) ::
            {:ok, [action()], term()} | {:stop, reason :: term(), term()}
```

- The loop checks every action at the boundary. An event goes through the `Helyx.Session.Stream` check. A reply must have the shape of its request, below. A bad action ends the loop. The closed port stops the program, and the `:DOWN` starts the turn cleanup.
- The replies: `{:turn, ...}` gives `:ok`. `{:steer, ...}` gives `:ok`, `:rejected`, or `{:error, reason}`. `{:interrupt, ...}` gives `:ok` or `{:error, reason}`. `{:tool_result, ...}` gives `:ok` when written. `:close` gives `:ok` after the exit.
- "Written" means that the watchdog accepted the bytes within its stdin cap (#196). It does not mean that the program read them. Delivery is known only from the program's own output: the `result` line or the control response for Claude, the JSON-RPC answer for Codex, and the harness's `tool_result` event for a tool call.
- `stream/3` stays. A provider without `harness_init/3` keeps one program per turn, so the change can land one provider at a time.

New stream events, for a connected turn only:

- `{:user_message, steer_id, text}`: the harness took the steer `steer_id` at this point. The session first closes the open assistant message with the rules of `message_end`, then appends a user message. No message goes between a call and its result.
- `{:tool_request, call_id, name, args}`: the harness asks Helyx to run a Helyx tool. This event only runs the tool. It is not in the transcript (see "Helyx tool calls").

`Helyx.Session.Hands`:

- Holds at most one harness process per session, with its provider and model.
- Starts it on the first connected turn, and again after a crash, a failed interrupt, or a provider switch.
- Accepts `Helyx.Tool.hold/1` from it, because it is in `tasks`.
- Does not carry requests to it and keeps no timer for it. Plugin code does not run in the hands process.
- Runs the prepare Task of each connected turn.

### Helyx tool calls

One path puts a call in the transcript: the harness's own events. The Codex `dynamicToolCall` item, and the Claude `tool_use` block named `mcp__helyx__<tool>` with its `tool_result`, give the `tool_call` and `tool_result` events, as for the harness's own tools today.

`{:tool_request, call_id, name, args}` only runs the tool:

1. The provider maps the request to the call id of its own events. Codex: `item/tool/call` carries `callId`, the id of the `dynamicToolCall` item. Claude: the `mcp_message` `tools/call` carries `_meta["claudecode/toolUseId"]`, the id of the `tool_use` block. Both are to verify.
2. A request whose id does not map gets an error result at once, and nothing runs.
3. The session runs the tool on the hands, as a local call: one at a time per turn, with its own bounds.
4. The result goes back with `{:tool_result, turn_id, call_id, result}`. The loop keeps the open requests keyed by `{turn_id, call_id}`. A result whose pair is not open is dropped. So a late result of an old turn never answers a call of a new turn, even when the harness uses the same call id again.

### Abort

The order on a `submitting` or `submitted` turn (a `preparing` turn: see "Turn states"):

1. The session ends the turn at once, as today, and gives each call with no result an `aborted` error result.
2. The hands run step 1 of the turn cleanup: kill and release the turn's Helyx tool Tasks, and drop the queued tool requests.
3. The harness process answers every open tool request of the turn with an error result `aborted`. From here, a tool request of this turn gets that answer at once and runs nothing. A pending harness request that is not a tool call is answered as on a close: Codex `decline`, Claude an error.
4. The session sends `{:interrupt, turn_id}` with the interrupt bound.
5. `:ok` keeps the harness process. Any other answer, or the deadline, stops it (see "Turn cleanup"). A stop sends no end of input, so Claude runs no queued turn.
6. The abort call returns to the client after step 5.

Every event with the aborted turn id that comes after step 1 is dropped by the session, as today.

### Steer

Each steer gets a `steer_id` from the session. Delivery is at most once.

The session's `submitted` state does not prove that the program still runs the turn: the terminal can be on its way to the session. So the loop decides, because it sees the terminal and the steer in one order. Two orders are possible:

- **The loop has already emitted the terminal of the turn.** The steer gets `:rejected`, and nothing is written. The rejection is confirmed, because nothing reached the program. The session queues the steer for the next turn.
- **The loop wrote the steer before the terminal.** The steer is unresolved until the program shows that it took it. While a steer of the turn is unresolved, the provider does not end the turn (see "Claude Code" and "Codex").

The answers:

| Answer to `{:steer, ...}` | Meaning | Session |
| --- | --- | --- |
| `:ok` | the program has the steer | waits for `{:user_message, steer_id, text}` |
| `:rejected` | confirmed: the loop sent nothing, or the program refused it | queues it for the next turn, as a steer on a local turn |
| `{:error, _}` | unknown | does not queue it again |
| the deadline | unknown; the armed kill stops the harness process, and the turn fails (see "Deadlines") | does not queue it again |

When a turn ends and a steer with `:ok` or an unknown answer has no `user_message`, the session emits a notice: "the steer was not confirmed; send it again if needed". Its text stays in the notice. It is never sent twice by Helyx.

A steer that waits for its answer or its `user_message` counts in the 32 entries of the steer queue until the turn ends.

### Claude Code

- `claude --output-format stream-json --verbose --input-format stream-json --include-partial-messages --permission-mode bypassPermissions --session-id=<uuid> --mcp-config <helyx server>`, with no `-p`. The run passes `--resume=<id>` in place of `--session-id` when the harness session exists.
- A turn is one user line. The turn ends at a `result` line with `queued_turn_count` 0 **and** no unresolved steer. A steer that `claude` queues as its next turn therefore stays in the same Helyx turn.
- A steer is a user line with `uuid` equal to `steer_id`. `claude` never rejects a user line, so the provider checks first: after the terminal of the turn, it answers `:rejected` and writes nothing. Otherwise the write gives `:ok`, and the steer is unresolved.
- `command_lifecycle` `started` for that `uuid` resolves the steer and gives `{:user_message, steer_id, text}`. It comes 0 to 10 ms after the tool result or the `result` (#198). The replay echo is not used: it comes only when the next model call starts, 0.65 to 1.77 s later.
- A `result` with `queued_turn_count` 0 can come before `claude` read an unresolved steer. Then `claude` reads it later and starts a turn of its own. #198 saw this in every run: a line queued at the end of a turn always ran as a turn of its own, and every `result` had `queued_turn_count` 0. So the provider waits for `started`, then for the next `result` with `queued_turn_count` 0, and only then emits the terminal. The whole program turn is inside the Helyx turn.
- The wait for `started` after such a `result` is bounded (see "Bounds"). Over the bound, the loop ends itself (see "Stop"): Helyx does not know whether the program will start the steer.
- `interrupt` is the control request `interrupt` with `cancel_queued: true`.
  - The program must list `interrupt_cancel_queued_v1` in `init.capabilities`. Without it, every interrupt answers `{:error, :no_cancel_queued}`, and the abort stops the program.
  - A response with a `still_queued` list that is not empty answers `{:error, :still_queued}`. The abort stops the program.
  - Otherwise the reply is `:ok` after the `result` line with `terminal_reason` `aborted_streaming` or `aborted_tools`. Both steps are inside the interrupt bound.
- The Helyx tools are an SDK MCP server named `helyx`. The provider answers `mcp_message` control requests. A `tools/call` gives `{:tool_request, ...}`.

### Codex

- `initialize` with `experimentalApi`, then `thread/start` with `dynamicTools` (the Helyx tools), or `thread/resume` with the trust overrides, which a resume does not keep (research note).
- A turn is `turn/start`. A steer is `turn/steer` with `expectedTurnId` and `clientUserMessageId` equal to `steer_id`. The `userMessage` item carries this id in the field `clientId` (#198). After `turn/completed` of the turn, the provider answers `:rejected` and sends nothing. The server also checks `expectedTurnId`, so a steer that crosses the end of the turn gets the error below.
  - A success answer gives `:ok`. The `userMessage` item with that `clientId` gives `{:user_message, ...}`.
  - The errors `no active turn to steer` and a turn id mismatch give `:rejected`. Any other error gives `{:error, reason}`.
- `turn/interrupt` stops the turn but **not a running command**: the command runs to its end, and its late `item/completed` can come during the next turn (#198, 7 of 7 runs). So the provider tracks the open `commandExecution` items of the turn (`item/started` without `item/completed`). Owner decision on #201:
  - No open command: `interrupt` is `turn/interrupt`. The answer comes only after the turn stopped. The program stays.
  - An open command: `interrupt` answers `{:error, :command_running}` at once, and the abort stops the program. On TERM the program ends its commands (research note). The next turn starts the program again and resumes, as today.
  - After an interrupt with `:ok`, a `turn/started` that Helyx did not ask for, or any item of the stopped turn, ends the loop, and the program stops.
  - An accepted steer that the model did not yet take is dropped by `turn/interrupt`, and no turn starts (#198).
- `item/tool/call` gives `{:tool_request, ...}`. The result goes back as `contentItems` text.
- When `experimentalApi` is rejected, the thread starts without `dynamicTools`, and the session emits a notice that the Helyx tools are off for this provider.
- A thread whose tool set differs from the current Helyx tool set starts a new thread with the replay.

## Bounds

The numbers are proposals. Observed values are given for comparison.

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| connect: Task start to `{:harness_ready, pid}` and a ready thread or session | 30,000 ms, armed kill | stop and turn cleanup. Observed: under 2 s |
| prepare Task | 10,000 ms, armed kill | the kill ends it; the turn fails; the harness process stays |
| interrupt, from the request to the reply | 2,000 ms, armed kill | stop and turn cleanup. Observed: 19 ms (Codex), 50 ms (Claude) |
| steer answer | 2,000 ms, armed kill | stop and turn cleanup; the steer is unknown: not queued again, a notice |
| `{:turn, ...}` answer | 2,000 ms, armed kill | stop and turn cleanup |
| Claude: the wait for `started` of an unresolved steer after a `result` with `queued_turn_count` 0 | 5,000 ms, a timer of the loop. Observed: 0 to 10 ms | the loop ends itself: stop and turn cleanup; the steer is unknown, a notice. A blocked loop does not reach this timer, and an abort (an armed kill) ends it |
| steers waiting for an answer or a `user_message` | in the 32 entries of the session's steer queue | `{:error, :queue_full}` to the client |
| requests from the session open in the harness process | 8 | `{:error, :busy}` to the caller at once |
| Helyx tool requests of one turn | one runs; at most 16 wait | over 16: an error result to the harness at once |
| `tool_result` answer (written, see above) | 2,000 ms, armed kill | stop and turn cleanup |
| bytes written to the program and not yet read by it | the watchdog stdin cap of #196: 16 MiB (`@stdin_max_bytes` in `Helyx.Watchdog`), plus at most one read of 65,536 bytes and the pipe (row "watchdog input on stdin" of `coding-agent.md`) | the watchdog stops the program group; the closed port gives a crash, then the turn cleanup |
| the harness's own requests (approval, elicitation) | answered at once: approvals `accept`, the rest an error | none |
| events from the harness process to the session mailbox | 10,000 waiting messages, checked before each send, as for every provider (#197) | the turn fails with `{:error, {:session_behind, length, 10000}}` |
| close (normal end only): end of input to the exit | 5,000 ms, armed kill | stop: TERM, grace, KILL |
| TERM grace | Claude 5,000 ms (today 500 ms), Codex 5,000 ms | KILL. The program's own command groups can stay after a KILL (research notes) |
| stdout line | 16 MiB, as today | the loop ends; stop and turn cleanup |
| stderr | the last 2,000 bytes of lines that start with `ERROR`, ANSI removed | older lines are dropped |
| harness process life | the session; no idle close | unbounded in time, #195 |
| Helyx tool specs to the harness | the checked specs of session start | none; a changed set needs a new Codex thread |

On `SIGTERM` both programs end their own commands: Claude 2.1.283 in about 0.7 s (`claude-code-stream-json.md`), Codex 0.157.1 in 0.04 s (`codex-app-server.md`, "Processes on 0.157.1"). The Codex program has no graceful restart handler in stdio mode, but that handler is not the cleanup of commands.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| harness process | the hands, as a Task in `tasks` | hands, linked; the hands trap exits | close at session end or provider switch, then `release/3` of its handles | the link kills it with the hands; its crash is a `:DOWN` in the hands, which run the turn cleanup | kept after an interrupt with `:ok`; stopped on any other answer (the loop ends itself) or a missed deadline (the armed kill) |
| program port, watchdog, program group | `Helyx.Watchdog.start/4` in `harness_init/3` | hands (the handles) and watchdog (the life) | close: end of input, the exit, then `release/3` | the closed port ends the watchdog's stdin: TERM, grace, KILL | as the harness process; a stop sends no end of input |
| prepare Task | hands | hands, linked | returns the context | the link; the turn fails | killed in turn cleanup step 1 |
| the harness's own command groups | the program | the program | the program ends them | on TERM the program ends them; a KILL leaves them (research notes, both programs) | Claude: the interrupt ends a foreground command; a background task survives (#194). Codex: the interrupt does not end a command, so an abort with an open command stops the program (#201) |
| Helyx tool Task of a connected turn | hands | hands, linked | the result is sent back | the link; on a crash of the harness process, turn cleanup step 1 | killed and released in turn cleanup step 1 |
| open tool request | the harness | the harness process (keyed by `{turn_id, call_id}`) | answered with the result | ends with the harness process | answered `aborted` in abort step 3 |
| open request from the session | the session (with a timer) | the harness process | answered | the session's monitor gives `:DOWN`: turn cleanup | answered, or the timer stops the harness process; a late reply is dropped |
| steer in the local queue of a `preparing` turn | the session | the session | goes into the context of `{:turn, ...}` | ends with the session | dropped with the queues of the aborted turn, as today |

## Verified before implementation

#198 ran the protocol checks on 2026-09-27 (`claude` 2.1.283, `codex` 0.157.1). The results are in `docs/research/claude-code-stream-json.md` and `docs/research/codex-app-server.md`, and this doc follows them. Two items stay open:

- The stop path end to end with the watchdog cap: #196 must land first. The test belongs to #199.
- When Claude sends `control_cancel_request`: never seen. The provider handles it as `notifications/cancelled` if it comes.

The implementation tickets still test both orders at a Claude turn end, with the provider: a steer after the terminal writes nothing, and a steer written before a `result` keeps the Helyx turn open until its `started` and the next `result`.

## Out of scope

- Approvals in the UI. The request path is built, and the answer stays `accept` (#192, decision 5).
- An idle close of the harness process (#195).
- The ownership of Claude background tasks between turns (#194).
- `thread/fork`, `thread/revert`, `rewind_files`, and branching.
- Compaction inside the harness (`thread/compact/start`).
- The model switch inside one program (`set_model`, the `turn/start` overrides). A switch closes the program, as today.
- The known gap of a result after an abort (`docs/features/external-turn.md`).
- Flow control between a provider stream and the session mailbox. #197 chose a cap on the queue length, over which the turn fails.
