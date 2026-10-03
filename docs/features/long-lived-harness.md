# Long-lived harness

One harness program serves the provider process of a session, not one turn: `claude` for `Helyx.Provider.ClaudeCode` and `codex app-server` for `Helyx.Provider.Codex`. Both share `Helyx.HarnessIO`. This doc gives what the harness plugins own: the program lifecycle, the idle close answer, the replay, and the plugin bounds. The Core turn contract (turn states, turn end, deadlines, steer, provider death) is in `docs/features/session-lifecycle.md`, and the provider protocol in `docs/features/one-provider-path.md`.

The protocol facts are in `docs/research/claude-code-stream-json.md` and `docs/research/codex-app-server.md`.

## Program lifecycle

- **Start.** `init/3` finds the program on `PATH` (`HarnessIO.find/1`) and starts it in the session's working directory, in its own process group under `Helyx.Watchdog`, with open input. The provider process holds the groups with `Helyx.Tool.hold/1`, and the hands release them with `release/3` (ADR 0004). The program has the trust of the bash tool: Claude runs with `--permission-mode bypassPermissions`, and Codex threads run with the approval policy `never` and the sandbox `danger-full-access`.
- **Close.** `:close` ends the program's input (`HarnessIO.close/2`) and answers `:ok` at the exit. A program exit at any other time stops the provider process.
- **Stop.** Any stop of the provider process closes its port. The watchdog sends TERM to the program group, waits the TERM grace, and sends KILL. A stop never sends end of input first: Claude runs its queued turns after end of input, and a stop must not run them.
- **Idle close.** `:idle_close` closes as `:close` when the program has no work of its own, and answers `:busy` otherwise; the program then stays. Claude has work of its own while the `tasks` list of the last `background_tasks_changed` line is not exactly `[]`, while a program turn runs, and once after a `task_notification` line. Codex has work of its own while a child thread has open work.
- **Background work.** A Claude background `Bash` task, and a Codex child thread with open work after a normal turn end, belong to the program, not to a turn. They outlive the turn end and end with the program. A Claude background task also outlives an abort; an interrupt ends every Claude sub-agent.
- **Errors.** stderr is dropped: the Claude `result` line and the Codex error answers carry the errors.

## Claude Code

