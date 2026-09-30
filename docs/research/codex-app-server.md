# The JSON-RPC protocol of `codex app-server`

Research for ticket #11 (Codex harness provider). Facts observed on 2026-09-25 from the unmodified Codex program, `codex-cli 0.155.0`, on macOS, signed in with ChatGPT (`codex login status` prints `Logged in using ChatGPT`). Sources: `codex app-server --help`, the schema that `codex app-server generate-json-schema --out <dir>` writes (without `--experimental`), and eight small runs with the model `gpt-6-luna`, the cheapest in `model/list`, driven by a Python script over stdio. The program is closed to Helyx and changes often, so the facts below are observations of one version, not a contract. Anything marked "not verified" was not run.

## Transport

- `codex app-server` with no option listens on stdio (`--listen stdio://` is the default). Each message is one JSON object on one line, in both directions. The server writes no `"jsonrpc"` key; it accepts requests that have one.
- Stderr carries the program's own log lines (with ANSI colour codes), for example `ERROR codex_core::session: failed to record rollout items`. Stdout carries only protocol lines.
- **End of file on stdin ends the program with exit status 0.** Every run below ended that way after its last response.
- The user's own configuration is active: `~/.codex/config.toml`, its MCP servers (`mcpServer/startupStatus/updated` notifications), and its hooks (`hook/started`, `hook/completed`).

## Handshake

1. Request `initialize` with `{"clientInfo": {"name": ..., "version": ...}}`. The result has `userAgent`, `codexHome`, `platformFamily`, and `platformOs`.
2. Notification `initialized` (no params).

## Threads

- `thread/start` takes `cwd`, `model`, `approvalPolicy`, `sandbox`, and more, all optional. The result is `{"thread": {...}}` with `thread.id` (a UUIDv7 string, 36 bytes), `thread.path` (the rollout file under `~/.codex/sessions/`), `model`, and the resolved `cwd`. A relative `cwd` is resolved against the program's working directory. A `thread/started` notification with the same thread follows. The result line was 1,830 bytes.
- `thread/resume` takes `threadId` and the same overrides. With `"excludeTurns": true` the result has the thread without its turns; without it, `thread.turns` holds the whole history.
- **A lost thread.** `thread/resume` with a UUID that names no thread gives an error response and nothing else: `{"error":{"code":-32600,"message":"no rollout found for thread id <id>"},"id":2}`. The program keeps running, so a `thread/start` on the same connection works.
- **A killed program leaves a resumable thread.** A run got `SIGTERM` to its process group while the model ran `sleep 30`; the program logged `failed to record rollout items: thread ... not found` and exited. A new program resumed the thread by id, and the model knew the code word given in the killed turn's prompt.

## Replay: `thread/inject_items`

`thread/inject_items` is in the stable schema (not `--experimental`): `{"threadId": ..., "items": [...]}`, where `items` are "raw Responses API items to append to the thread's model-visible history". The result is `{}`. It makes no model call and no item notifications.

Verified on a fresh thread, before its first turn, with these items:

```json
{"type":"message","role":"user","content":[{"type":"input_text","text":"Remember the code word PELICAN."}]}
{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Noted: the code word is PELICAN."}]}
{"type":"function_call","call_id":"toolu_01ABC","name":"Read","arguments":"{\"path\": \"notes.txt\"}"}
{"type":"function_call_output","call_id":"toolu_01ABC","output":"the file says: BLUE HORSE"}
{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I read notes.txt."}]}
```

The next `turn/start` answered `Code word: PELICAN; notes.txt said: BLUE HORSE.` with no tool run. So user text, assistant text, and a call with its output all reach the model, and a call to a tool that the thread does not have (`Read`) is accepted in history.

The model API checks the injected items only when a turn sends them, and the thread keeps them: **a bad item fails every later turn of that thread**. Observed limits, each from a `turn/completed` with `status: "failed"` and the API's `invalid_request_error`:

- `name` of a `function_call` must match `^[a-zA-Z0-9_-]+$`: `mcp/server.tool` was rejected.
- `call_id` has at most 64 characters: 100 was rejected, 64 was accepted. `call.a/b:1` (dots, a slash, a colon) was accepted.

Not verified: the length limit of `name`, a `call_id` with non-ASCII characters, image content, and a size limit of the injected history.

