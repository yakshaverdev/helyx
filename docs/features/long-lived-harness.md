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
- **Context preparation.** For each connected turn the hands start a short prepare Task. The session sends the start as a cast and does not wait for a reply (see "Built in #199"). It runs `ModelContext.build/2` and `Compaction.compact/2`, as `Helyx.Session.Stream.run/1` does today, and sends the context to the session. The session sends `{:turn, turn_id, context}` to the harness process (see "Turn states"). A raise, an exit, the prepare bound, or a plugin that returns anything but a `Helyx.Context` fails the turn, and the harness process stays. At the bound, its armed kill ends it (see "Deadlines"). So a plugin bug in preparation never stops the program, and a connected provider never skips the configured plugins.
- **No stream Task for a connected turn.** The loop checks each event with the checks of `Helyx.Session.Stream` and sends `{:stream_event, turn_id, event}` to the session, as the stream Task does today. At the end of a turn it sends the terminal. The session ends the turn on the terminal, not on a Task reply. Before each send the loop reads the session queue length, as the stream Task does: over 10,000 waiting messages the turn fails with `{:error, {:session_behind, length, 10000}}` (#197).
- **The session** keeps its rules. It never runs plugin code. It sends each request to the harness process as a message, with an armed kill (see "Deadlines"). The hands start and release processes; they do not carry requests.
- **A crash** of the harness process is a `:DOWN` in the hands. The turn fails through the turn cleanup below. There is no reconnect inside a turn. The next external turn starts a new harness process, which resumes or replays as today.
- An abort does not remove the harness process from `tasks`. The hands release it only on a close, a stop, or a crash.

### Turn cleanup

Every end of a connected turn that leaves Helyx work runs one path in the hands: an abort, a crash of the harness process, a bad action, a missed deadline, a failed `tool_result` delivery, a failed prepare Task, and a normal end with Helyx work left (see "Normal end").

1. Kill the turn's prepare Task and Helyx tool Tasks, and release their handles, as for a local turn today. The harness loop holds the waiting tool requests, not the hands (see "Built in #203").
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

At the terminal of a normal end, the session checks for Helyx work of the turn: a running Helyx tool Task, or an open tool request. The loop answers the waiting tool requests at the terminal (see "Built in #203").

- With none, the turn ends as today.
- With some, the turn ends, and the session asks the hands for the turn cleanup, step 1. Each Helyx call with no result gets an `aborted` error result, as today at the end of an external call. The session starts no turn until the hands answer.

A harness can withdraw a tool request: at an interrupt, Claude sends the MCP notification `notifications/cancelled` in an `mcp_message` for an open `tools/call` (#198). The source also has `control_cancel_request`, which was never seen; the provider treats it the same way. Codex withdraws nothing: an open `item/tool/call` gets no `serverRequest/resolved`, so the abort answers it first (abort step 3). The provider gives the action `{:cancel_tool, turn_id, call_id}`. The loop acts by the state of the request (see "Built in #203", "The start ask"): a waiting request leaves the loop's queue; a request that the loop sent but that did not get `:ok` at its start ask stays in the loop until the ask, which gets `:dropped`; a request that got `:ok` goes to the session, also after the end of its turn, and the session asks the hands to kill and release that one tool Task. Its result, if one comes, is dropped: the pair `{turn_id, call_id}` is no longer open.

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
        | :idle_close
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
- The replies: `{:turn, ...}` gives `:ok`. `{:steer, ...}` gives `:ok`, `:rejected`, or `{:error, reason}`. `{:interrupt, ...}` gives `:ok` or `{:error, reason}`. `{:tool_result, ...}` gives `:ok` when written. `:close` gives `:ok` after the exit. `:idle_close` gives `:ok` after the exit, as `:close`, or `:busy` when the program runs work of its own, a background task; the program then stays (see "Idle close").
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
3. The session runs the tool on the hands, as a local call, with its own bounds. The loop sends the session one request at a time per turn and keeps the waiting ones (see "Built in #203").
4. The result goes back with `{:tool_result, turn_id, call_id, result}`. The loop keeps the open requests keyed by `{turn_id, call_id}`. A result whose pair is not open is dropped. So a late result of an old turn never answers a call of a new turn, even when the harness uses the same call id again.

### Abort

The order on a `submitting` or `submitted` turn (a `preparing` turn: see "Turn states"):

1. The session ends the turn at once, as today, and gives each call with no result an `aborted` error result.
2. The hands run step 1 of the turn cleanup: kill and release the turn's Helyx tool Tasks. The loop drops its waiting tool requests in step 3.
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
- A steer is a user line with a `uuid` of its own; the provider maps it to `steer_id` (#202: a `steer_id` is not a UUID). `claude` never rejects a user line, so the provider checks first: after the terminal of the turn, it answers `:rejected` and writes nothing. Otherwise the write gives `:ok`, and the steer is unresolved.
- `command_lifecycle` `started` for that `uuid` resolves the steer and gives `{:user_message, steer_id, text}`. It comes 0 to 10 ms after the tool result or the `result` (#198). The replay echo is not used: it comes only when the next model call starts, 0.65 to 1.77 s later.
- A `result` with `queued_turn_count` 0 can come before `claude` read an unresolved steer. Then `claude` reads it later and starts a turn of its own. #198 saw this in every run: a line queued at the end of a turn always ran as a turn of its own, and every `result` had `queued_turn_count` 0. So the provider waits for `started`, then for the next `result` with `queued_turn_count` 0, and only then emits the terminal. The whole program turn is inside the Helyx turn.
- The wait for `started` after such a `result` is bounded (see "Bounds"). Over the bound, the loop ends itself (see "Stop"): Helyx does not know whether the program will start the steer.
- `interrupt` is the control request `interrupt` with `cancel_queued: true`.
  - The program must list `interrupt_cancel_queued_v1` in `init.capabilities`. Without it, every interrupt answers `{:error, :no_cancel_queued}`, and the abort stops the program.
  - A success response whose `still_queued` is not exactly `[]` answers `{:error, :still_queued}`: a non-empty list, `null`, another type, or a missing value. Only `[]` confirms that no queued work remains (ADR 0007). The abort stops the program.
  - Otherwise the reply is `:ok` after the success response and the `result` line of the turn, or after a success response whose `cancelled` list holds the turn's `uuid`. Both steps are inside the interrupt bound. The `result` of an interrupted turn has `terminal_reason` `aborted_streaming` or `aborted_tools`. A turn that ended just before the interrupt has `completed` (#200). A turn whose `result` comes before Helyx writes the interrupt gets `:ok`, and Helyx writes no interrupt. After a replay, a `result` before `started` of the turn's line is skipped, so the interrupt waits for `started`.
  - Accepted, because each one fails safe (owner decision on #200):
    - The interrupt answers `:ok` on the turn's `result` with any `terminal_reason`, not only `aborted_*`. A turn that ended just before the interrupt gives `completed`, and an idle program writes no other `result`.
    - After a replay the interrupt waits for `started` of the turn's line. A replay that takes longer than the 2,000 ms interrupt bound stops the program through the armed kill; the fresh harness session is then not resumed.
- The provider needs `msg_lifecycle_v1` in `init.capabilities` (owner decision on #200: accepted, because it fails safe; since #246 for every turn, not only after a replay). Without it, the first `result` before `started` stops the program with `{:error, :no_msg_lifecycle}`. So an older `claude` without the capability cannot run a turn.
- A program that lists `msg_lifecycle_v1` and never sends `started` for the turn's line keeps the turn in `submitted`, which is unbounded and accepted (see "Bounds"). An abort ends it: the interrupt waits for `started`, and the interrupt bound stops the program.
- A `result` with `queued_turn_count` above 0 does not end the turn (the ticket rule, kept by the owner on #200), also with a pending interrupt. The turn stays in `submitted` until an abort. A missing `queued_turn_count`, or one that is not a non-negative integer, does not confirm that no queued work remains, so it stops the program with `{:error, :no_queued_turn_count}` (ADR 0007).
- The Helyx tools are an SDK MCP server named `helyx`. The provider answers `mcp_message` control requests. A `tools/call` gives `{:tool_request, ...}`.

### Codex

- `initialize` with `experimentalApi`, then `thread/start` with `dynamicTools` (the Helyx tools), or `thread/resume` with the trust overrides, which a resume does not keep (research note).
- A turn is `turn/start`. A steer is `turn/steer` with `expectedTurnId` and `clientUserMessageId` equal to `steer_id`. The `userMessage` item carries this id in the field `clientId` (#198). After `turn/completed` of the turn, the provider answers `:rejected` and sends nothing. The server also checks `expectedTurnId`, so a steer that crosses the end of the turn gets the error below.
  - A success answer gives `:ok`. The `userMessage` item with that `clientId` gives `{:user_message, ...}`.
  - The exact error `no active turn to steer` with code -32600 gives `:rejected`. Any other error gives `{:error, reason}`, a turn id mismatch included: its exact form is not verified, so it does not confirm a safe state (#202).
- `turn/interrupt` stops the turn but **not a running command**: the command runs to its end, and its late `item/completed` can come during the next turn (#198, 7 of 7 runs). So the provider tracks the open `commandExecution` items of the turn (`item/started` without `item/completed`). Owner decision on #201:
  - No open command: `interrupt` is `turn/interrupt`. The answer comes only after the turn stopped. The program stays.
  - An open command: `interrupt` answers `{:error, :command_running}` at once, and the abort stops the program. On TERM the program ends its commands (research note). The next turn starts the program again and resumes, as today.
  - The same rule holds at every end of a turn, not only at an abort: a `turn/completed` with an open command stops the program, so no new turn starts while a command of an earlier turn can still run (section "Built in #201"). From #224 it holds for an open tool item of any type (section "Built in #224").
  - Sub-agents (#224): an abort while a child thread of the turn has open work stops the program too, with `:agent_running`. A child thread with open work at a normal end of the turn belongs to the program, and the idle close answers `:busy` while it runs (section "Built in #224").
  - At any time, not only after an interrupt: a `turn/started` that Helyx did not ask for, a `turn/completed` of a turn whose id is not known, or an item of a turn that is not the running one ends the loop, and the program stops (`:turn_not_asked`, `:item_of_ended_turn`). The program runs one turn of its thread at a time, so such a line is a protocol fault, and the stop fails safe.
  - An accepted steer that the model did not yet take is dropped by `turn/interrupt`, and no turn starts (#198).
- `item/tool/call` gives `{:tool_request, ...}`. The result goes back as `contentItems` text. A call that the provider answers itself records its call id first, and a later call with that id in the turn gets an error (the rule of `Helyx.Provider`, #203).
- When `experimentalApi` is rejected, the thread starts without `dynamicTools`, and the session emits a notice that the Helyx tools are off for this provider.
- A thread whose tool set differs from the current Helyx tool set starts a new thread with the replay.

## Bounds

The numbers are proposals. Observed values are given for comparison.

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| connect: Task start to `{:harness_ready, pid}` and a ready thread or session | 30,000 ms, armed kill | stop and turn cleanup. Observed: under 2 s |
| prepare Task | 10,000 ms, armed kill | the kill ends it; the turn fails; the harness process stays |
| start of the prepare Task in the hands | one release of the hands, up to the 20,000 ms release deadline | the cast waits in the mailbox of the hands; the prepare bound starts when the Task starts, so a `preparing` turn lasts at most about 30,000 ms |
| interrupt, from the request to the reply | 2,000 ms, armed kill | stop and turn cleanup. Observed: 19 ms (Codex), 50 ms (Claude) |
| steer answer | 2,000 ms, armed kill | stop and turn cleanup; the steer is unknown: not queued again, a notice |
| `{:turn, ...}` answer | 2,000 ms, armed kill | stop and turn cleanup |
| `submitted`: from the `:ok` answer to the terminal event | unbounded, and accepted: a model turn has no time bound, as the stream of an external turn | the user aborts; the interrupt has its armed kill |
| Claude: the wait for `started` of an unresolved steer after a `result` with `queued_turn_count` 0 | 5,000 ms, a timer of the loop. Observed: 0 to 10 ms | the loop ends itself: stop and turn cleanup; the steer is unknown, a notice. A blocked loop does not reach this timer, and an abort (an armed kill) ends it |
| steers waiting for an answer or a `user_message` | in the 32 entries of the session's steer queue | `{:error, :queue_full}` to the client |
| requests from the session open in the harness process | 8; a `tool_result` or `tool_start` request is not counted and not limited, because it is never open after its callback | `{:error, :busy}` to the caller at once |
| Helyx tool requests of one turn | one runs; at most 16 wait. A withdrawn running request counts until the result of its killed run comes | over 16: an error result to the harness at once |
| `tool_result` answer (written, see above) | 2,000 ms, armed kill | stop and turn cleanup |
| `tool_start` answer: the session asks the loop before it runs a Helyx tool | 2,000 ms (`harness_ms.tool_start`), armed kill. The session does not block: the ask is a message, and the answer comes as `{:harness_reply, ...}`. The loop answers it itself, with no provider callback and no call to the session | the kill stops the harness process, and its `:harness_down` fails the turn; the call is dropped and does not run. A dead loop gives the same `:harness_down`. At a session end the hands and the harness process end with the session. An answer after the end of the turn goes to the wait after the turn and runs nothing; the session sends the call's `aborted` result after the hands' cleanup |
| a Helyx call's result after the end of its turn (the call got `:ok` at the ask) | the kill wait of the hands (their release deadlines, up to 20,000 ms), then the tool result bound, 2,000 ms, armed kill; the next turn waits for both | stop and turn cleanup |
| the loop's own `tool_result` requests (`aborted`, over the limit, a used call id) | no armed kill: the provider replies inside the same callback, as the Claude provider does when it writes the result; the session's `tool_result` requests follow the same rule | a reply that is not among the callback's actions stops the harness process at once with `{:tool_result_not_answered, turn_id, call_id}` |
| Claude: the call ids of `tools/call` in the provider's turn (`used`) | one entry per `tools/call` with a string id, cleared when the provider's turn ends: unbounded, and accepted, as the turn's transcript is | none |
| call ids that the live turn used | one entry per tool request of the turn, cleared at the turn's end: unbounded, and accepted, as the turn's transcript is | none |
| bytes written to the program and not yet read by it | the watchdog stdin cap of #196: 16 MiB (`@stdin_max_bytes` in `Helyx.Watchdog`), plus at most one read of 65,536 bytes and the pipe (row "watchdog input on stdin" of `coding-agent.md`) | the watchdog stops the program group; the closed port gives a crash, then the turn cleanup |
| the harness's own requests (approval, elicitation) | answered at once: approvals `accept`, the rest an error | none |
| events from the harness process to the session mailbox | 10,000 waiting messages, checked before each send, as for every provider (#197) | the turn fails with `{:error, {:session_behind, length, 10000}}` |
| close (normal end only): end of input to the exit | 5,000 ms, armed kill | stop: TERM, grace, KILL |
| TERM grace | Claude 5,000 ms, Codex 5,000 ms | KILL. The program's own command groups can stay after a KILL (research notes) |
| stdout line | 16 MiB, as today | the loop ends; stop and turn cleanup |
| stderr | the last 2,000 bytes of lines that start with `ERROR`, ANSI removed. Claude: nothing is kept, and the `result` line carries the errors (#200). Codex: none, stderr is dropped (#201) | older lines are dropped |
| Codex: a line of a turn that is not the running one (`turn/started` not asked for, `turn/completed` of an unknown turn, an item of another turn) | none: one such line | the loop ends at once: stop and turn cleanup, with `:turn_not_asked` or `:item_of_ended_turn` |
| Codex: child threads with open work (`agents`) | one entry per child thread, kept between turns; an entry leaves only at a `subAgentActivity` item of kind `completed` | none. Accepted hole (#224, for the owner): a child whose `completed` never comes (seen after an interrupt of the child turn) keeps its entry until the program ends, so the idle close answers `:busy` until the session ends |
| Codex: open tool items at a turn's end | none: one open tool item of any type (#224) | the loop ends at once: stop and turn cleanup, with `:command_running` for a command and `:tool_running` for another type; the release TERMs the program before the next turn starts; on TERM the program ends its commands, and a KILL after the 5,000 ms grace leaves them (row "the harness's own command groups") |
| Codex: the shape of a line that changes turn or thread state (`turn/started`, `turn/completed`, `item/started`, `item/completed`, the answers to the requests) | one check of the full shape before any state changes: string turn and item ids, no request `id` on a turn or item notification of any thread, an answer only for a due request with its id (any other answer is dropped), the asked thread id or the exact lost-thread error for `thread/resume` and a string thread id for `thread/start`, an answer with a `result` or an `error` object but not both (and a string `result.turn.id` for `turn/start`), a `turn/completed` status of `completed`, `failed`, or `interrupted`, and a tool item's `item/completed` status that ends the item, such as `completed`, `failed`, or `declined` for a command (the schema's enums, research note), an `item/completed` of an open tool item with the same type, a string `threadId` on the four turn and item lines, and a string `agentThreadId` and a schema `kind` on a `subAgentActivity` item (#224) | any other shape, a missing or unknown status included, ends the loop at once: stop and turn cleanup, with `{:malformed, method}`; in the handshake, the connect fails with it |
| Codex: requests with an answer due | a new id per request (`due` maps it to its method); a `turn/interrupt` waits until no `turn/interrupt` answer is due, and a `turn/start` until no `turn/start` or `thread/inject_items` answer is due | the wait of a turn or an interrupt is bounded by its armed kill (2,000 ms) |
| harness process life | the session, or 30 minutes idle (`harness_ms.idle`, 1,800,000 ms): no turn and no wait of the session. A program with a background task answers `:busy` and stays, so its life is unbounded while the task lives (#194). The same holds for a Claude background sub-agent and a Codex child thread with open work (#224) | the idle close (see "Idle close") |
| idle close: `:idle_close` to its answer, and end of input to the exit | 5,000 ms, armed kill (the close bound) | stop: TERM, grace, KILL. The wait before the next turn ends at the `:harness_down` |
| Core stop with an open harness process | the session end with no turn, also during a wait (an idle close, a switch close, an abort): the current harness process and the one of the wait get the close, in parallel (5,000 ms, armed kill). The close comes after any open request, so a `:busy` answer does not keep the program. Then the session stops its hands and waits for them (22,000 ms: one release of 20,000 ms and a margin). During a turn the harness process ends with the hands. The session's shutdown bound is 30,000 ms, so the Core stops its task supervisor only after the hands ended (#219) | over 22,000 ms the session kills the hands: no release runs, the port closes with the harness process (the keeper of `Helyx.HarnessIO.keep_port/1`), and the watchdog ends the group. Accepted hole: at a session end during an abort or an idle-close wait, the close is bounded by what is left of the kill of the waited request, not by the full 5,000 ms. When that kill fires first, the program gets TERM from the watchdog, not end of input; the release still runs. |
| Helyx tool specs to the harness | the checked specs of session start | none; a changed set needs a new Codex thread |

On `SIGTERM` both programs end their own commands: Claude 2.1.283 in about 0.7 s (`claude-code-stream-json.md`), Codex 0.157.1 in 0.04 s (`codex-app-server.md`, "Processes on 0.157.1"). The Codex program has no graceful restart handler in stdio mode, but that handler is not the cleanup of commands.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| harness process | the hands, as a Task in `tasks` | hands, linked; the hands trap exits | close at session end, at a provider switch, or at an idle close with no background task, then `release/3` of its handles | the link kills it with the hands; its crash is a `:DOWN` in the hands, which run the turn cleanup | kept after an interrupt with `:ok`; stopped on any other answer (the loop ends itself) or a missed deadline (the armed kill) |
| program port, watchdog, program group | `Helyx.Watchdog.start/4` in `harness_init/3` | hands (the handles) and watchdog (the life) | close: end of input, the exit, then `release/3` | the closed port ends the watchdog's stdin: TERM, grace, KILL | as the harness process; a stop sends no end of input |
| prepare Task | hands | hands, linked | returns the context | the link; the turn fails | killed in turn cleanup step 1 |
| harness process and program at a Core stop | as above | as above | with no turn, also during a wait, the session closes each harness process it holds or waits for in `terminate/2`, and the hands run `release/3` for it; then the session stops the hands and waits for them. During a turn the harness process ends with the hands. The Core stops its task supervisor after its session supervisor, so every release runs while the task supervisor runs (tests: "a Core stop ... ends the program group" in `plugins/bundled`) | the hands are killed at the wait bound: the port closes with the harness process, and the watchdog ends the group. Accepted hole: at a session end during an abort or an idle-close wait, the close is bounded by what is left of the kill of the waited request, not by the full 5,000 ms. When that kill fires first, the program gets TERM from the watchdog, not end of input; the release still runs. | as on a normal end |
| the harness's own command groups | the program | the program | the program ends them | on TERM the program ends them; a KILL leaves them (research notes, both programs) | Claude: the interrupt ends a foreground command; a background task survives the abort and the turn end, and ends with the program: the close at the session end or at a model switch, a stop after a failed interrupt or another error, or a crash of Helyx. The program ends its background tasks first, on end of input or on TERM (#194). The idle close skips a program with a running background task (#195). Claude sub-agents (#224): the interrupt ends a foreground sub-agent inside the abort; a background sub-agent is a background task. Codex: the interrupt does not end a command, so an abort with an open command stops the program, and so does the end of a turn with an open tool item (#201, #224). A Codex child thread with open work belongs to the program after a normal end of its turn, and an abort of the turn that has it stops the program (#224) |
| Helyx tool Task of a connected turn | hands | hands, linked | the result is sent back | the link; on a crash of the harness process, turn cleanup step 1 | killed and released in turn cleanup step 1 |
| open tool request | the harness | the harness process (keyed by `{turn_id, call_id}`) | answered with the result | ends with the harness process | answered `aborted` in abort step 3 |
| open request from the session | the session (with a timer) | the harness process | answered | the session's monitor gives `:DOWN`: turn cleanup | answered, or the timer stops the harness process; a late reply is dropped |
| steer in the local queue of a `preparing` turn | the session | the session | goes into the context of `{:turn, ...}` | ends with the session | dropped with the queues of the aborted turn, as today |

## Verified before implementation

#198 ran the protocol checks on 2026-09-27 (`claude` 2.1.283, `codex` 0.157.1). The results are in `docs/research/claude-code-stream-json.md` and `docs/research/codex-app-server.md`, and this doc follows them. Two items stay open:

- The stop path end to end with the watchdog cap: #196 must land first. The test belongs to #199.
- When Claude sends `control_cancel_request`: never seen. The provider handles it as `notifications/cancelled` if it comes.

The implementation tickets still test both orders at a Claude turn end, with the provider: a steer after the terminal writes nothing, and a steer written before a `result` keeps the Helyx turn open until its `started` and the next `result`.

## Built in #199

#199 built the Core part: the callbacks, the loop `Helyx.Session.Harness`, the armed kills, the prepare Task, the turn states, the abort, the close, and the stop. The names in the code:

- A request is `{:harness_request, from, tref, request}` to the harness process, sent by `Helyx.Session.Harness.request/3`, which arms the kill. The reply is `{:harness_reply, from, value}` to the session.
- The hands send `{:harness_down, pid, reason}` after the release of the harness process's handles, and the session acts on that message, not on its own monitor. So a new harness process never starts while the hands still hold the handles of an old one. A harness process that ended while the session was idle is found when a message or the end of a turn or a wait would start a turn: the session waits for its `:harness_down`, and the message waits as a follow-up. A steer during that wait queues as a steer, and steers go first, as in the wait of an abort. A harness process that ends after this check ends during the new turn: the turn starts on the old process, and its `:harness_down` fails that turn. The session never waits in a call for hands that release a harness process: the prepare Task starts with a cast, and the connect runs only when the session holds no harness process. `reason` is the turn's error: `:harness_timeout` after an armed kill, `{:task_exit, reason}` after a crash, `{:harness_init, reason}`, `{:harness_error, kind, reason}` after an error answer, `{:harness_stop, reason}` after a stop from `harness_info/2`, `{:bad_action, action}`, `{:bad_return, value}`, a malformed event's error, `{:session_behind, length, 10000}`, and `:closed`.
- A turn fails at that message, not at the error answer: the loop ends itself after an error answer, and the session waits for the release.
- The prepare Task checks the return of each plugin at the boundary (`Helyx.Session.Stream.prepare/4`) and sends `{:prepared, turn_id, {:ok, context}}` with a `Helyx.Context`, or `{:prepared, turn_id, {:error, {:bad_context, plugin}}}` when the return is not a `Helyx.Context` with exactly its three fields, a `system` that is nil or a string, and `messages` and `tools` that are lists. The check does not look into the list elements. Here `plugin` is `:model_context` or `:compaction` and the value is not part of the reason. The error fails the turn with `{:bad_context, plugin}`, and the harness process stays. So a connected turn leaves `preparing` within the prepare bound, with a checked context or a failure. The hands send `{:prepare_failed, turn_id, reason}` when it dies; the turn fails with `{:task_exit, reason}`.
- The kill is cancelled before the reply goes out, but `:timer.cancel/1` does not tell whether the kill already fired. A reply that the loop makes at the bound can therefore be followed by the kill. This is a documented exception to "a reply that the loop made in time is never a timeout". After a `{:turn, ...}` reply, the turn fails at the `:harness_down` with `:harness_timeout`. After an interrupt reply, the abort ends as usual, and the next turn can start on the process before the kill ends it; a connected turn then fails with `:harness_timeout`, as a turn does on a process that ends after the check above. This is accepted: the turn fails at a bound, and no request reaches a new harness process before the release.
- #202 replaced the rule that a steer on a connected turn waits as a follow-up (see "Built in #202").
- #203 added the Helyx work at a normal end (see "Built in #203").

## Built in #200

#200 made `Helyx.Provider.ClaudeCode` a connected provider: turn, interrupt, and stop. Steer (#202) and the Helyx tools (#203) are not in it. The decisions in the code:

- `stream/3` answers `{:error, :connected}`, as the Codex provider does (#201). The session never calls it for a provider with `harness_init/3`, so the per-turn `claude -p` run is gone.
- `harness_init/3` starts one `claude` with `--session-id=<new uuid>`, or `--resume=<id>` when the session gives `:harness_session_id`. Stderr is dropped, as before: the `result` line carries the errors, so the stderr row of "Bounds" keeps nothing for Claude. `{:harness_session, id, cut}` comes when the first turn of a fresh program is written, with the replay: a fresh idle program writes no `init` line before its first user line (research note, #200 section).
- A lost session: the resumed program writes one `result` with the lost text before any `init`, with no input (research note, #200 section). The provider then starts a fresh program with a new id. A turn that was already written goes to the fresh program with the replay, and `{:harness_session, id, cut}` names the new id.
- A turn writes its user line with a `uuid` and answers `:ok` at once. The turn ends at a `result` with `queued_turn_count` 0. The provider emits only the terminal; the session closes the open assistant message.
- After a replay, each replay user line gets its `result` before `started` of the turn's line; an assistant line gets none (research note, #200 section, for one replay user line; inferred for more). The provider skips every `result` before that `started`, so a failed replay line does not end the turn.
- So after a replay the provider needs `command_lifecycle` lines. It takes `msg_lifecycle_v1` in the `capabilities` of an earlier `init` as the sign that they come (inferred: the research note lists the capability and the lines, but does not link them). A `result` in the skip with no such `init` stops the program with the error `:no_msg_lifecycle`. The steer rows need `started` too. A `result` of the turn's own line before its `started` is also skipped. No run showed one; if it comes, the turn ends only by an abort, and the interrupt bound then stops the program.
- An interrupt writes `interrupt` with `cancel_queued: true` after two waits inside the interrupt bound. First, the program lists its capabilities only in the `init` line of its first query, so the interrupt waits for that line. A fresh idle program writes no `init` before its first user line (research note). Nobody tested a resumed program. The provider waits for its `init` too. Second, after a replay the interrupt waits for `started` of the turn's line.
- The reason for the second wait is inferred, not observed. The replay lines are queued queries too, so `cancel_queued` can drop some of them. The live program would then hold part of the history, and the next turn would go to it. `started` of the turn's line comes after the replay results (research note, #200 section, for one replay user line; inferred for more).
- Without the second wait, the turn's line was written before the interrupt, so the program has it, queued or started, when it reads the interrupt.
- The interrupt answers `:ok` when both the success response and the turn's `result` came, in either order, or when the response's `cancelled` list holds the turn's `uuid`: no `result` comes for a cancelled line (research note, #200 section). The `result` need not have `terminal_reason` `aborted_*`. A turn that ended just before the interrupt gives a `completed` result, then the response of an idle program, and no other result follows (research note). An interrupt for a turn that already ended, or whose `result` comes before the interrupt is written, answers `:ok` and writes nothing.
- A `can_use_tool` request of the program gets `allow` with its input unchanged, because the program runs with `bypassPermissions` (row "the harness's own requests"). With no `--permission-prompt-tool`, the program sends none (research note). Every other control request gets an error response at once.
- Not a hole (#226): a sub-agent writes no `result` line, and its own lines carry `parent_tool_use_id` (research note, "Sub-agents at the end of a turn"). So the `result` of the turn's line is the only `result` that ends the turn.
- A close while a resumed program reports its session lost starts no fresh program: the close waits for the lost program's exit, which answers it.
- A delivery release TERMs first, as a cancel does: the harness process ends normally after a stop while `claude` can still run a command.
- After an abort that left no assistant message, the next prompt holds the aborted user message and the new one, because the prompt is all user messages at the end of the transcript. This was so before #200 too.
- Manual run with the real program on 2026-09-27: two turns on one program, an abort during a foreground command that left the program alive, and a later turn on it that knew the first turn. The results are in `docs/reviews/2026-09-27-claude-connected.md`.

## Built in #194

A background task of the Claude program belongs to the program, not to the turn that started it. It outlives an abort and the end of its turn, and it ends with the program. The test "a background task survives an abort and is gone after the session ends" (`plugins/bundled`, tag `:real_claude`, excluded from `mix precommit`) runs the real `claude` with `haiku`: one turn starts a background command and a foreground command, `Session.abort/1` ends the turn, the foreground command is gone, the background command and the harness process stay, and after the session end the background command is gone. In 3 runs on 2026-09-27 (`claude` 2.1.283) the test passed. The program ended the background task on the end of input of the close, before the close bound and so before any TERM (research note, "Processes").

## Idle close

Owner decision on #195 (2026-09-29): one timer in the session.

- The session arms the timer when it holds a ready harness process with no turn and no wait (the wait of an abort, a failed turn, a close, or an idle close). Each arm has a new ref; the timer message carries it. A message whose ref is not the current one, or that arrives during a turn or a wait, is dropped. So the timer never sends a request while a turn, a prepare, or a request is open: each of them exists only inside a turn or a wait, and each end of a turn or a wait arms a new timer.
- When the timer fires, the session sends `:idle_close` with the close bound, 5,000 ms, as an armed kill, and waits as for a model switch: every message waits as a follow-up.
- `:ok`: the program exited, and the loop ends. The wait ends at the `:harness_down`, and the next turn starts a new program, which resumes.
- `:busy`: the program stays, the wait ends, and the session arms the timer again.
- Any other answer, or the bound, stops the harness process (see "Stop"), and the wait ends at its `:harness_down`.
- Claude Code: the program sends the whole set of its live background tasks in `background_tasks_changed` at each change (`claude-code-stream-json.md`, "Background tasks"). Only a `tasks` list that is exactly empty gives a close; a JSON line of this subtype with no list counts as a task until the next list. A line that is not JSON is dropped before the provider sees it (`Helyx.HarnessIO.lines/3`), so the set keeps its last value; the program writes each line whole. The initial set of a new program is empty. An `ambient` task counts as a task. The provider reads only this line: the program's schema calls it the level signal of the set, and the `task_started`, `task_updated`, and `task_notification` lines are its edges, so they add nothing to the set.
- Codex answers `:idle_close` as `:close` (built in #201) when no child thread has open work: no tool item outlives a turn, because a turn that ends with an open tool item stops the harness process. A child thread with open work answers `:busy` (#224, section "Built in #224"). Test: "an idle close after a turn ends the input and answers :ok at the exit".
- Known gap: a Claude background task that ends starts a program turn of its own (`claude-code-stream-json.md`, "Background tasks"). That turn is outside a Helyx turn, and an idle close can end it with end of input. A background task belongs to the program, not to a turn (#194).

## Built in #201

#201 built the Codex connected provider: the turn, the interrupt, and the close. The steer arrives with #202 and the Helyx tools with #203. The names in the code (`Helyx.Provider.Codex`):

- `harness_init/3` starts the program with open input and the 5,000 ms TERM grace, sends `initialize`, then `thread/resume` with the stored id and the trust overrides, or `thread/start`. A resume error with code -32600 and the exact message `no rollout found for thread id <id>` starts a fresh thread on the same program; any other resume error stops with `{:malformed, "thread/resume"}`. Any other error answer, the program's exit, or a line over the cap fails the connect. `initialize` does not ask for `experimentalApi` until #203.
- `stream/3` returns `{:error, :connected}`: Codex has no per-turn run.
- The first turn on a fresh thread emits `{:harness_session, thread_id, cut}` and sends the replay with `thread/inject_items`, then `turn/start`. A turn on a resumed thread sends `turn/start` at once.
- The `{:turn, ...}` reply `:ok` goes out at the `turn/start` answer, or at `turn/completed` when that comes first. An error answer to `turn/start` or `thread/inject_items` is the reply `{:error, {:codex, method, message}}`. The server sent the `turn/start` answer before `turn/started` in every run with codex 0.157.1.
- An interrupt of the current turn with an open `commandExecution` item answers `{:error, :command_running}` at once and writes nothing. An interrupt before the turn id is known waits and goes out when the id is known. An interrupt with no open command sends `turn/interrupt`, and the reply `:ok` goes out at `turn/completed` of the turn. An error answer to a sent `turn/interrupt` is the reply `{:error, reason}`. An interrupt of an ended turn answers `:ok` at once.
- A `turn/completed` while a `commandExecution` item is open stops the harness process with `:command_running`, whatever the status and whether or not an interrupt is pending: a command outlives its turn (#198), so the program must not serve the next turn. The turn, and a pending interrupt, get no reply and fail at the stop; the release TERMs the program, which ends its commands; a KILL after the grace leaves them, as in the Ownership table. From #224 an open tool item of any other type stops it too, with `:tool_running` (section "Built in #224").
- Closed in #224 (section "Built in #224"): a command of a sub-agent thread counts as the open work of its child thread, and an open tool item of another type at the turn's end stops the harness process.
- Closed hole, found in review round 13 (#234): an `item/started` of the running turn with the id of a tool item that has a tool call stops the harness process with `{:malformed, "item/started"}`, whether the item is open or completed. A tool item that completes with no start counts as started, so a later `item/started` of it stops the same way. The transcript holds each tool call once.
- A tool item leaves the open work (the open tool items, and the calls that wait for a result) only at an `item/completed` with its id and its type (#224) whose status ends it: `completed`, `failed`, or `declined` for a command and a file change; `completed` or `failed` for an MCP or dynamic tool call; `completed`, `failed`, or `interrupted` for a `collabAgentToolCall`; any string but `inProgress` for an `imageGeneration`. A type with no status in the schema ends at its `item/completed`. One function (`malformed/2`) checks every line that changes turn or thread state before any state changes: `turn/started` needs a string `turn.id`; `turn/completed` a string `turn.id` and the status `completed`, `failed`, or `interrupted`; `item/started` and `item/completed` a string `turnId`, item `type`, and item `id`, and a tool item's `item/completed` a status that ends it; an `item/started` of the running turn an id with no tool call yet; the answers to `thread/inject_items` and `turn/interrupt` a `result` object or an `error` object, and the answer to `turn/start` a string `result.turn.id` or an `error` object; an answer never has both, and a turn or item notification of any thread never has a request `id`. An answer counts only for the due request with its id: the `thread/resume` answer needs the asked thread id or the exact lost-thread error, and the `thread/start` result a string thread id. An answer with an id that is not due (late, duplicate, or never asked) is dropped, so it never answers a later request or changes the thread. Any other such line stops the harness process with `{:malformed, method}`: a missing or unknown status would clear the turn or its open work while the work can still run. A `turn/started`, `turn/completed`, `item/started`, or `item/completed` with no string `threadId` stops the harness process with `{:malformed, method}`: the schema requires the field, and the line can belong to this thread (#224). Any other line with no `threadId` is dropped with the lines of other threads.
- An `item/` notification with another turn id than the running one stops the harness process with `:item_of_ended_turn`, and a `turn/started` that Helyx did not ask for stops it with `:turn_not_asked`, at any time, not only after an interrupt: the program runs one turn of its thread at a time, so such a line is a protocol fault.
- A line over 16 MiB, the held events over 10,000, and the program's exit stop the harness process with `{:line_over_limit, 16777216}`, `{:held_over_limit, 10000}`, and `{:codex_exit, status}`; the held events and the events of that chunk are dropped. A port `:DOWN` (for example `:epipe`) stops it with `{:codex_exit, reason}`.
- The close ends the program's input and replies `:ok` at the program's exit, inside the 5,000 ms close bound. The idle close (`:idle_close`) does the same (see "Idle close").
- A command or file change approval request is answered `accept`. Every other server request gets the error `-32601`. stderr is dropped, as before.
- Each request gets a new integer id from 1 up, and `due` maps the id of each request without an answer to its method, so each answer belongs to one request. A `turn/interrupt` goes out only when no `turn/interrupt` answer is due, and a `turn/start` only when no `turn/start` or `thread/inject_items` answer is due. A turn waits with its prompt, and an interrupt waits as pending, until that answer comes.
- The server does not state the order of the `turn/start` answer and the turn's notifications, so the provider does not depend on it. Events of the turn can go out before the `:ok` reply, as "Turn states" allows. A `turn/completed` that comes before the answer ends the turn at once: the reply `:ok` goes out first, then the held events and the terminal. The late `turn/start` or `turn/interrupt` answer then belongs to no turn: it clears its id from `due` and is dropped when it has its full shape, and it stops the harness process when it does not. An answer with an id that is not due is dropped. A `turn/started` with a new id counts only while the turn's own `turn/start` is open. Accepted hole: a `turn/started` that comes after the `turn/completed` of its own turn, against the order in the research note, is taken as the next turn when it comes while that turn's `turn/start` is open; the turn can then end on the old turn's lines, and the harness process stops at the next line of the real turn (`:turn_not_asked` or `:item_of_ended_turn`). Closing it needs the ids of ended turns. A `turn/completed` of a turn whose id is not known (not started, or already ended) stops the harness process with `:turn_not_asked`: the turn then gets no reply and no terminal, and fails at the stop.
- The manual run with the real program is in `docs/reviews/2026-09-27-201-codex-connected.md`.
- The owner decision on #201 ("stop the program when a command of the turn is open; interrupt otherwise") replaces the ticket's line "an abort during a command leaves the program alive": an abort during a command stops the program, and the next turn starts a new one that resumes the thread. The rule holds at every end of a turn with an open command, not only at an abort.

## Built in #202

#202 built the steer on a connected turn. The names in the code:

- The session sends `{:steer, turn_id, steer_id, text}` only in `submitted`, with a new `steer_id` and the 2,000 ms steer bound. In `preparing` and `submitting` the steer stays in the local queue; at the `{:turn, ...}` answer `:ok` the session sends the local steers, in order. The turn keeps each sent steer (`steers` in `Helyx.Session.Turn`) until its `user_message`.
- The sent steers count in the 32 steers (`Helyx.Session.Queues`, `held`). Over that, the client gets `{:error, :queue_full}`.
- The loop answers a request over 8 open requests with `{:error, :busy}` and does not give it to the provider. For a steer this is an unknown answer. For a turn or an interrupt the loop then ends itself.
- An error answer to a steer does not end the loop: the steer is unknown, and the turn goes on.
- At a normal end, the session waits for the answers of the steers that have none, so a late `:rejected` still queues the steer for the next turn. Each steer with `:ok` or an unknown answer and no `user_message` gets the event `:steer_unconfirmed` with its text. An abort or a failure gives this event for every sent steer with no `user_message`, one with no answer included. The TUI shows it as a notice.
- No turn starts while a steer request is open, because its armed kill could end that turn. At every end of a turn (normal, abort, failure), each steer with no answer goes to the wait after the turn. The wait ends when each of these steers has its answer, or at the `:harness_down`. After an abort or a failure the steer has its notice already, so a late `:rejected` does not queue it again. An abort in the wait after a normal end does the same for the steers that wait there. A failure at the `:harness_down` leaves no request open.
- A steer that the harness takes before its answer gets no notice; its request stays open as above.
- A `:rejected` answer during the turn queues the steer for the next turn, while a later steer can still go to the running turn. The order of the two then changes. Accepted: today only a steer that crosses the end of the turn is rejected, and every later steer is then rejected too.
- The session appends its own text of the steer, the text it checked at the client call, not the text of the event. A `user_message` with an unknown `steer_id` is dropped.
- Claude Code: after a lost-session relaunch the steers of the turn are dropped, not written again; the session gives each a notice. While the turn is held for an unresolved steer, the `result` that the provider held is not the terminal. An error `result` goes out as a notice at the start of the steer (#241).
- Codex: the answer to `turn/steer` can come after `turn/completed`, so the provider keeps the open steer requests past the turn's end. A `user_message` waits, as a `message_end` does, until the results of the sent calls are out.

## Built in #224

Owner decision on #224 (2026-09-29), after the research of #226 (`claude-code-stream-json.md` and `codex-app-server.md`, sections "Sub-agents at the end of a turn"): sync work ends inside its turn, and background work belongs to the program.

Claude Code:

- Sync work: the interrupt with `cancel_queued: true` ends a foreground sub-agent, and the turn's `result` comes after it with `terminal_reason` `aborted_tools` (research note, 1 run). So the abort of #200 needs no change.
- Background work: the program sends `background_tasks_changed` for a background sub-agent (research note, "Sub-agents at the end of a turn"), and the program's schema describes that line as the full set of live background tasks, also "a foreground agent being backgrounded" (research note, "Background tasks"). So a background sub-agent is a background task of #194, and the idle close answers `:busy` while it runs. No code change. That the sub-agent is an entry of the `tasks` list is inferred from the schema text; the research note does not print the list.
- A sub-agent writes no `result` line, and its own lines carry `parent_tool_use_id`, which the provider drops. So no sub-agent line ends a turn or makes an event.
- Accepted, program behaviour: in one research run, an interrupt sent while the program was idle ended a running background sub-agent. It is inferred from this run that an abort can also end background work of an earlier turn. Helyx does not prevent this.

Codex (`Helyx.Provider.Codex`):

- A `subAgentActivity` item on the program's own thread (`item/started` or `item/completed`) changes the set `agents`: the child threads with open work, each with a program turn id. This set belongs to the program, not to a turn: it stays after the turn's end. The kind `completed` removes the child thread (`agentThreadId`). Every other kind (`started`, `interacted`, `interrupted`) adds an unknown child with the item's turn id, and sets the turn of a known child only when the item has the running turn's id (#244; a late item with an older turn id was not observed in the research, so this rule guards an inferred case). So a late item with an older or unknown turn id never moves a child away from its turn, and an abort of that turn still stops the program. An item with the running turn's id, such as `interacted` in a later turn, moves the child to the running turn. Only `completed` confirms that the work ended: after `turn/interrupt` of a child turn, its command ran on, and no `completed` came (research note).
- An `item/completed` of the running turn with the id of an open tool item of another type stops the harness process with `{:malformed, "item/completed"}`: it would clear the open item while it runs (Codex review, round 1).
- A `subAgentActivity` item needs a string `agentThreadId` and a `kind` of the schema of codex 0.157.1 (`started`, `interacted`, `interrupted`, `completed`); any other shape stops the harness process with `{:malformed, method}`, in the one check of `malformed/2`. The schema requires `agentThreadId` for every kind (`generate-json-schema`, 0.157.1, 2026-09-29).
- A `subAgentActivity` item can come with the turn id of any turn: the `completed` item comes with the turn id of the turn that spawned the child, also after that turn ended (research note). So it never stops the harness process with `:item_of_ended_turn`, and it makes no event.
- The lines of a child thread are still dropped. A command of a child thread is open work of its child thread, until the `completed` item.
- Sync work, at an abort: an interrupt while a command of the turn is open answers `{:error, :command_running}` at once, as before. An interrupt while a child thread of the turn has open work answers `{:error, :agent_running}` at once. Both write nothing, and the abort stops the program; on TERM the program ends the child's commands (research note). A `turn/completed` while an interrupt waits and a child thread of the turn has open work stops the harness process with `:agent_running` too. This covers a child that starts after the interrupt, and an interrupt that waited for the turn id or for the answer to an earlier interrupt. Such an interrupt goes out with no new check; an open command or child at the turn end then stops the harness process, and the interrupt deadline bounds the wait.
- Sync work, at every end of a turn: a `turn/completed` while a tool item of the turn is open stops the harness process, with `:command_running` for a command and `:tool_running` for any other type, such as the `wait` `collabAgentToolCall`, which got no `item/completed` after `turn/interrupt` (research note). A late `item/completed` of such an item thus never reaches a later turn.
- Background work: at a normal end of a turn with no interrupt, a child thread with open work stays with the program. The idle close answers `:busy` while `agents` is not empty, and the session arms the timer again.
- A `turn/completed` with no string `threadId` stops the harness process with `{:malformed, "turn/completed"}`: the provider cannot tell whether it ends the running turn. The same holds for `turn/started`, `item/started`, and `item/completed`: the schema of codex 0.157.1 requires `threadId` in all four.
- Accepted holes (owner decision on #224, 2026-09-29: accepted as documented, no follow-up tickets). Each needs a program behaviour that the research did not see, and the session end bounds each one:
  - A child thread whose `completed` item never comes (for example after the model interrupts it) stays in `agents`. The idle close then answers `:busy` until the session ends, and an abort of its turn stops the program.
  - A sub-agent of a sub-agent: its `subAgentActivity` lines are on the child thread, which the provider drops, and the parent's `completed` item confirms only the end of the child's turn (its id is `subagent-completed-<child turn id>`). So the child leaves `agents` while its own child can still run. A later abort then interrupts the turn and does not stop the program, and an idle close ends the program with end of input. Not run in the research ("Not run").
  - When `interacted` comes while an earlier child turn runs, the `completed` item of that earlier turn removes the child. Its new work can still run (`send_input` was not run in the research). A later abort then interrupts the turn and does not stop the program.
- With the steer of #202: a turn end that these rules stop (`:command_running`, `:tool_running`, `:agent_running`) stops the harness process while a `turn/steer` answer can still be open. That steer gets no answer and fails at the `:harness_down`, so the session gives it the `:steer_unconfirmed` notice and never sends it again, as for any stop (section "Built in #202"). A steer that got `:ok` but whose `userMessage` item is held behind the open tool item loses that item at the stop, so the session gives the `:steer_unconfirmed` notice for a steer that the program took. It is never sent again. A steer's `userMessage` item is not a tool item, so it never clears or keeps open work.
- The turn that the program starts by itself at the end of background work is out of scope: ticket #240.

## Built in #203

#203 built the shared path of the Helyx tool calls and the Claude Code part. Codex (#243) uses the shared path as it is, and follows the one provider rule of #203: a call id that the provider answers itself is recorded first. The names in the code:

- **The loop owns the tool rules** (`Helyx.Session.Harness`). A turn is live from its `{:turn, ...}` request until its terminal or its `{:interrupt, ...}` request. The loop keeps the call ids of the live turn's open tool requests. A pair `{turn_id, call_id}` is open when the turn is live and the id is kept.
- The loop answers a tool request itself, through the provider's `{:tool_result, ...}` request with no armed kill, in these cases: the turn is not live (`aborted`); 17 requests of the turn are open (one runs and 16 wait); and at the terminal, at the interrupt before the provider sees it, and at the next turn, each open request gets `aborted`. A provider replies `:ok` to such a request inside the same callback, so the result is written before the next request reaches it; a missing reply stops the harness process. The reply does not go to the session. The session's own `{:tool_result, ...}` requests follow the same rule, so no result is pending when an interrupt reaches the provider, and a `tool_result` request never counts in the 8 open requests.
- A `{:tool_result, ...}` request from the session whose pair is not open is answered `:ok` by the loop and does not reach the provider. A `{:cancel_tool, ...}` action closes its pair: a waiting request leaves the loop's queue; the running request goes to the session as the action only after the `:ok` to its start ask, and before the `:ok` the loop keeps it until the ask gets `:dropped` (see "The start ask"). For a pair that is not open it does nothing. A second request with the call id of an open pair is a bad action and stops the harness process. The loop records the call id of every request of the live turn before any check that answers it. A request with a call id that the live turn used before, and that is no longer open (withdrawn, answered, or rejected by the loop, for example over the limit), gets the error result "the call id was used before in this turn". So a call id gets one answer, and an id that got any answer never runs later in the turn; the result of a withdrawn run could otherwise answer the new request.
- **The loop owns the waiting queue.** It sends the session one `{:tool_request, ...}` event at a time: the next waiting request goes to the session only when the result of the running request came, also the result of a withdrawn run. So the session holds only the running request.
- **The start ask.** A request that the loop sent can still be in the session mailbox when the loop answers it `aborted` at the terminal. So the session asks `{:tool_start, turn_id, call_id}` before it runs the tool, and runs it only on the answer `:ok`. The loop answers `:ok` only for the open running request, and marks it started. Any other answer is `:dropped`, and the session drops the request. So a call gets exactly one answer, and a call that got any answer from the loop never starts. An `:ok` and an answer of the loop exclude each other: the loop handles one message at a time. After the `:ok`, only the result of the run answers the call: the terminal, the interrupt, and the next turn skip it. The `stream_end` still goes to the session at once, so the turn end does not wait. At every end of a connected turn with a Helyx tool, the session sends `{:tool_result, turn_id, call_id, {:error, "aborted"}}`, the result of the killed run, when the hands answer the turn cleanup. So the order is the old one: the kill, then the answer, then the interrupt. The request waits in the wait after the turn, as an open steer request does, so the next turn starts only after the answer. The loop writes it for a started call also after its turn, and the program's `tools/call`, still open, gets it; the Claude provider keeps its open calls by call id across turns. For a call that the loop already answered, or that the harness withdrew, the loop drops it. The bound of this late answer is the kill wait of the hands (their release deadlines, up to 20,000 ms), then the tool result bound, 2,000 ms. `end_tools` skips a started call; the skip acts at the terminal. At the interrupt and the next turn the session's result came first, so no call is started there; the skip stays because one `end_tools` serves all three ends. A request withdrawn before the ask stays running in the loop until the ask; the ask gets `:dropped`, and the next waiting request goes to the session. A request withdrawn after the `:ok` goes to the session as `{:cancel_tool, ...}`, also after the end of its turn, and the next one goes when the result of its killed run comes; that result is dropped.
- The event `{:tool_request, call_id, name, args}` passes the check of a tool call (`Helyx.Session.Stream.check/2`): an integer over the digit limit gives a rejection, and the session answers `tool call not run: ...` with no run.
- **The session** runs the request that the loop sent on the hands (`tool` in `Helyx.Session.Turn`). It sends each result with the 2,000 ms tool result bound (`harness_ms.tool_result`) and keeps the `from` in `results` until the answer. At every end of the turn, an open `from` goes to the wait after the turn, as an open steer request does, so no turn starts while its kill is armed. A `{:cancel_tool, ...}` kills the running tool with `Hands.kill/3`, a cast; the hands release it and send its result, which the loop drops and which starts the next waiting request.
- A normal end with a running request asks the hands for the turn cleanup, step 1, and the next turn waits for it. An abort and a crash of the harness process already run it: the tool Tasks are Tasks of the turn.
- The session emits no `tool_execution_start` for a tool request: the harness's own events show the call.
- **Claude Code.** The program gets `--mcp-config {"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}}` and no `--strict-mcp-config`, so the user's own MCP servers stay (owner decision 3). The shapes are in `claude-code-stream-json.md`, "The SDK MCP server shapes". Each `initialize` gets the same result, because the program can send it again. A notification gets the ack `{"jsonrpc":"2.0","result":{}}`, which the program needs. A request of another method gets the JSON-RPC error -32601 (source only). An `initialize` echoes a string `params.protocolVersion`; without one it gets the result with protocol version `2025-11-25`, and a `tools/call` without `params` gets an error result.
- A `tools/call` gives the tool request when its `_meta["claudecode/toolUseId"]` is a string, its name is a string, its arguments are an object or absent, its id was not used in the provider's turn, and a Helyx turn runs. Otherwise it gets an error result (`isError: true`) at once, and nothing runs. The provider records the call id in its turn before any check that answers it, so an id that it rejected (for example with arguments that are not an object) gets "the call id was used before in this turn" later and never runs; the loop never sees such an id. A result is written as `{"content":[{"type":"text",...}],"isError":...}`.
- `notifications/cancelled` for an open call, and `control_cancel_request` for its control request, give `{:cancel_tool, ...}`. A `control_cancel_request` gets no answer (source only).
- #224 turn-end rules are not changed. The order at the end of a turn is the same, and the Codex tool items are not affected: a Codex `turn/completed` with an open tool item still stops the harness process, so a started Helyx call of that turn gets no late answer; the program is gone.
- Accepted holes:
  - A `tools/call` of a sub-agent runs, but its `tool_use` line has a `parent_tool_use_id`, so the transcript does not show it: the provider drops sub-agent lines (#224).
  - Two identical `tools/call` lines with the same control `request_id` and the same JSON-RPC id: a program that sends one control request id twice. The provider does not detect it (owner decision).
  - A `tools/call` in a program turn outside a Helyx turn, such as the turn that a finished background task starts, gets the error "no Helyx turn is running".
  - Doc gap: the numbered steps of "Abort" (step 3) and of "Turn cleanup" (step 2) say that the harness process answers every open tool request of the turn `aborted`. A call that got `:ok` at its start ask is not in that answer. The session sends its `aborted` result after the hands answer the cleanup and before the interrupt (between abort steps 2 and 4), and the steps do not show it. The bullets above, "The loop owns the waiting queue" and "The start ask", and the Bounds table give the correct order. Reproduction: read abort step 3 against the `progress/1` clause for `Wait.tool` in `Helyx.Session.Server`. Accepted: the last review round (round 4) found it, and the owner decided to merge with the rest recorded as known gaps.
  - Doc gap: "Normal end" says that the session starts no turn until the hands answer. The next turn also waits for the answer to the late `aborted` result of a started call (its `from` is in the wait). Only this section states it. Reproduction: the test "a next turn waits for the answer of the call whose ask was open at the abort". Accepted for the same reason.
  - Order dependency: `end_tools` at `{:turn, ...}` does not clear `started`. A stale pair could remove a call id of the new turn from `calls` if the program used the same id again. No path reaches it today, because the next turn waits for the late result, which clears `started`. Accepted for the same reason; a change to that wait must clear `started` at the next turn.

## Built in #246

A program turn is a turn that `claude` starts by itself, for example when a background task ends. It has no `command_lifecycle` line, and its `result` has `origin` and a null `user_message_uuid` (`claude-code-stream-json.md`, "Program turns"). A Helyx user line written during a program turn is queued, and starts 1 ms after the program turn's `result` (1 run). Before #246, the lines and the `result` of the program turn counted for the Helyx turn, so the Helyx turn ended with the program's answer, and the real answer was dropped.

- **Invariant.** The lines and the `result` of a Helyx turn count only after `command_lifecycle` `started` of its own `uuid`, for every turn (the guard `started?/1`: the turn's `messages` are nil from the start on). Before it, a model line is dropped, as between turns; a `result` is skipped when an earlier `init` listed `msg_lifecycle_v1`, and stops the program with `{:error, :no_msg_lifecycle}` otherwise; a `tools/call` gets the error "no Helyx turn is running". The replay skip of #200 is the same rule. `started` came before every model line of a normal turn in 3 runs (research note).
- The entry points are `translate/2` (the result clause and the drop clause) and the `tools/call` clause of `mcp/3`. The boundary is the program's stdout. The lost-session `result` of a resumed program is checked first: it comes before any `init` and before `started`.
- No new buffer or wait. The program turn is dropped; showing it is #240.
- Tests (`plugins/bundled`): "a prompt during a program turn gets its own answer, not the program's", a fake program that writes the observed order of the lines of the program turn and of the queued line, plus a Helyx tool call inside the program turn, which the research did not see; and "a result before the start to a program without msg_lifecycle_v1 stops it".
- Accepted holes, each needs a program behaviour that the research did not see:
  - An interrupt during a program turn was not run. When the control response does not name the turn's line in `cancelled`, the interrupt waits for a `result` of the turn that does not come, and the interrupt bound stops the program. It fails safe.
  - A program turn that starts while a Helyx turn is held for an unresolved steer (after `started` of the turn's line) counts for the Helyx turn. The research saw a queued user line start right after a `result`, not a background task that ends in that window.
  - The `started` clause of a steer does not check the start of the turn's line. A steer written before that start, for example during a program turn, whose `started` comes before the `started` of the turn's line gives `{:user_message, ...}` while the turn's lines are still dropped. The program queue took the lines in order in every run, so the turn's line starts first.
  - A result with `is_error` true that comes before any `init` and before `started`, other than the lost session, stops the program with `{:error, :no_msg_lifecycle}`: the turn fails, but without the program's error text. Before #246 the turn got that text. The research saw no such result; it fails safe. Reproduction: a fresh program whose first line is an error `result`.

## Built in #241

#241 added the provider stream event `{:notice, text}` (owner decision: one generic event, which Codex #243 uses too). The names in the code:

- **Entry points.** A notice enters Core only through `Helyx.Session.Stream.check/2`: the stream Task of a turn and the harness loop (`{:event, turn_id, {:notice, text}}`) both call it. It passes from any turn, local or external.
- **Bound.** `text` is valid UTF-8 of at most 2,000 bytes, the bound of `HarnessIO.cap_error/1`. A text over the bound, not valid UTF-8, or not a binary is a malformed event (`{:bad_stream_event, event}`): it fails a stream turn and stops the harness process, as every malformed event does.
- **The session** emits the event `:notice` with `%{text: text}` and the turn id. The notice joins no message, so the transcript, the session file, and the replay to the model never hold it. A notice of a turn that is not running is dropped, as every stream event of such a turn is.
- **The TUI** shows the text as a notice cell. The render path drops control characters and wraps the text to the width (`styled_lines/3` in `Helyx.TUI`), and the 2,000-byte bound of the session holds there. A notice is client-local after that: a second client's snapshot does not show it, as for every notice.
- **Claude Code.** A `result` that the turn holds for an unresolved steer is kept as `held` in the provider's `Turn`: the text `subtype: errors` of an error `result`, or nil for a success. At the start of a steer the provider sends `{:notice, "the turn before the steer failed: " <> held}`, cut with `HarnessIO.cap_error/1`, after the `message_end` and before the `user_message`. A later held `result` of a Helyx line (the turn's or a steer's) replaces `held`. The `result` of a program turn (`origin.kind` `task-notification`, research note "Program turns") never changes `held`, so a program turn's error never becomes the notice and never clears a held error.
- Accepted holes:
  - An interrupt of a held turn answers `:ok` and the turn ends aborted with no notice: the held error is lost. The user asked to stop the turn. Reproduction: change the test "an interrupt of a held turn answers :ok at the control response" to hold an error `result` (`failed/1`) in place of `result("a")`; no `notice` event comes.
  - When no steer starts within the steer wait, the harness process stops with `:steer_not_started`, and the held error is lost; the turn fails with the stop. Reproduction: change the test "with no start after a held result stops the harness process" to hold an error `result` (`failed/1`); the actions end with the stop and hold no `notice` event.
  - An exit of the program while the turn waits for the steer's start stops the harness process with `{:claude_code_exit, status}`, and the held error is lost. Reproduction: a scripted turn that holds an error `result` (`failed/1`) and then exits with status 3 gives only `{:stop, {:claude_code_exit, 3}}`, with no `notice` event. A stop sends no events.
  - Only the exact `origin` `{"kind": "task-notification"}` marks a program turn's `result`. A program `result` with another `origin` (another `kind`, a `kind` that is not a string, or `null`) counts as a Helyx `result`: its error becomes the held error, and its success clears a held error. The research saw only `task-notification` on a program turn's `result`, and `origin` `null` with `user_message_uuid` equal to the line's `uuid` on a Helyx line's `result`. Closing it needs a match on `user_message_uuid` against the turn's and the started steers' `uuid`s. Reproduction: the test "a program turn's error result after a held success gives no notice" with `origin` `%{kind: "scheduled-task"}` or `nil` gives the notice.
  - Two held `result` lines before one steer start keep only the last one. The research did not see a second `result` before a steer's start.

## Out of scope

- Approvals in the UI. The request path is built, and the answer stays `accept` (#192, decision 5).
- Showing the Claude background tasks in the TUI (#194).
- `thread/fork`, `thread/revert`, `rewind_files`, and branching.
- Compaction inside the harness (`thread/compact/start`).
- The model switch inside one program (`set_model`, the `turn/start` overrides). A switch closes the program, as today.
- The known gap of a result after an abort (`docs/features/external-turn.md`).
- Flow control between a provider stream and the session mailbox. #197 chose a cap on the queue length, over which the turn fails.