- The program runs as `claude --output-format stream-json --verbose --include-partial-messages --input-format stream-json --permission-mode bypassPermissions --model=<model> --session-id=<uuid> --mcp-config <helyx server>`, with no `-p`. A resume passes `--resume=<id>` in place of `--session-id`. The model ref is `claude-code/<model>`, where `<model>` is what `claude --model` takes.
- **Capabilities.** Each `init` line must list `interrupt_cancel_queued_v1` and `msg_lifecycle_v1`. An `init` without both stops the provider process with `{:missing_capabilities, missing}`.
- **Turn.** A turn is one user line with a `uuid`, answered `:ok` at the write. The lines and the `result` of a turn count only after `command_lifecycle` `started` of its `uuid`; the provider drops the lines before it, such as those of a replay. The turn ends at a `result` with `queued_turn_count` 0 and no unresolved steer. A `result` with `queued_turn_count` above 0 does not end the turn. A missing `queued_turn_count`, or one that is not a non-negative integer, stops the provider process with `:no_queued_turn_count`.
- **Steer.** A steer is a user line with a `uuid` of its own, which the provider maps to the `steer_id`. After the terminal of the turn, the provider answers `:rejected` and writes nothing. Otherwise the write answers `:ok`, and the steer is unresolved until `command_lifecycle` `started` of its `uuid`, which gives `{:user_message, steer_id}`. A `result` with `queued_turn_count` 0 while a steer is unresolved gives no event: the provider waits for the steer's `started`, then for the next such `result`. Over the steer wait, the provider process stops with `:steer_not_started`. After a lost-session relaunch the steers of the turn are dropped, not written again.
- **Interrupt.** The control request `interrupt` with `cancel_queued: true`. It waits for the first `init` line, and after a replay for `started` of the turn's line. A success response whose `still_queued` is not exactly `[]` answers `{:error, :still_queued}`. Otherwise the answer is `:ok` after the success response and the turn's `result` (any `terminal_reason`), or after a success response whose `cancelled` list holds the turn's `uuid`. A turn that already ended answers `:ok`, and nothing is written.
- **Program turns.** An `init` line with no Helyx turn starts a program turn: the provider makes a UUID as its turn id and gives `{:event, id, :turn_start}`. A steer and an interrupt of it work as for any turn. A `{:turn, ...}` while a program turn runs replaces it: the program runs the new line after the program turn, and the rest of the program turn is dropped.
- **Lost session.** A resumed program that no longer has the session writes one `result` with the lost text before any `init`, and exits. The provider starts a fresh program with a new id, and a turn that was already written goes to it with the replay. A close during that waits for the lost program's exit.
- **Helyx tools.** An SDK MCP server named `helyx`, next to the program's own tools and the user's MCP servers; the model sees each tool as `mcp__helyx__<name>`. A `tools/call` gives `{:tool_request, id, name, arguments}` when its `_meta["claudecode/toolUseId"]` is a string, its name is a string, its arguments are an object or absent, and a turn is started (a Helyx turn after its `started`, or a program turn). Any other call gets the error result `the call does not map to a tool use` at once. `notifications/cancelled` for an open call gives `{:cancel_tool, call_id}`. `initialize` gets a result that echoes `params.protocolVersion`, and `tools/list` gets the Helyx tool specs. A notification gets the ack `{"jsonrpc":"2.0","result":{}}`, and a request of another method gets the JSON-RPC error -32601.
- **Control requests.** `can_use_tool` is allowed with its input unchanged; any other control request gets an error answer. An unknown line, `control_cancel_request` included, is ignored.
- **Output.** Text and thinking stream as deltas. Tool calls and results arrive whole. The provider sends no `message_end`: the session closes the message.

## Codex

- The program runs as `codex app-server`. The model ref is `codex/<model>`.
- **Connect.** `initialize` (with `experimentalApi` when the session has Helyx tools), then `thread/resume` with the stored id and the trust overrides, or `thread/start` (with the Helyx tools as `dynamicTools`). A resume error with code -32600 and the exact message `no rollout found for thread id <id>` starts a fresh thread on the same program. Any other resume error fails the connect with `{:malformed, "thread/resume"}`. An error answer to `initialize` or `thread/start` fails the connect with the program's error.
- **Thread id.** The stored id is the thread id, and when the thread has Helyx tools, `#` and the first 16 hex digits (`@digest_hex` in `Helyx.Provider.Codex.Tools`) of the SHA-256 of the JSON of its `dynamicTools`. A stored id whose digest is not the one of the session's tools starts a new thread with the replay.
- **Turn.** `turn/start` with the prompt; `:ok` at its answer, which carries the program's turn id. An error answer to `turn/start` or `thread/inject_items` is the reply `{:error, {:codex, method, message}}`, and the provider process stops.
- **Steer.** `turn/steer` with `expectedTurnId` equal to the running program turn id and `clientUserMessageId` equal to the `steer_id`. After `turn/completed` the provider answers `:rejected` and sends nothing. A success answer gives `:ok`. The exact error `no active turn to steer` with code -32600 gives `:rejected`; any other error gives `{:error, reason}`. The `item/started` of a `userMessage` item of the running turn with a string `clientId` gives `{:user_message, clientId}`.
- **Interrupt.** With an open `commandExecution` item of the turn, `{:error, :command_running}` at once; with a child thread of the turn that has open work, `{:error, :agent_running}`. Both write nothing, and Core then stops the program. Otherwise `turn/interrupt`, sent when the turn id is known and answered at `turn/completed`, or with its error answer. An interrupt of an ended turn answers `:ok`.
- **Open work at a turn end.** A `turn/completed` with an open tool item stops the provider process with `:command_running` for a command and `:tool_running` for another type: `turn/interrupt` does not stop a running command, and its late `item/completed` must not reach the next turn. A `turn/completed` while an interrupt waits and a child thread of the turn has open work stops it with `:agent_running`.
- **Child threads.** A `subAgentActivity` item on the program's own thread changes `agents`: kind `completed` removes the child (any turn id); any other kind moves it to the running turn. The notifications of a child thread are dropped. A server request of any thread gets its answer as below, and an `item/tool/call` of a child thread does not map.
- **Unasked turns.** A `turn/started` whose id is not the one of the `turn/start` answer, or a `turn/completed` of an unknown turn, stops the provider process with `:turn_not_asked`. An item of another turn stops it with `:item_of_ended_turn`.
- **Line check.** `Helyx.Provider.Codex.Check.malformed/2` checks the full shape of every line that changes turn or thread state before any state changes. Any other shape, and a turn or item line with no string `threadId`, stops the provider process with `{:malformed, method}`; in the connect, the connect fails with it.
- **Request ids.** Each request has a new integer id; `due` maps each id without an answer to its method. An answer with an id that is not due is dropped. The turn end settles a sent `turn/interrupt`.
- **Helyx tools.** An `item/tool/call` of the running turn whose `callId` is an open `dynamicToolCall` item, with a string `tool` and object `arguments`, gives `{:tool_request, call_id, tool, arguments}`. Any other call gets `the call does not map to a tool use` at once. A result goes back as one `inputText` content item with `success`.
- **Server requests.** A command or file change approval request is answered `accept`; every other request gets the JSON-RPC error -32601.
- **Output.** Text and reasoning stream as deltas. A tool item is a tool call when it starts and a tool result when it completes. The provider sends no `message_end`.