## Turns

- `turn/start` takes `threadId` and `input`, a list of `{"type":"text","text":...}` (images and more exist). The result is `{"turn": {"id": ..., "status": "inProgress", ...}}`.
- Notifications of one turn, in order: `turn/started`; `item/started` and `item/completed` of a `userMessage` (the prompt); then per model output `item/started`, deltas, `item/completed`; `thread/tokenUsage/updated` after each model call; `turn/completed` last. Every one carries `threadId`, and every one but `turn/started` and `turn/completed` carries `turnId`; those two carry the turn as `turn`, with `turn.id`.
- `turn/completed` has `turn.status`: `completed`, `interrupted`, or `failed`, and `turn.error` (`{"message": ..., "codexErrorInfo": ...}`) when failed. A failed turn is preceded by an `error` notification with the same error and `"willRetry": false`.
- Observed on 2026-09-27 with `codex-cli 0.157.1` (#201): the `turn/start` answer came before `turn/started` in every run, and the request ids of `turn/start` and `turn/interrupt` were used again on later turns of one connection with no error.
- `thread/tokenUsage/updated` has `tokenUsage.last` and `tokenUsage.total`, each `{totalTokens, inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, reasoningOutputTokens}`.

### Items

`item.type` values in the schema: `userMessage`, `hookPrompt`, `agentMessage`, `functionCallOutput`, `plan`, `reasoning`, `commandExecution`, `fileChange`, `mcpToolCall`, `dynamicToolCall`, `collabAgentToolCall`, `subAgentActivity`, `webSearch`, `imageView`, `sleep`, `imageGeneration`, `enteredReviewMode`, `exitedReviewMode`, `contextCompaction`. Observed in runs: `userMessage`, `reasoning`, `agentMessage`, `commandExecution`.

- `agentMessage`: `item/started` with `text: ""`, then `item/agentMessage/delta` notifications (`{"itemId": ..., "delta": "Code"}`), then `item/completed` with the whole `text`. `phase` was `commentary` for text before a tool call and `final_answer` for the last text.
- `reasoning`: `item/started` and `item/completed` with empty `summary` and `content` lists for this model. The schema has `item/reasoning/summaryTextDelta` and `item/reasoning/textDelta` (`{"itemId", "delta", ...}`); neither was observed.
- `commandExecution`: `item/started` with `command` (`/bin/zsh -lc 'echo hi > out.txt && cat out.txt'`), `cwd`, `status: "inProgress"`, and `processId` (an id of the program, not an OS pid); `item/completed` with `status: "completed"`, `aggregatedOutput` (`"hi\n"`), and `exitCode`. No `item/commandExecution/outputDelta` was observed. The status enum is `inProgress`, `completed`, `failed`, `declined`; `fileChange` has the same, `mcpToolCall` and `dynamicToolCall` have no `declined`. In the 0.157.1 schema (2026-09-27, `generate-json-schema`), `collabAgentToolCall` has `inProgress`, `completed`, `failed`, `interrupted`; `imageGeneration` has a required `status` string with no enum; `webSearch`, `imageView`, and the other item types have no `status`.

## Interrupt

`turn/interrupt` with `threadId` and `turnId`, sent while the model ran `sleep 30`: the result `{}` and `turn/completed` with `status: "interrupted"` arrived within 1 ms of each other, less than 1 s after the request. The running `commandExecution` got no `item/completed`.

## Processes

The program on `PATH` is a Node wrapper (`~/.bun/bin/codex`) that runs the native binary as its child in the same process group. The native binary starts every command, and its helper processes (`node_repl`, `codex-code-mode-host`), **each in a process group of its own**.

- `SIGTERM` to the wrapper's group while `sleep 30` ran: 0.5 s later no process of the tree was left. The program ends its commands itself.
- `SIGKILL` to the same group: `sleep 30` survived with parent 1 in its own group. The helpers ended.
- The wrapper source (`@openai/codex` 0.155.0, `bin/codex.js`, lines 255 to 295) forwards `SIGINT`, `SIGTERM`, and `SIGHUP` to the native binary once (a later signal finds `child.killed` set and does nothing), and exits only after the binary exits, with its status. So the wrapper's pid lives until the binary has ended its commands. Not verified: what the native binary does with a second `SIGTERM` sent to the group during its cleanup.

## Approvals

With `"approvalPolicy": "never"` and `"sandbox": "danger-full-access"` on `thread/start` and `thread/resume`, the runs above ran commands and wrote files with no server request. The schema lists these server requests: `item/commandExecution/requestApproval` and `item/fileChange/requestApproval` (result `{"decision": "accept" | "acceptForSession" | "decline" | "cancel" | ...}`), `item/permissions/requestApproval`, `item/tool/requestUserInput`, `mcpServer/elicitation/request`, `item/tool/call`, `account/chatgptAuthTokens/refresh`, `attestation/generate`, and the v1 `applyPatchApproval` and `execCommandApproval`. None arrived in these runs. Not verified: what the program does with a JSON-RPC error answer to a server request (fail the item, fail the turn, or wait).

## Sizes

No limit is documented for a line. The largest lines in these runs were the `thread/start` result and the `thread/started` notification, under 2,000 bytes each. `thread/resume` without `excludeTurns` returns the whole history in one line (not measured).

## Long-lived use, steering, approvals, and client tools (2026-09-26)

Runs on 2026-09-26 with `codex-cli 0.157.1` (the program updated itself from 0.155.0), the model `gpt-6-luna` with effort `low`, in empty temporary directories: four runs with about 20 turns, driven by a Python script over stdio. Source: `openai/codex` tag `rust-v0.157.1`, commit `36650394c5b38c2990ccf2a3457165ca3e9d9726`, and the schemas from `generate-json-schema` with and without `--experimental`. "Verified" means a run on 0.157.1. "Source" means the repository at that tag.

### Stable and experimental schema

- The stable schema has 104 client requests, 10 server requests, and 83 notifications. With `--experimental` it has 167 client requests and 11 server requests (source).
- An experimental method or field needs `initialize` with `"capabilities":{"experimentalApi":true}`. Without it the server answers `{"error":{"code":-32600,"message":"thread/start.dynamicTools requires experimentalApi capability"},"id":2}` (verified).
- **`thread/rollback` was removed.** The call gives `unknown variant` (verified). `thread/revert` replaces it (source: `app-server/README.md`).

### One process, many turns (verified)

- One process ran 7 turns and a compaction turn on one thread in about 55 s. Each `turn/start` came after the last `turn/completed` on the same connection. `thread/status/changed` goes `active`, then `idle`, around each turn.
- Overrides on `turn/start` (`model`, `effort`, `cwd`, `sandboxPolicy`, `approvalPolicy`, `summary`) apply "for this turn and subsequent turns" (source). `effort: "low"` on a later turn was accepted (verified). A model or `cwd` change in the middle of a thread was not verified.
- **`thread/resume` does not keep the sandbox and the approval policy.** A thread started with `"sandbox":"workspace-write"`. A later `thread/resume` with no override returned `"sandbox":{"type":"readOnly",...}` and `"approvalPolicy":"never"` (verified). A client sends the overrides again on every resume.

### Steer: `turn/steer` (stable, verified)

- Request: `{"threadId","expectedTurnId","input":[...],"clientUserMessageId"?}`. The result is `{"turnId"}`.
- Sent while the model ran `sleep 6`: the command was not stopped. After its `item/completed`, the steer input arrived as a `userMessage` item **in the same turn**, before the next model call. The model obeyed it, and the turn had one `turn/completed` with `completed`. So a steer takes effect at the next model call.
- Errors: `no active turn to steer` with no turn running, and `expected active turn id ... but found ...` with a wrong id (verified). A review turn and a compaction turn cannot be steered (source).
- **`turn/start` during a running turn also steers.** It returned the running turn's id, and its text became a `userMessage` of that turn (verified). Only `turn/steer` checks the turn id.

### Interrupt (verified)

- `turn/interrupt {threadId, turnId}` during `sleep 30`: the result `{}` came after 19 ms, then `thread/status/changed` `idle` and `turn/completed` with `"status":"interrupted"`. The running `commandExecution` got no `item/completed` before the script ended (2026-09-27: the command keeps running, see "Verify before implementation"). The server sends the result only after the turn has stopped (source).
- The next `turn/start` on the same process and thread worked 0.5 s later.

### Approvals

- `approvalPolicy`: `untrusted`, `on-request`, `never`, or a `granular` object. `sandbox` on `thread/start`, `thread/resume`, and `thread/fork`: `read-only`, `workspace-write`, `danger-full-access` (source).
- **Command** (verified with `untrusted` and `read-only`): `{"method":"item/commandExecution/requestApproval","id":1,"params":{"threadId","turnId","itemId","command":"/bin/zsh -lc 'echo hi > made.txt'","cwd",...,"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{...}},"cancel"]}}`. The `item/started` of the command comes first. `serverRequest/resolved` follows the answer.
  - `{"decision":"accept"}`: the command ran, although the sandbox was `read-only`.
  - `{"decision":"decline"}`: `item/completed` with `"status":"declined"`, and the turn went on. `decline` worked although `availableDecisions` did not list it.
  - `acceptForSession` and `cancel` ("the turn will also be immediately interrupted") are in the source; not verified.
- **File change** (verified): `{"method":"item/fileChange/requestApproval","id":3,"params":{"threadId","turnId","itemId","reason":null,"grantRoot":null}}`. The request has no diff; the diff is in the `changes` of the `fileChange` item's `item/started`, which comes first.
- **A JSON-RPC error answer to an approval is a decline** (verified). The server sent `serverRequest/resolved`, the item completed with `"status":"declined"`, and the turn completed. This closes the "not verified" item in "Approvals" above.

### Client tools: `dynamicTools` (experimental, verified)

- `thread/start.dynamicTools` is experimental. The server request `item/tool/call` and the item `dynamicToolCall` are stable (source).
- A tool spec is `{"type":"function","name","description","inputSchema","deferLoading"?}`, or a `namespace` that holds such tools (source).
- Observed: `item/started` of a `dynamicToolCall`, then `{"method":"item/tool/call","id":0,"params":{"threadId","turnId","callId","namespace":null,"tool":"lookup_code","arguments":{"key":"alpha"}}}`. The answer `{"id":0,"result":{"contentItems":[{"type":"inputText","text":"ZEBRA-42"}],"success":true}}` reached the model.
- Content items: `inputText`, `inputImage` (a remote URL is rejected), `inputAudio` (a `data:` URL only) (source).
- An error answer, or an answer that does not parse, reaches the model as `success: false` with the text "dynamic tool request failed" or "dynamic tool response was invalid". The turn does not fail (source: `app-server/src/dynamic_tools.rs`).
- `thread/resume` has no `dynamicTools` field (source). **The tools of a thread survive a resume in a new process** (verified, two runs). Process 1 started a thread with the tool `lookup_code`, ran one turn that called it, and ended by end of file on stdin. Process 2 sent `thread/resume` with no tools and asked for a new key. The server sent `item/tool/call` for `lookup_code`, and the answer that only the tool could give reached the model. This worked when process 2 sent `initialize` with `experimentalApi` and also when it did not, so only `thread/start` needs the experimental capability.
- So the tool set is fixed when the thread starts. A client that needs another tool set starts a new thread.
- Schema of 0.157.1 (`generate-json-schema --experimental`, 2026-09-30, #243; no model call): `InitializeCapabilities.experimentalApi` is a boolean with the default `false`. A `function` tool spec requires `name`, `description`, `inputSchema`, and `type`. `DynamicToolCallParams` requires `threadId`, `turnId`, `callId`, `tool`, and `arguments` (any JSON); `namespace` is a string or null. `DynamicToolCallResponse` requires `contentItems` and `success`. The `dynamicToolCall` item requires `id`, `tool`, `arguments`, and `status`. The `thread/resume` result has no field for the thread's tools. Not seen: the error of an `initialize` that rejects `experimentalApi`.

### Other methods (verified unless marked)

| Method | Result |
|---|---|
| `model/list` | `data[]` with `id`, `isDefault`, `supportedReasoningEfforts`, `hidden` |
| `account/rateLimits/read` | `primary.usedPercent`, `windowDurationMins`, `resetsAt`, `planType`, and more. The server also sends `account/rateLimits/updated` after every model call |
| `config/read` | The user's effective configuration |
| `thread/list` | `data[]` with `id`, `preview`, `model`, `status` |
| `thread/fork {threadId, excludeTurns, lastTurnId?}` | A new thread with `forkedFromId`. No model call |
| `thread/revert {threadId, beforeTurnId}` | Removes that turn and every later one from the history. It does not undo file changes (source) |
| `thread/compact/start {threadId}` | `{}` at once, then a separate turn with a `contextCompaction` item. `thread/compacted` was not sent |
| `thread/tokenUsage/updated` | Now also has `modelContextWindow` (258400 for this model) |
| `item/commandExecution/outputDelta` | Now observed (`"delta":"first\n"`); 0.155.0 did not send it |

### Processes on 0.157.1 (verified)

- Every command, and the helpers `node_repl` and `codex-code-mode-host`, still run in a process group of their own. The program starts a shell command with `setsid()`, or `setpgid(0,0)` when that fails, and with `kill_on_drop(true)` (source: `utils/pty/src/process_group.rs`, `core/src/spawn.rs`).
- **End of file on stdin during a running command:** the program exited with status 0 after about 0.07 s, and the command was gone 0.5 s later (two runs). The turn is saved as `interrupted`.
- In stdio mode the program installs no graceful handler for `SIGTERM` and `SIGHUP` (source: `app-server/src/lib.rs`, `graceful_signal_restart_enabled`). This handler is the graceful restart of the server, not the cleanup of commands.
- **`SIGTERM` to the program's group during a running command** (the wrapper and the binary, as the watchdog sends it): the program exited with status 0 after 0.04 s, and the command was gone 0.5 s later (two runs). So a TERM still ends the commands on 0.157.1, as on 0.155.0. The cause is not confirmed in the source; the likely path is `kill_on_drop` when the runtime ends.

## Verify before implementation (2026-09-27)

Runs on 2026-09-27 with `codex-cli 0.157.1`, the model `gpt-6-luna` with `model_reasoning_effort` `low`, in empty temporary directories, for the list "Verify before implementation" in `docs/features/long-lived-harness.md`. A Python script drove `codex app-server` over stdio, with `initialize` with `experimentalApi`, `approvalPolicy` `never`, and `sandbox` `danger-full-access` unless noted. Each program ran in a new session (its own process group). The user's configuration was loaded, and its hooks ran: a `stop` hook took 0.05 to 1.1 s between the last `item/completed` and `turn/completed`, with `hook/started` and `hook/completed` notifications. Times are the times at which the script read the line.

### A `turn/steer` that crosses `turn/completed` (verified, 3 runs)

- The script sent `turn/steer` when it read `hook/completed` of the `stop` hook, before it read `turn/completed`.
- The answer: `{"error":{"code":-32600,"message":"no active turn to steer"},"id":...}`. It came 1 to 2 ms after the request and **before** the `turn/completed` notification of the turn.
- No `turn/started` in the next 8 s. No new turn.

### A steer after the final answer and before `turn/completed` (verified, 5 runs)

- Sent at `item/completed` of the final `agentMessage` (1 run), at `thread/tokenUsage/updated` after it (2 runs), or at `hook/started` of the `stop` hook (2 runs).
- Each was accepted with the running turn's id. The turn took one more model call: a `userMessage` item with the steer, a second `agentMessage` that obeyed it, and one `turn/completed` with `completed`, 2.8 to 3.2 s later.

### `turn/steer` during the final answer (verified, 2 runs)

- Sent at the first `item/agentMessage/delta` of a poem. Accepted. The items of the turn: `userMessage`, `agentMessage`, `userMessage` (the steer), `agentMessage`. The second answer obeyed the steer. So the turn took one more model call, and the first answer stayed in the turn as its own item.

### The `userMessage` item of a steer (verified, 3 runs)

- The steer's `userMessage` item carries the value of `clientUserMessageId` in a field named **`clientId`**: `{"type":"userMessage","id":"01a0...","clientId":"<clientUserMessageId>","content":[...]}`. The item has no field `clientUserMessageId`. The first user message of a turn from `turn/start` has `"clientId":null`.

### `callId` of `item/tool/call` (verified, 5 calls in 3 runs)

- `callId` equalled the `id` of the `dynamicToolCall` item, for example `exec-2aeb2f3a-9792-4b97-ac71-9ba1aef7ca69`.

### An accepted steer, then `turn/interrupt` (verified, 2 runs)

- `turn/steer` during a foreground `sleep 15`, accepted; `turn/interrupt` 0.5 s later. Result `{}`, then `turn/completed` with `interrupted`.
- The steer was dropped: no `userMessage` item for it, no `turn/started` in the next 10 s, and the file that the steer asked for was not made. `thread/read` with `includeTurns` showed only the first user message in the interrupted turn.

### `turn/interrupt` does not end a running command (verified, 7 runs)

- During a foreground `sleep 17.3` (4 runs, one with `sandbox` `workspace-write`) or `sleep 15` (3 runs, with an accepted steer before the interrupt): the result `{}` and `turn/completed` with `interrupted` came as before.
- **The command kept running.** `ps` found the `sleep` in its own process group 1 s after the interrupt, in each run.
- When the command ended, 12.9 to 15.7 s after the interrupt, the program sent `item/completed` of that `commandExecution` with `"status":"completed"`, an item of the interrupted turn. In 2 runs it came during the next turn.
- This corrects the notes in "Interrupt" above: the runs there did not wait for the end of the command.

### An open `item/tool/call` at `turn/interrupt` (verified, 2 + 3 runs)

- **Not answered** (2 runs): the script held the request and sent `turn/interrupt` 2 s later. The program sent **no** `serverRequest/resolved`. The result `{}` and `turn/completed` with `interrupted` came, and then, 2 ms after `turn/completed`, `item/completed` of the `dynamicToolCall` with `"status":"failed"`. A late answer to the request 3 s later gave no error and no notification. The next turn ran as usual.
- **Answered first, as the design's abort orders it** (3 runs): the script answered the request with `"success":false` and the text `aborted`, then sent `turn/interrupt` at once. `item/completed` of the `dynamicToolCall` with `"status":"failed"` came before the interrupt result and `turn/completed`. No item of the turn came after `turn/completed`.

### The tool set after a resume with a different tool set (verified, 2 runs)

- Process 1: `thread/start` with `dynamicTools` `[lookup_code]`, one turn that called it, end of file on stdin.
- Process 2: `thread/resume` with `"dynamicTools":[fetch_color]`. The server accepted the request with no error and ignored the field. A turn that asked for `fetch_color` got the answer `NO_FETCH_COLOR` and no tool call. A turn that asked for `lookup_code` called it.
- So the thread keeps the tool set of `thread/start`. A resume does not change it and does not report the unused field.

### Not run

- The stop path end to end with the watchdog stdin cap: the cap is ticket #196, which is open. `SIGTERM` to the group is in "Processes on 0.157.1" above.

## Sub-agents at the end of a turn (2026-09-29, #226)

Runs on 2026-09-29 with `codex-cli 0.157.1`, the default model `gpt-6-astra` with `effort` `low`, for ticket #226. A Python script drove `codex app-server` over stdio, in a new session (its own process group), in an empty temporary directory. `initialize` set `experimentalApi`. `thread/start` had `approvalPolicy` `never` and `sandbox` `danger-full-access`. The feature `multi_agent` is `stable` and on by default (`codex features list`); the thread settings said `"multiAgentMode":"explicitRequestOnly"`. The prompt asked the model to use `spawn_agent` once; the sub-agent ran `python3 -c "import time; time.sleep(40)" <marker>`. `ps` looked for the marker. 4 runs; a fifth run is not counted because it started 0.144.1 by mistake. The user's own hooks were active. The source was not read for this section.

### The lines of a sub-agent (verified, 4 runs)

- **`spawn_agent` gives a `subAgentActivity` item**, not a `collabAgentToolCall`, on the parent thread: `{"type":"subAgentActivity","id":"call_...","kind":"started","agentThreadId":"<child thread id>","agentPath":"/root/<name>"}`. `item/started` and `item/completed` came within 4 ms.
- **The child thread gets no `thread/started`.** Its first line is `thread/status/changed` `idle`, then `active`, then its own `turn/started`. Its lines carry the child `threadId` and the child `turnId`: `item/started` and `item/completed` of `commandExecution` and `agentMessage`, `item/commandExecution/terminalInteraction` (about every 10 s during the command, `stdin` `""`), `thread/tokenUsage/updated`, and `turn/completed`.
- **When the child turn completes**, the parent thread gets a second `subAgentActivity` item: `"id":"subagent-completed-<child turn id>"`, `"kind":"completed"`, with the `turnId` of the parent turn that spawned it, also when that turn had already ended (2 runs). No new parent turn started in the 1.7 to 4.4 s that the script waited after it.
- **`wait` gives a `collabAgentToolCall` item** (1 run): `{"type":"collabAgentToolCall","tool":"wait","status":"inProgress","senderThreadId":<parent>,"receiverThreadIds":[],"agentsStates":{},"prompt":null,"model":null,"reasoningEffort":null}`. After `turn/interrupt` of the parent, this item got **no `item/completed`**.

### The sub-agent outlives the parent turn (verified, 4 runs)

- In 3 runs the model ended the parent turn after `spawn_agent`. `turn/completed` `completed` of the parent came first. The child's command started 1.6 to 9.1 s after it. `ps` found the command 2 s later.
- **`turn/interrupt` of the parent after its end** (1 run): the error `{"code":-32600,"message":"no active turn to interrupt"}`. The child ran on: the command completed with `exitCode` 0, then the child's `agentMessage` `done`, `turn/completed` `completed`, and the parent's `subAgentActivity` `completed`.
- **`turn/interrupt` of the parent during `wait`** (1 run): the result `{}` and the parent's `turn/completed` `interrupted` came within 11 ms. The child thread was not interrupted: its command ran to the end (`status` `completed`, `exitCode` 0) 38 s later, then the child's `turn/completed` `completed` and the parent's `subAgentActivity` `completed`, in the interrupted turn.
- **`turn/interrupt` of the child turn** (1 run, with the parent turn already ended): the result `{}` and the child's `turn/completed` `interrupted` came at once. The command kept running, as in "`turn/interrupt` does not end a running command": its `item/completed` `completed` came 38 s later, in the interrupted child turn. **The parent got no `subAgentActivity` `completed`** in this run.

### `SIGTERM` (verified, 4 runs)

- `SIGTERM` to the program's group: exit status 0 after 0.02 to 0.07 s in each run. In the run where the child's command still ran (the parent turn ended), `ps` found no marker process 1 s after the exit.
- The child's command ran in a process group of its own (pgid equal to its pid), with the program as parent. This is the same as a command of the main thread.

### Not run

- `send_input`, `close_agent`, and `resume_agent`; a `collabAgentToolCall` for `spawn` (the model did not offer one); a sub-agent of a sub-agent.
- End of file on stdin and `SIGKILL` with a sub-agent running.
- Whether the parent thread starts a turn by itself more than 4.4 s after the `subAgentActivity` `completed`.

## Program turns (2026-09-30, #240)

Runs on 2026-09-30 with `codex-cli 0.157.1`, for ticket #240. A Python script drove `codex app-server` over stdio, in a new session (its own process group), in an empty temporary directory. `initialize` set `experimentalApi`. `thread/start` had `approvalPolicy` `never` and `sandbox` `danger-full-access`; `turn/start` had `effort` `low`. The user's own hooks were active. The prompt asked the model to use `spawn_agent` once for a sub-agent that runs `sleep 15` and replies `done`, not to wait for it, and to reply `spawned`. The script waited 120 s after the parent's `subAgentActivity` `completed` item. It was ready to send `turn/steer`, and `turn/start` 1 s later, on a parent `turn/started` that it did not ask for.

- **Run 1**, model `gpt-6-luna`: the parent's `turn/completed` at 9.2 s; the child's `turn/completed` and the parent's `subAgentActivity` `completed` at 29.1 s.
- **Run 2**, model `gpt-6-astra`: the parent's `turn/completed` at 11.2 s; `subAgentActivity` `completed` at 35.3 s.

### Results (observed, runs 1 and 2)

- **The parent thread did not start a turn by itself.** After `subAgentActivity` `completed`, the program wrote no line at all for 120 s: no `turn/started`, no `thread/status/changed`, and no other notification.
- End of file on stdin then ended the program with status 0 within 2 s.
- There was no such turn, so `turn/start` and `turn/steer` during it were not observed.

### Not run

- A wait of more than 120 s; a sub-agent that ends with `failed` or `interrupted`.
