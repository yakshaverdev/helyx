# Long-lived harness

One harness program serves the provider process of a session, not one turn: `claude` for `Helyx.Provider.ClaudeCode` and `codex app-server` for `Helyx.Provider.Codex`. Both share `Helyx.HarnessIO`. This doc gives what the harness plugins own: the program lifecycle, the idle close answer, the replay, and the plugin bounds. The Core turn contract (turn states, turn end, deadlines, steer, provider death) is in `docs/features/session-lifecycle.md`, and the provider protocol in `docs/features/one-provider-path.md`.

The protocol facts are in `docs/research/claude-code-stream-json.md` and `docs/research/codex-app-server.md`.

## Program lifecycle

- **Start.** `init/3` finds the program on `PATH` (`HarnessIO.find/1`). Codex starts it there; Claude starts it at the first turn, because the launch takes the turn's prompt (`docs/features/provider-parity.md`). It runs in the session's working directory, in its own process group under `Helyx.Watchdog`, with open input. The provider process holds the groups with `Helyx.Tool.hold/1`, and the hands release them with `release/3` (ADR 0004). The program has the trust of the bash tool: Claude runs with `--permission-mode bypassPermissions`, and Codex threads run with the approval policy `never` and the sandbox `danger-full-access`.
- **Close.** `:close` ends the program's input (`HarnessIO.close/2`) and answers `:ok` at the exit. A program exit at any other time stops the provider process.
- **Stop.** Any stop of the provider process closes its port. The watchdog sends TERM to the program group, waits the TERM grace, and sends KILL. A stop never sends end of input first: Claude runs its queued turns after end of input, and a stop must not run them.
- **Idle close.** `:idle_close` closes as `:close` when the program has no work of its own, and answers `:busy` otherwise; the program then stays. Claude has work of its own while the `tasks` list of the last `background_tasks_changed` line is not exactly `[]`, while a program turn runs, and once after a `task_notification` line. Codex has work of its own while a child thread has open work.
- **Shell.** Each program runs with its shell off, and the model runs its commands with the Helyx `bash`. The hands then give each command its abort, its output bound, and its tool events; a command that the program ran with its own shell had none of them, and a background command outlived an abort. Every Helyx tool goes to it, and Claude has none of its own tools (`docs/features/provider-parity.md`). The observed runs are in `docs/research/harness-shell-off.md`.
- **Background work.** A Claude background task, such as a background sub-agent, and a Codex child thread with open work after a normal turn end, belong to the program, not to a turn. They outlive the turn end. An interrupt ends every Claude sub-agent.
- **No stored state.** With the provider option `persist: false` (`:provider_opts` of the session; default `true`), the program keeps no conversation file: Claude Code launches with `--no-session-persistence`, and Codex starts the thread with `ephemeral: true`. Such a harness session cannot be resumed: the provider gives no `:resume_id` event, a later program and a prompt change start a fresh harness session with the replay, an `init/3` with a `:resume_id` fails with `:no_state_resume`, and a Claude Code compaction fails at once. The rule and its reasons are in `docs/features/harness-no-state.md`.
- **Environment.** With the provider option `env` (`:provider_opts` of the session), a map of string to string with the default `%{}`, every launch of the program gets the map on top of the environment of the BEAM. The state folder of the program is one use of it (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). The check, the bounds, and why Helyx logs no value are in `docs/features/harness-no-state.md`, "The environment of the program".
- **Errors.** stderr is dropped: the Claude `result` line and the Codex error answers carry the errors. An error result of a turn (a Claude `result` that is not a success, `is_error: true` with the subtype `success` too, and a Codex `turn/completed` that is not `completed`) fails the turn with `%Helyx.ProviderError{provider: id, kind: subtype_or_status, text: text}`, whose message is `<id>: <text>` (#746). The text is the program's error text, cut at 2,000 bytes. A result with no text fails it with `{:claude_code, subtype, ""}` or `{:codex, status, ""}`. A Codex error answer to a request that fails the request or the turn (`failure/2`) is the same exception with the method as `kind` and the error `message` as the text, or `unexpected response` when it has none; a Claude Code error answer to `initialize` or to an interrupt has the `kind` `:initialize` or `:interrupt`, and with no text it is `{:initialize, ""}` or `{:interrupt, ""}` (#760). An error answer to `thread/resume` other than a lost thread keeps `{:malformed, "thread/resume"}` (see "Connect").

## Claude Code

- The program runs as `claude --output-format stream-json --verbose --include-partial-messages --input-format stream-json --permission-mode bypassPermissions --tools= --setting-sources= --strict-mcp-config --system-prompt= --system-prompt-snapshot=off --disable-slash-commands --model=<model> --session-id=<uuid> --mcp-config <helyx server>`, with no `-p`. The first line on stdin is the control request `initialize` with the turn's prompt. A resume passes `--resume=<id>` in place of `--session-id`. The program of a compaction has no `--disable-slash-commands`, because the flag also takes out `/compact` (`docs/features/harness-compaction.md`, #754). The model ref is `claude-code/<model>`, where `<model>` is what `claude --model` takes.
- **Shell off.** `--tools=` takes out every tool of the program: the shell, `Monitor`, the file tools, web fetch and search, and sub-agents.
- **Commands off.** With `--disable-slash-commands`, a user line runs no program command or skill. A line whose first word is the name of a built-in command (`/init`, `/help`) gets the program's answer `/<name> isn't available in this environment.` with no model call and no text delta, so the turn ends `done` with no text; a line with a skill name such as `/code-review` reached the model after a program reminder that no command ran. A named limit (ADR 0002).
- **Capabilities.** Each `init` line must list `interrupt_cancel_queued_v1` and `msg_lifecycle_v1`. An `init` without both stops the provider process with `{:missing_capabilities, missing}`.
- **Turn.** A turn is one user line with a `uuid`, answered `:ok` at the write. The lines and the `result` of a turn count only after `command_lifecycle` `started` of its `uuid`; the provider drops the lines before it, such as those of a replay. The turn ends at a `result` with `queued_turn_count` 0 and no unresolved steer. A `result` with `queued_turn_count` above 0 does not end the turn. A missing `queued_turn_count`, or one that is not a non-negative integer, stops the provider process with `:no_queued_turn_count`.
- **Steer.** A steer is a user line with a `uuid` of its own, which the provider maps to the `steer_id`. After the terminal of the turn, the provider answers `:rejected` and writes nothing. Otherwise the write answers `:ok`, and the steer is unresolved until `command_lifecycle` `started` of its `uuid`, which gives `{:user_message, steer_id}`. A `result` with `queued_turn_count` 0 while a steer is unresolved gives no event: the provider waits for the steer's `started`, then for the next such `result`. Over the steer wait, the provider process stops with `:steer_not_started`. After a lost-session relaunch the steers of the turn are dropped, not written again.
- **Interrupt.** The control request `interrupt` with `cancel_queued: true`. It waits for the first `init` line, and after a replay for `started` of the turn's line. A success response whose `still_queued` is not exactly `[]` answers `{:error, :still_queued}`. Otherwise the answer is `:ok` after the success response and the turn's `result` (any `terminal_reason`), or after a success response whose `cancelled` list holds the turn's `uuid`. A success response whose `cancelled` is not a list is a contract break: the provider stops and the turn fails. The interrupt no longer waits for a `result` after such a response. A turn that already ended answers `:ok`, and nothing is written.
- **Program turns.** An `init` line with no Helyx turn starts a program turn: the provider makes a UUID as its turn id and gives `{:event, id, :turn_start}`. A steer and an interrupt of it work as for any turn. A `{:turn, ...}` while a program turn runs replaces it: the program runs the new line after the program turn, and the rest of the program turn is dropped.
- **Lost session.** A resumed program that no longer has the session writes one `result` with the lost text before any `init`, and exits. The provider starts a fresh program with a new id, and a turn that was already written goes to it with the replay. A close during that waits for the lost program's exit.
- **Helyx tools.** An SDK MCP server named `helyx`, the only MCP server; the model sees each tool as `mcp__helyx__<name>`. A `tools/call` gives `{:tool_request, id, name, arguments}` when its `_meta["claudecode/toolUseId"]` is a string, its name is one of the tools that the program was given, its arguments are an object or absent, and a turn is started (a Helyx turn after its `started`, or a program turn). Any other call gets the error result `the call does not map to a tool use` at once. `notifications/cancelled` for an open call removes the call from the open calls and gives no action, so the later result of its run is not written. `initialize` gets a result that echoes `params.protocolVersion`, and `tools/list` gets the Helyx tool specs. The transcript has the Helyx name, without the `mcp__helyx__` prefix. A notification gets the ack `{"jsonrpc":"2.0","result":{}}`, and a request of another method gets the JSON-RPC error -32601.
- **Control requests.** Every control request gets an error answer, `can_use_tool` too: the launch flags make it impossible (ADR 0007, update of 2026-10-16). An unknown line, `control_cancel_request` included, is ignored.
- **Output.** Text and thinking stream as deltas. Tool calls and results arrive whole. The provider sends no `message_end`: the session closes the message.

## Codex

- The program runs as `codex app-server --disable shell_tool --disable unified_exec`. With these flags, the tool list of the model request has no command tool on codex 0.144.1 and 0.162.1, for the thread and for a sub-agent, also when the user's `config.toml` turns `unified_exec` on. On both versions `--disable shell_tool` takes out every command tool (`exec_command`, `write_stdin`, `shell_command`). `--disable unified_exec` alone changes `exec_command` into `shell_command` on 0.144.1 and has no effect on 0.162.1, where `codex features list` still shows `unified_exec` on (see the research note). `apply_patch` stays for file changes. The model ref is `codex/<model>`.
- **Own tools.** `apply_patch`, `request_user_input`, the `multi_agent_v1__*` tools, the MCP resource tools, and the tools of the user's MCP servers stay: a named limit (ADR 0002). The probe of #754 found no option, feature, or thread parameter of 0.163.0 that removes them; the config key `model_catalog_json` was not tried (`docs/research/provider-parity.md`).
- **Connect.** `initialize` (with `experimentalApi` when the program gets Helyx tools) in `init/3`. The first turn opens the thread with its prompt as `baseInstructions`: `thread/resume` with the stored id and the trust overrides, or `thread/start` (with the Helyx tools as `dynamicTools`). A resume error with code -32600 and the exact message `no rollout found for thread id <id>` starts a fresh thread on the same program. Any other resume error fails the turn with `{:malformed, "thread/resume"}`. An error answer to `initialize` fails the connect, and one to `thread/start` fails the turn, with the program's error.
- **Thread id.** The stored id is the thread id, `#`, and the digest of the flags and the `dynamicTools` (`HarnessIO.session_id/2`; `docs/features/provider-parity.md`, "Resume eligibility"). A stored id with another digest starts a new thread with the replay.
- **Turn.** `turn/start` with the prompt; `:ok` at its answer, which carries the program's turn id. An error answer to `turn/start` or `thread/inject_items` is the reply `{:error, %Helyx.ProviderError{kind: method, text: message}}` (see "Errors"), and the provider process stops.
- **Steer.** `turn/steer` with `expectedTurnId` equal to the running program turn id and `clientUserMessageId` equal to the `steer_id`. After `turn/completed` the provider answers `:rejected` and sends nothing. A success answer gives `:ok`. The exact error `no active turn to steer` with code -32600 gives `:rejected`; any other error gives `{:error, reason}`. The `item/started` of a `userMessage` item of the running turn with a string `clientId` gives `{:user_message, clientId}`.
- **Interrupt.** With an open `commandExecution` item of the turn, `{:error, :command_running}` at once; with a child thread of the turn that has open work, `{:error, :agent_running}`. Both write nothing, and Core then stops the program. Otherwise `turn/interrupt`, sent when the turn id is known and answered at `turn/completed`, or with its error answer. An interrupt of an ended turn answers `:ok`.
- **Open work at a turn end.** A `turn/completed` with an open tool item stops the provider process with `:command_running` for a command and `:tool_running` for another type: `turn/interrupt` does not stop a running command, and its late `item/completed` must not reach the next turn. A `turn/completed` while an interrupt waits and a child thread of the turn has open work stops it with `:agent_running`.
- **Child threads.** A `subAgentActivity` item on the program's own thread changes `agents`: kind `completed` removes the child (any turn id); any other kind moves it to the running turn. The notifications of a child thread are dropped. A server request of any thread gets its answer as below, and an `item/tool/call` of a child thread does not map.
- **Unasked turns.** A `turn/started` whose id is not the one of the `turn/start` answer, or a `turn/completed` of an unknown turn, stops the provider process with `:turn_not_asked`. An item of another turn stops it with `:item_of_ended_turn`.
- **Line check.** `Helyx.Provider.Codex.Check.malformed/2` checks the full shape of every line that changes turn or thread state before any state changes. Any other shape, and a turn or item line with no string `threadId`, stops the provider process with `{:malformed, method}`; in the connect, the connect fails with it.
- **Request ids.** Each request has a new integer id; `due` maps each id without an answer to its method. An answer with an id that is not due is dropped. The turn end settles a sent `turn/interrupt`.
- **Helyx tools.** An `item/tool/call` of the running turn whose `callId` is an open `dynamicToolCall` item, with a `tool` that the thread was given and object `arguments`, gives `{:tool_request, call_id, tool, arguments}`. Any other call gets `the call does not map to a tool use` at once. A result goes back as one `inputText` content item with `success`.
- **Server requests.** Every server request gets the JSON-RPC error -32601, a command or file change approval request too: the approval policy `never` makes it impossible (ADR 0007, update of 2026-10-16).
- **Output.** Text and reasoning stream as deltas. A tool item is a tool call when it starts and a tool result when it completes. The provider sends no `message_end`.

## Replay

A fresh harness session (no resume id, a lost session, or a changed Codex tool set) gets the rest of the transcript before the first turn's prompt, and the turn gives `{:resume_id, id, cut}` with the number of messages left out. The prompt is the user messages at the end of the context. The replay keeps the newest messages within `@replay_max_bytes` of `Helyx.HarnessIO` and never starts at a tool result.

- Claude Code writes the replay as lines that start no model call (`shouldQuery: false`), in chunks. Each chunk ends at a replayed user line, and the next chunk goes out at that line's `result` with `num_turns` 0. So the model gets the transcript in its order. A steer while chunks are held goes after the turn's line.
- Codex sends the replay with `thread/inject_items`, then `turn/start`.

## Bounds

| What | Bound | Over the bound | Owner |
| --- | --- | --- | --- |
| stdout line | 16 MiB (`@line_max_bytes` in `Helyx.HarnessIO`) | the provider process stops | provider |
| JSON in a stdout line | a JSON object, with each integer up to the largest integer of the BEAM: on OTP 28 every integer of 1,262,592 digits or fewer decodes, and 1,262,593 nines do not (`docs/features/wire-protocol.md`, "Bounds"); a line of 16 MiB can hold a larger one (#786) | the line is skipped, as perl's own text and any other line that does not decode to a JSON object | provider (`Helyx.HarnessIO.lines/3`) |
| bytes written to the program and not yet read | 16 MiB (`@stdin_max_bytes` in `Helyx.Watchdog`) | the watchdog stops the program group and exits with a status; the provider process stops on that exit | watchdog |
| TERM grace | 5,000 ms (`@term_grace_ms` in `Helyx.HarnessIO`) | KILL. The program's own command groups can stay after a KILL | watchdog |
| replay | 400,000 bytes (`@replay_max_bytes` in `Helyx.HarnessIO`) | the oldest messages are left out; `cut` counts them | provider |
| replay: tool call id | 1 to 64 characters of `[a-zA-Z0-9_-]` (`Helyx.HarnessIO.wire_id/1`) | the id becomes `h_` and 62 hex digits of its SHA-256 | provider |
| Codex replay: tool name | `[a-zA-Z0-9_-]` (`tool_name/1` in `Helyx.Provider.Codex.Replay`); no length limit, because none is known for `thread/inject_items`. The replay budget bounds the bytes | each other character becomes `_`; an empty name becomes `_`. The name is not cut to an assumed program limit: a program that rejects a long name fails the replay through its generic error path | provider |
| Claude: wait for `started` of an unresolved steer after a `result` with `queued_turn_count` 0 | 5,000 ms (`@steer_wait_ms` in `Helyx.Provider.ClaudeCode`) | the provider process stops with `:steer_not_started` | provider |
| Claude: wait for `started` of the turn's line, and for each replay chunk's `result` | unbounded, accepted | an abort; the interrupt has its armed kill | Core |
| Codex: open `item/tool/call` requests | one per call that gave a `{:tool_request, ...}`, removed at its `{:tool_result, ...}`; Core answers every request once | not needed: Core answers each request once | provider |
| Codex: child threads with open work (`agents`) | one entry per child thread, until a `subAgentActivity` item of kind `completed` | unbounded, accepted; see "Current limits" | provider |
| Codex: thread id from `thread/start` | 1 to 239 bytes of valid UTF-8, so a stored id with its digest passes `Helyx.Message.resume_id?/1` | the first turn fails with `{:malformed, "thread/start"}` | provider |
| harness life | the session; the idle close after the idle time; unbounded while the program has work of its own | the idle close | Core |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| --- | --- | --- | --- | --- | --- |
| program port, watchdog, program group | `Helyx.Watchdog.start/4` in `init/3` (Codex), at the first turn (Claude), in a relaunch after a prompt change, or in a Claude relaunch after a lost session | provider process (the linked port), hands (the handles), and watchdog (the life) | close: end of input, the exit, then `release/3` | the closed port ends the watchdog's stdin: TERM, grace, KILL | kept after an interrupt `:ok`, and on an abort in `preparing` (no interrupt goes out); otherwise as a crash, with no end of input |
| the program's own command groups | the program | the program | the program ends them | on TERM the program ends them; a KILL leaves them | The model runs no command in the program: the shell is off, and its commands are Helyx `bash` calls. For a command that the program runs by itself, Claude: the interrupt ends a foreground command. Codex: an open command stops the program |

## Replaced mechanism

The Helyx `bash` replaces the program's own shell (#478).

| Old | New |
| --- | --- |
| Claude `Bash`, with `run_in_background`, and `Monitor` | off with every other tool of the program (`--tools=`); the model calls `mcp__helyx__bash`, which the hands run, abort, and bound |
| Codex `shell_tool` and `unified_exec` (`commandExecution` items) | disabled by the launch flags; the model calls the `bash` dynamic tool. The `command_running` check stays for a command that the program runs by itself |
| Helyx `read`, `edit`, and `write` next to the program's file tools | sent; Claude has no tools of its own, and Codex keeps the few that no flag removes (`docs/features/provider-parity.md`) |
| Real test: a background `Bash` task outlives an abort, a foreground one ends, the program stays | `claude_code_real_test.exs`: the model's command is a Helyx `bash` call, the hands release it on abort, and the program stays. No model background shell is left to test |

Users see each command as a Helyx `bash` tool cell, and Esc aborts it: the hands release it. A Codex thread stored with the file tools in its set starts fresh with the replay.

## Out of scope

- Approvals in the UI: an approval request gets an error (#503).
- A product option that gives a harness its own shell. It comes when a product needs it.
- Showing the Claude background tasks in the TUI.
- The MCP servers of the user's own Claude or Codex config. They stay. A tool of such a server that starts a process gives it no Helyx abort, output bound, or tool event. The Codex tool lists of the probe had one named `mcp__node_repl__js` (`docs/research/harness-shell-off.md`, "The tool list of the model request").
- `thread/fork`, `thread/revert`, `rewind_files`, and branching.
- Compaction inside the harness: `docs/features/harness-compaction.md` (#552).
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