## Replay

A fresh harness session (no resume id, a lost session, or a changed Codex tool set) gets the rest of the transcript before the first turn's prompt, and the turn gives `{:resume, id, cut}` with the number of messages left out. The prompt is the user messages at the end of the context. The replay keeps the newest messages within `@replay_max_bytes` of `Helyx.HarnessIO` and never starts at a tool result.

- Claude Code writes the replay as lines that start no model call (`shouldQuery: false`), in chunks. Each chunk ends at a replayed user line, and the next chunk goes out at that line's `result` with `num_turns` 0. So the model gets the transcript in its order. A steer while chunks are held goes after the turn's line.
- Codex sends the replay with `thread/inject_items`, then `turn/start`.

## Bounds

| What | Bound | Over the bound | Owner |
| --- | --- | --- | --- |
| stdout line | 16 MiB (`@line_max_bytes` in `Helyx.HarnessIO`) | the provider process stops | provider |
| bytes written to the program and not yet read | 16 MiB (`@stdin_max_bytes` in `Helyx.Watchdog`) | the watchdog stops the program group and exits with a status; the provider process stops on that exit | watchdog |
| TERM grace | 5,000 ms (`@term_grace_ms` in `Helyx.HarnessIO`) | KILL. The program's own command groups can stay after a KILL | watchdog |
| replay | 400,000 bytes (`@replay_max_bytes` in `Helyx.HarnessIO`) | the oldest messages are left out; `cut` counts them | provider |
| replay: tool call id | 1 to 64 characters of `[a-zA-Z0-9_-]` (`Helyx.HarnessIO.wire_id/1`) | the id becomes `h_` and 62 hex digits of its SHA-256 | provider |
| Codex replay: tool name | `[a-zA-Z0-9_-]`, at most 64 bytes (`tool_name/1` in `Helyx.Provider.Codex.Replay`) | each other character becomes `_`, then the name is cut to 64 bytes; an empty name becomes `_` | provider |
| Claude: wait for `started` of an unresolved steer after a `result` with `queued_turn_count` 0 | 5,000 ms (`@steer_wait_ms` in `Helyx.Provider.ClaudeCode`) | the provider process stops with `:steer_not_started` | provider |
| Claude: wait for `started` of the turn's line, and for each replay chunk's `result` | unbounded, accepted | an abort; the interrupt has its armed kill | Core |
| Codex: open `item/tool/call` requests | one per call that gave a `{:tool_request, ...}`, removed at its `{:tool_result, ...}`; Core answers every request once | not needed: Core answers each request once | provider |
| Codex: child threads with open work (`agents`) | one entry per child thread, until a `subAgentActivity` item of kind `completed` | unbounded, accepted; see "Current limits" | provider |
| Codex: thread id from `thread/start` | 1 to 239 bytes of valid UTF-8, so a stored id with its digest passes `Helyx.Message.resume_id?/1` | the connect fails with `{:malformed, "thread/start"}` | provider |
| harness life | the session; the idle close after the idle time; unbounded while the program has work of its own | the idle close | Core |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| --- | --- | --- | --- | --- | --- |
| program port, watchdog, program group | `Helyx.Watchdog.start/4` in `init/3`, or in a Claude relaunch after a lost session | provider process (the linked port), hands (the handles), and watchdog (the life) | close: end of input, the exit, then `release/3` | the closed port ends the watchdog's stdin: TERM, grace, KILL | kept after an interrupt `:ok`, and on an abort in `preparing` (no interrupt goes out); otherwise as a crash, with no end of input |
| the program's own command groups | the program | the program | the program ends them | on TERM the program ends them; a KILL leaves them | Claude: the interrupt ends a foreground command; a background `Bash` task survives. Codex: an open command stops the program |

## Out of scope

- Approvals in the UI: the answer stays `accept`.
- Showing the Claude background tasks in the TUI.
- `thread/fork`, `thread/revert`, `rewind_files`, and branching.
- Compaction inside the harness (`thread/compact/start`).
- A model switch inside one program: a switch closes the program.

## Current limits

The session end bounds each one.

- A session stop during a wait for an interrupt or an idle close answer can kill the provider process before its close answers (`docs/features/session-lifecycle.md`, "Current limits"). The program then gets TERM from the watchdog before it exits by itself. When the kill fires before the provider process reads the close, the program gets no end of input.
- Claude: a `result` of the turn's own line before its `started` is skipped, so the turn ends only by an abort.
- Claude: an interrupt during a program turn was not run. When the control response does not name the line in `cancelled`, the interrupt waits for a `result`, and its armed kill stops the program.
- Claude: a program turn that starts while a Helyx turn waits for an unresolved steer counts for the Helyx turn.
- Claude: the `started` clause of a steer does not check the start of the turn's line.
- Claude: a prompt that is preparing when a program turn starts makes the session drop the program turn, and its text is lost.
- Claude: an idle close between `background_tasks_changed []` and `task_notification`, when the two lines come in separate reads, ends the program's input. What the program then does was not observed (`docs/research/claude-code-stream-json.md`, "End of input during a program turn").
- Claude: a `task_notification` that starts no program turn gives one more `:busy`.
- Claude: a `tools/call` of a sub-agent runs, but the transcript does not show it: the provider drops sub-agent lines.
- Claude: an interrupt sent while the program is idle can end a background sub-agent of an earlier turn.
- Codex: a child thread whose `completed` item never comes stays in `agents`, so the idle close answers `:busy` until the session ends, and an abort of its turn stops the program.
- Codex: a sub-agent of a sub-agent is not tracked, and an `interacted` child whose earlier turn completes leaves `agents` while its new work runs. A later abort then interrupts and does not stop the program.
- Codex: the transcript names a Helyx call `dynamicToolCall`, as every tool item is named by its type.
- Codex: the digest is taken over the JSON of the specs; a spec with more than 32 parameter keys encodes in hash order, which can change between OTP releases and starts a new thread with the replay.
