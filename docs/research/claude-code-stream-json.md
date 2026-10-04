# The stream-json protocol of `claude -p`

Research for ticket #10 (Claude Code harness provider). Facts observed on 2026-09-19 from the unmodified Claude Code program, version `2.1.276`, on macOS, signed in with a subscription (`apiKeySource` is `none`). Source: `claude --help`, and four small `-p` runs with `--model haiku` in an empty directory with one text file. The program is closed source, so the facts below are observations of one version, not a contract. Anything marked "not verified" was not run.

## Command line

```text
claude -p --output-format stream-json --verbose [--include-partial-messages]
       [--input-format stream-json] [--model <model>] [--resume <session id>] [-- <prompt>]
```

- `--output-format stream-json` needs `--print` and `--verbose`.
- `--model` takes an alias (`haiku`, `sonnet`, `opus`) or a full name. The `init` line reports the full name (`claude-haiku-4-5-20251001` for `haiku`).
- Two ways to give the prompt, both verified:
  - As an argument. `claude -p ... -- "-Say ok again."` with stdin at `/dev/null` works, and `--` lets the prompt start with a dash. The argument is visible in `ps` and is bounded by the OS argument limit.
  - On stdin with `--input-format stream-json`: one JSON object per line, `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}`. The program runs the prompt and exits with status 0 when stdin reaches end of file.
- `--resume <session id>` continues a harness session. The run reports the same `session_id` as before, so the id is stable over resumes. `--fork-session` exists and gives a new id; not verified.
- `--session-id <uuid>` lets the caller choose the id; verified on `2.1.283` (see "Long-lived session and the control protocol").
- `--permission-mode` choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`. The `init` line reported `default` with no flag. In `-p` mode nobody can answer a permission prompt. The `Read` tool ran without a prompt. On `2.1.283`, `Write` in the default mode without a permission prompt tool is denied with a `system/permission_denied` line (see "Permission requests").
- The user's own hooks, plugins, skills, and `CLAUDE.md` files are active in a `-p` run. `--bare` turns them off, but it also turns off the OAuth login, so it cannot be used with a subscription.

## Output lines

Stdout is one JSON object per line. Every line has `type`, `session_id`, and `uuid`. Stderr was empty on the successful runs.

Observed order for one prompt that made one `Read` tool call, with `--include-partial-messages`:

| `type` / `subtype` | Count | Notes |
|---|---|---|
| `system` / `hook_started`, `hook_response` | 2 each | From the user's own hooks. A `hook_response` line carries the hook's stdout; one was 11,016 bytes. They come before `init` |
| `system` / `init` | 1 | `session_id`, `model`, `cwd`, `tools`, `permissionMode`, `apiKeySource`, `claude_code_version`, and more; 6,495 bytes |
| `system` / `status` | 1 per model call | `"status":"requesting"` |
| `rate_limit_event` | 1 | Position varies: after `init` in one run, before `result` in another |
| `stream_event` | many | Only with `--include-partial-messages`. `event` is a raw Anthropic Messages streaming event: `message_start`, `content_block_start`, `content_block_delta` (`text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta`), `content_block_stop`, `message_delta` (carries `stop_reason`), `message_stop` |
| `assistant` | 1 per content block | See below |
| `user` | 1 per tool result | See below |
| `result` | 1, last | See below |

Without `--include-partial-messages` the same run has no `stream_event` lines; all other lines are the same.

### `assistant`

`message` is an Anthropic Messages assistant message. One line carries exactly one content block. A model response with a thinking block and a tool call is two lines with the same `message.id`. `message.stop_reason` was `null` on every `assistant` line; the stop reason of a response appears only in the `message_delta` stream event. `message.usage` repeats on each line of one response. Top-level `parent_tool_use_id` is `null` for the main loop (a sub-agent sets it; not verified).

Blocks observed: `{"type":"thinking","thinking":"","signature":"..."}` (the thinking text was empty for this model, the signature was not), `{"type":"text","text":"..."}`, and `{"type":"tool_use","id":"toolu_...","name":"Read","input":{...},"caller":{"type":"direct"}}`.

With partial messages on, the `assistant` line of a block arrives after that block's last delta and before its `content_block_stop`.

### `user` (tool result)

```json
{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_...","type":"tool_result","content":"1\thello file\n2\t"}]},"parent_tool_use_id":null,"session_id":"...","tool_use_result":{...}}
```

`content` was a string here. In the Messages format it can also be a list of text and image blocks, and the block can carry `is_error`; neither was observed. `tool_use_result` is a tool-specific structured copy. The tool result line arrived before the `message_delta` and `message_stop` stream events of the response that made the call.

### `result`

The last line. On success: `"subtype":"success"`, `"is_error":false`, `"result"` (the final text), `"stop_reason":"end_turn"`, `"num_turns"`, `"usage"` (`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, and more), `"total_cost_usd"`, `"permission_denials"`, `"session_id"`. Exit status 0.

## A lost harness session

`claude -p ... --resume 11111111-2222-4333-8444-555555555555` (a valid UUID that names no session):

- Exit status 1.
- Stderr: `No conversation found with session ID: 11111111-2222-4333-8444-555555555555`.
- Stdout is one line only, with no `init` before it: `{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"11111111-...","errors":["No conversation found with session ID: 11111111-..."],...}`. The `session_id` is the one that was asked for, not a new one.
- No model call was made (`total_cost_usd` is 0). Nothing ran, so a second run without `--resume` repeats no work.

The only machine-readable sign is the text in `errors`. `error_during_execution` is a general subtype.

## Replay into a fresh session (2026-09-25)

Runs on 2026-09-25 with version `2.1.282`, `--model haiku`, `--input-format stream-json`, the input piped on stdin, and no `--resume`. Each run started a fresh harness session.

- **A `user` line starts a model call; an `assistant` line does not.** With the history `assistant` (text and a `tool_use`), `user` (the `tool_result`), `assistant` (text), `user` (the question), the first `user` line made a model call of its own (it answered `Ready. What's next?`, with its own `init` and `result`), and the question got a second call that knew the replayed history.
- **`"shouldQuery": false` on a `user` line records it with no model call.** Each such line gives one `init` line and one `result` line with `"subtype":"success"`, `"num_turns":0`, `"result":""`, and no `stop_reason`. The `assistant` lines give no output. The last `user` line, without the key, ran one model call that knew every replayed line: a user text, an earlier reply quoted word for word, a `tool_use` with its `tool_result`, and a `tool_result` with `"is_error": true`.
- **The `init` line repeats once per query of the run**, with the same `session_id`.
- **Tool ids.** `toolu_01AAAAAAAAAAAAAAAAAAAAAA` and `call_1` were both accepted as `tool_use` ids with their `tool_result`. The Messages API documents the pattern `^[a-zA-Z0-9_-]+$`; ids with other characters were not tried.
- **A leading `assistant` line** (the replay starts with an assistant reply, with no user line before it) was accepted, and the model used its text.
- **Thinking** was not replayed. The `thinking` blocks of these runs had empty text and a signature bound to the model that made them.

## Signals and resume (2026-09-25)

- **SIGTERM** to a run that had written `init` and started its reply ended it with exit status 143 and no `result` line.
- **A harness session whose run was killed can be resumed.** `--resume <id>` of that session ran the next prompt, and the model knew the prompt of the killed run (a code word given there).
- **A run killed during a tool call can be resumed** (`claude` 2.1.282, `--model haiku`, `bypassPermissions`). The run started `Bash` with `sleep 40`, got `SIGTERM` after its `tool_use` line and before a result, and `--resume <id>` ran the next prompt with no error. The model answered that the outcome of the command was unknown because the session ended before the result was recorded. So Claude Code closes an open tool call of a killed run by itself.
- **The `=` forms `--model=haiku` and `--resume=<id>` work** like the two-word forms. With a lost id, the output is the same as the lost case above: one `result` line, `error_during_execution`, `num_turns` 0, `errors` `["No conversation found with session ID: <id>"]`, and the same text on stderr.
- **`--permission-mode bypassPermissions`**: the `Write` tool ran with no prompt in a `-p` run through `Helyx.Provider.ClaudeCode`, and a `--resume=` turn after it knew the file's content.

## Sizes

No limit is documented for a line. A line holds a whole tool result or a whole hook output, so its size is set by the tool, not by the protocol. The largest line in these runs was 11,016 bytes. The program may write to stderr at any time.

## Not verified

- `cancel_queued: true` during a replay: whether it drops queued replay lines (`shouldQuery: false`). #200 waits for `started` of the turn's line because of this inferred risk (2026-09-27).
- The order of the replay `result` lines and `started` of the next line with a `uuid` for more than one replay user line. #200 observed it for one replay user line only (2026-09-27).
- The `result` line of a run that hits an API error or a usage limit.
- Sub-agent lines (`parent_tool_use_id`), image tool results, and `is_error` tool results in the output (an `is_error` result in the replay was accepted).
- Tool ids with characters outside `[a-zA-Z0-9_-]` in the replay.

## Long-lived session and the control protocol (2026-09-26)

Runs on 2026-09-26 with version `2.1.283`, `--model haiku`, in empty temporary directories: eleven runs driven by a Python script over stdio. Sources: the Python Agent SDK `anthropics/claude-agent-sdk-python` tag `v0.2.160` (commit `36f95486ee9fc49d8ee1ed56811f07b5e8e23ac6`), files `_internal/transport/subprocess_cli.py`, `_internal/query.py`, `_internal/sdk_mcp_bridge.py`, `types.py`; and the TypeScript SDK `@anthropic-ai/claude-agent-sdk@0.3.283` (`sdk.d.ts`, `core.mjs`). "Verified" means a run on `2.1.283`. "Source" means one of these files.

### How the SDKs start the program (source)

- Always `--output-format stream-json --verbose --input-format stream-json`. **No `-p`.** The runs above also worked without `-p` (verified).
- `--permission-prompt-tool stdio` when the host answers permission requests (below). `--mcp-config <json>` for SDK MCP servers. `--resume=<id>` and `--session-id=<id>` always in the `=` form.
- Environment: `CLAUDE_CODE_ENTRYPOINT=sdk-py` (or `sdk-ts`), and `CLAUDECODE` removed.
- The Python SDK passes `--system-prompt ""` when the caller gives no prompt, so the SDK default is not the Claude Code prompt. A harness that wants the Claude Code prompt does not pass it.
- `--setting-sources ""` still loaded a claude.ai connector MCP server; `--strict-mcp-config` removed it (verified).

### One process, many turns (verified)

- One process takes many user lines on one stdin over time. Stdin stays open. Each turn writes `system/init` again, with the same `session_id`, and ends with its own `result` line.
- New `result` fields: `terminal_reason` (`completed`, `aborted_streaming`, `aborted_tools`), `result_index` (0, 1, 2, ... per process), and `queued_turn_count`. `usage` is for the turn. `total_cost_usd` and `modelUsage` add up over the process.
- `--session-id=<uuid>` sets the `session_id` that `init` and `result` report, so the host knows the id before the first line.
- A user line with a `uuid` gives `{"type":"command_lifecycle","command_uuid":"...","state":"queued"|"started"|"completed"}` lines. `--replay-user-messages` echoes each user line with that `uuid` and `"isReplay":true`.
- A string `content` is accepted: `{"type":"user","message":{"role":"user","content":"text"},"parent_tool_use_id":null,"session_id":""}`.
- `init.capabilities` lists features, for example `["interrupt_receipt_v1","interrupt_cancel_queued_v1","msg_lifecycle_v1","mcp_read_resource_v1","mcp_tool_ui_meta_v1"]`. A host can check a feature here instead of a version.
- 2026-10-03, `claude` 2.1.287 (#366): on one process with two turns, each `init` line listed `interrupt_receipt_v1`, `interrupt_cancel_queued_v1`, `interrupt_send_now_v1`, `msg_lifecycle_v1`, `sdk_mcp_tools_list_changed`, `sdk_mcp_manifests`, `mcp_read_resource_v1`, `mcp_tool_ui_meta_v1`, and `ui_surface_v1`. Each `result` had `num_turns` 1.
- **End of file on stdin.** When idle, the program exits with status 0 in about 0.5 s. When a turn runs with a message queued, it finishes the queued turns, writes their `result` lines, and then exits with status 0.

### A user line during a turn (verified)

- **During a tool call**, the line joins the running turn after the tool results. This is a steer: one `result` with `num_turns: 2`, and the reply obeyed the new line.
- **During the final text answer**, the line waits and runs as the next turn, with its own `result`.
- **`"priority":"now"`** on the user line (a field of the TypeScript `SDKUserMessage`, values `now`, `next`, `later`; not documented) stopped the running answer at once. The stopped turn gave `"subtype":"success"`, `"terminal_reason":"aborted_streaming"`, and the partial text in `result`. The new line then ran as the next turn.

### Control messages

Host to program (source, verified for the subtypes marked below):

```json
{"type":"control_request","request_id":"req_1_ab12cd34","request":{"subtype":"interrupt"}}
```

Program to host:

```json
{"type":"control_response","response":{"subtype":"success","request_id":"req_1_ab12cd34","response":{}}}
```

An error answer is `{"subtype":"error","request_id":...,"error":"text"}`. The host chooses its own request ids. The program's own requests use UUIDs, and the host answers with the same `request_id` in a `control_response`. A host answers a subtype that it does not support with `subtype: "error"` (source). The program can withdraw a pending request with `{"type":"control_cancel_request","request_id":...}` (source; not observed).

| Subtype, host to program | Status | Notes |
|---|---|---|
| `initialize` | verified | `{"subtype":"initialize","hooks":null}`; optional `agents`, `skills`, and more. The response has `commands`, `agents`, `models` (aliases and full names), `account`, `pid`, `current_permission_mode`, and `session_state` |
| `interrupt` | verified | The response is `{"still_queued":[<uuids>]}`. Queued user lines are kept and run next. The TypeScript SDK adds `cancel_queued: true` to drop them (source) |
| `set_model` | verified | `{"subtype":"set_model","model":"sonnet"}`. The program echoes a `user` line with `<local-command-stdout>Set model to ...`. The next turn ran on the new model and knew the earlier context |
| `mcp_status` | verified | The state and tools of each MCP server |
| `set_permission_mode`, `rewind_files`, `mcp_reconnect`, `mcp_toggle`, `stop_task`, `get_context_usage` | source | Not verified |

Program-to-host subtypes: `can_use_tool` and `mcp_message` (verified), `hook_callback` and `elicitation` (source).

### Interrupt (verified)

- **During streamed text:** the `control_response`, the partial `assistant` line, a `user` line `[Request interrupted by user]`, then `"subtype":"error_during_execution"`, `"is_error":true`, `"terminal_reason":"aborted_streaming"`. The `result` came about 50 ms after the request.
- **During a foreground `Bash` call:** `system/task_notification` with `"status":"stopped"`, an `is_error` tool result, a `user` line `[Request interrupted by user for tool use]`, then `error_during_execution` with `"terminal_reason":"aborted_tools"`. The `sleep` child was gone 1 s later.
- **A background `Bash` task survives an interrupt.**
- In each case the process stayed alive, and the next user line ran with the full context.
- So `is_error` with `terminal_reason` `aborted_*` is an abort, not a failure.

### Permission requests (verified)

- The program asks the host only with `--permission-prompt-tool stdio`. Without the flag, in the default mode, `Write` was denied with no request: a `{"type":"system","subtype":"permission_denied","tool_name":"Write",...}` line and an `is_error` tool result. A read-only command (`echo`) was not asked.
- Request: `{"type":"control_request","request_id":"<uuid>","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"touch original.txt",...},"permission_suggestions":[...],"blocked_path":"...","tool_use_id":"toolu_..."}}`.
- Allow: `{"behavior":"allow","updatedInput":{...}}`, with optional `updatedPermissions`. A changed input ran as changed. **The `assistant` `tool_use` line keeps the original input**, so a host that changes the input must record the changed input itself.
- Deny: `{"behavior":"deny","message":"..."}` gives an `is_error` tool result with that text and an entry in `result.permission_denials`. An optional `"interrupt": true` also stops the turn (source).
- The program can send the next `can_use_tool` before the result of the earlier tool.

### Background tasks (verified 2026-09-29, `claude` 2.1.284)

- A `Bash` call with `run_in_background: true` (`haiku`, `sleep 12`) gave `{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"bm9v5qfnr","task_type":"local_bash","description":"sleep 12"}],"uuid":...,"session_id":...}`, then `{"type":"system","subtype":"task_started","task_id":"bm9v5qfnr","tool_use_id":...,"description":"sleep 12","is_backgrounded":true,"task_type":"local_bash",...}`.
- When the command ended, after the turn's `result`: `background_tasks_changed` with `"tasks":[]`, then `task_updated` with `"patch":{"status":"completed","end_time":...}`, then `task_notification` with `"status":"completed"`.
- The program's schema (source, 2.1.284) describes `background_tasks_changed` as "The full set of live background tasks, emitted whenever membership changes (start, completion, kill, a foreground agent being backgrounded) or an entry's `ambient` flag flips", with "REPLACE semantics", "a level signal, unlike the task_started/task_notification edges". An entry has `task_id`, `task_type`, `description`, and an optional `ambient` flag (a housekeeping task). `task_updated.patch.status` is one of `pending`, `running`, `completed`, `failed`, `killed`, `paused`.
- The `task_notification` of the ended command started a program turn with no user line: an `init`, an assistant message ("The background command has completed."), and a `result`, while the host sent nothing. In the same run the model had also called `ScheduleWakeup`.

### Host tools through an SDK MCP server (verified)

- `--mcp-config '{"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}}' --strict-mcp-config`.
- The program sends MCP JSON-RPC inside `mcp_message` control requests: `{"subtype":"mcp_message","server_name":"helyx","message":{"jsonrpc":"2.0","id":0,"method":"initialize",...}}`. The host answers `{"subtype":"success","request_id":...,"response":{"mcp_response":{"jsonrpc":"2.0","id":0,"result":{...}}}}`.
- Order: `initialize`, `notifications/initialized`, `tools/list`, then `tools/call` with `{"name":"secret_word","arguments":{...},"_meta":{"claudecode/toolUseId":"toolu_...","progressToken":2}}`.
- The model sees the tool as `mcp__helyx__secret_word`. A reply `{"content":[{"type":"text","text":"..."}]}` became an ordinary tool result.
- MCP tools are deferred: the model called `ToolSearch` before it called the tool. On `2.1.288`, with `alwaysLoad: true` on the server, the model called the tool without `ToolSearch` (observed, 1 run; see "`alwaysLoad` on the SDK MCP server").
- This needs no HTTP server and no extra process.

### Processes (verified)

- The `Bash` tool runs each command as `/bin/zsh -c ...` with the program as its parent and **in a process group of its own** (pgid equal to its pid). A signal to the program's group does not reach it.
- `SIGTERM` to the program: exit status 143 in about 0.7 s. It first killed its background tasks (`task_updated` with `"status":"killed"`), and no child was left.
- End of input to the program with a running background task (2026-09-27, `claude` 2.1.283, `haiku`, a Helyx session close, 3 runs): the background command was gone after each close. In the 2 timed runs the close took 615 and 628 ms, under the 5,000 ms close bound, so no TERM reached the program before it exited. The test did not check the process group of the background command. If it has a group of its own, as the `Bash` commands above had, a signal to the program's group does not reach it, and the program ended it (inferred).
- `SIGKILL` to the program: the foreground `zsh` and its `sleep` were left running with parent 1.
- The SDKs close the program with end of file on stdin, then `SIGTERM`, then `SIGKILL`. Python waits 5 s before each signal. TypeScript waits 2 s before `SIGTERM` and 5 s before `SIGKILL`. Neither starts the program in a new process group (source).

### Helyx abort with a command in its own group (2026-09-26)

Four aborts through `Helyx.Session.abort/1` with `Helyx.Provider.ClaudeCode` (`2.1.283`, `haiku` and `sonnet`): a foreground `python3 -c "import time; time.sleep(90)"`, and in one run a background task of the same kind. Each abort returned in 537 to 613 ms, and `ps` found no process of the command 2 s later. The watchdog TERMs the program's group and KILLs it after 500 ms. The program ends its commands on the TERM within that time. The margin is small: a program with more children, or a slower machine, can need more than 500 ms, and a KILL then leaves the command groups running. `Helyx.Provider.Codex` already uses a TERM grace of 5 s for the same reason.

## Verify before implementation (2026-09-27)

Runs on 2026-09-27 with version `2.1.283`, `--model haiku`, in empty temporary directories, for the list "Verify before implementation" in `docs/features/long-lived-harness.md`. A Python script drove the program over stdio with the flags of the design: `--output-format stream-json --verbose --input-format stream-json --include-partial-messages --permission-mode bypassPermissions --replay-user-messages --strict-mcp-config`, no `-p`. Each program ran in a new session (its own process group). Times are the times at which the script read the line.

### The signal that the program took a steer line (verified, 2 kinds, 1 run each, and the 24 turns below)

- A line with a `uuid` gives `command_lifecycle` `queued` at once when the program reads it, in every run.
- **During a tool call** (a steer into the running turn): after the tool result, the replay echo of the `uuid` came first, then `command_lifecycle` `started` 10 ms later, then the next model call. `completed` came just before the `result`. The `result` had `num_turns` 2.
- **During the final text** (the line runs as the next turn): the `result` of the running turn came first, then `started` at the same millisecond, then the echo 1.07 s later, just before the `message_start` of the new model call. `completed` came after the `result` of the new turn.
- So `started` comes within 10 ms of the tool result or of the `result` after which the program takes the line. The echo comes when the program writes the new request to the model, 0.7 to 1.8 s after the `result` in these runs.

### `queued_turn_count` (verified, every `result` of these runs)

- Every `result` in these runs had `queued_turn_count` 0, also when a line was queued before the `result` (`command_lifecycle` `queued` 1.3 s before it). The field does not show a queued user line.

### Interrupt with `cancel_queued: true` while a steer line waits (verified, 4 runs)

- Two runs during the final text, two during a foreground `Bash` `sleep 20`. The steer line had `command_lifecycle` `queued`, then the script sent `{"subtype":"interrupt","cancel_queued":true}`.
- The response: `{"still_queued":[],"cancelled":["<uuid>"]}`. The `cancelled` list is new. Before the response, `command_lifecycle` `cancelled` for the `uuid`.
- Then the `result` with `error_during_execution` and `terminal_reason` `aborted_streaming` or `aborted_tools`, with `queued_turn_count` 0. No echo and no `started` for the `uuid`, and no other `result` in 8 s.
- The next user line ran as usual on the same process.
- `init.capabilities` listed `interrupt_cancel_queued_v1` in each run.

### A steer at the end of a turn (verified, 3 × 8 turns in 3 processes)

- The script sent `Reply with just OK<i>.`, then wrote the steer line with a `uuid` at one of three points: at the `message_stop` stream event of the answer, at the `assistant` text line, or after the `result`.
- At `message_stop`: in 4 of 8 turns the program read the line (`queued`) after it wrote the `result`; in 4 of 8 before. At the `assistant` line: 8 of 8 before the `result`, 0 to 30 ms before it. After the `result`: the line was read at once.
- In all 24 turns the `result` of the first turn had `queued_turn_count` 0 and `num_turns` 1, and the line then ran as a turn of its own with its own `result`. It never joined the finished turn.
- Gaps after that `result`, in the 16 turns where the line was written before it: `started` 0 to 10 ms; the echo 0.65 to 1.77 s; the `result` of the steer turn 0.89 to 2.06 s.
- The provider tests of the two orders (`:rejected` with nothing written; the terminal that waits for the echo) need the provider. They are not part of this run.

### `_meta["claudecode/toolUseId"]` (verified, 3 runs)

- In each run the `tools/call` of the SDK MCP server had `"_meta":{"claudecode/toolUseId":"toolu_...","progressToken":2}`, and the id equalled the `id` of the `tool_use` block `mcp__helyx__secret_word` in the `assistant` line.

### An open `mcp_message` at an interrupt (verified, 3 runs)

- The script did not answer a `tools/call` and sent `interrupt` 2 s later.
- The program sent **no** `control_cancel_request`. It sent a new `mcp_message` control request with the MCP notification `{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3,"reason":"AbortError: remote-cancel"}}`, where `requestId` is the JSON-RPC id of the open `tools/call`. Then the interrupt response, an `is_error` tool result, `[Request interrupted by user for tool use]`, and the `result` with `aborted_tools`.
- A late answer to the open `tools/call`, 3 s after the `result`, gave no error and no line other than its echo. The next turn ran as usual.
- With `--replay-user-messages`, the program also echoes each `control_response` that the host writes, as an output line of type `control_response`.
- When the program sends `control_cancel_request` was not found.

### `SIGTERM` to the group while a user line is queued (verified, 6 runs)

- Three runs during the final text, three during a foreground `Bash` `sleep 25`. The queued line asked the model to run `touch <marker>` with `Bash`. The script sent `SIGTERM` to the program's process group 0.3 s after `command_lifecycle` `queued`.
- Each run: exit status 143 after 0.87 to 1.68 s. The only `command_lifecycle` line of the `uuid` was `queued`: no `started`. No marker file 3 s after the exit. No `sleep 25` left.

### Not run

- The stop path end to end with the watchdog stdin cap: the cap is ticket #196, which is open. The TERM half of the path is the run above.

## The connected provider (2026-09-27, #200)

Runs on 2026-09-27 with version `2.1.283`, `--model haiku`, for ticket #200. A Python script drove the program with the flags of `Helyx.Provider.ClaudeCode` (`--output-format stream-json --verbose --include-partial-messages --input-format stream-json --permission-mode bypassPermissions`) and `--strict-mcp-config`, with no `-p`, and no `--replay-user-messages`.

- **A lost `--resume` without `-p`.** With a valid UUID that names no session, the program wrote one `result` line about 0.9 s after the start, before any input: `error_during_execution`, `num_turns` 0, no `init` before it, and `errors` `["No conversation found with session ID: <id>"]`. Then exit status 1. So the lost case is the same as with `-p`, and it comes without a user line.
- **A fresh idle program** (`--session-id`, no input for 2 s) wrote only hook lines. No `init` comes before the first user line.
- **Replay lines.** Each `user` line with `"shouldQuery": false` gave an `init` line and a `result` with `"subtype":"success"`, `num_turns` 0, and no `terminal_reason`.
- **The replay comes before the turn's line.** With one replay `user` line and one `assistant` line, then the prompt with a `uuid`: `queued` of the prompt, one `init`, the replay `result`, then `started` of the prompt, all within 10 ms. So the result of a replay line comes before `started` of the next line with a `uuid`.
- **`command_lifecycle`** `queued`, `started`, and `completed` came for a user line with a `uuid` also without `--replay-user-messages`.
- **An interrupt while idle** (after the `result` of a turn) got a success `control_response` with `still_queued` `[]` and `cancelled` `[]`. No `result` followed.
- **An abort during a foreground command.** The `control_response` came first, then the `result` with `terminal_reason` `aborted_tools`. The process stayed, and the next user line ran on it.
- **An interrupt 50 ms after the prompt** cancelled the prompt: `cancelled` held its `uuid`, and no `result` came for it. The next user line ran as usual.
- **The `Bash` tool refused a standalone `sleep 37`** and suggested a background run. A foreground `python3 -c "import time; time.sleep(37)"` ran, so the manual abort test of #200 uses it.

## Sub-agents at the end of a turn (2026-09-29, #226)

Runs on 2026-09-29 with version `2.1.284`, `--model haiku`, for ticket #226. A Python script drove the program with the flags of `Helyx.Provider.ClaudeCode` (`--output-format stream-json --verbose --include-partial-messages --input-format stream-json --permission-mode bypassPermissions --model=haiku --session-id=<uuid>`) and `--strict-mcp-config`, each program in a new session (its own process group), in an empty temporary directory. The user's own hooks were active. The prompt asked the model to use the `Agent` tool once; the sub-agent ran a foreground `python3 -c "import time; time.sleep(40)" <marker>`. `ps` looked for the marker. 5 runs; a sixth run is not counted because the model refused the prompt. "Verified" means one of these runs, not a contract.

### The tool and its lines (verified, 5 runs)

- The tool is `Agent` (the older name `Task` did not appear). Its input: `subagent_type`, `description`, `prompt`, and optional `run_in_background`.
- **A sub-agent's own lines carry `parent_tool_use_id`**, the `id` of the `Agent` `tool_use` block. Observed: `assistant` lines (thinking, text, `tool_use`), `user` lines (tool results, and in a foreground run the sub-agent's prompt as a `text` block), and `tool_progress` with `"heartbeat":true` every 30 s (`tool_use_id` `<Agent id>-heartbeat-0`). The `Agent` `tool_use` and its tool result have `parent_tool_use_id` `null`.
- **A sub-agent writes no `result` line.** Its end is `system/task_updated` (`patch.status` `completed` or `killed`) and `system/task_notification` with `task_id`, `tool_use_id` (the `Agent` id), `status` (`completed` or `stopped`), `output_file`, `summary`, and on completion `usage` (`total_tokens`, `tool_uses`, `duration_ms`).
- Other `system` lines: `task_started` (`task_id`, `tool_use_id`, `subagent_type`, `is_backgrounded`, `spawn_depth`, `task_type` `local_agent`, `prompt`), `task_progress` (`usage`, `last_tool_name`), and `background_tasks_changed` (the list of background tasks) for a background sub-agent. A `Bash` command of a sub-agent is a task of its own: `task_started` with `"owned_by_subagent":true` and `task_type` `local_bash`.
- **Every `result` has `subagent_stats`**: `spawned`, `requested` (`background`, `foreground`, `unset`), `started_in_background`, `max_depth`, `spawned_by_subagents`, `completed`, `failed`, `killed` (`parent`, `user`, `system`), `refused`, `by_type`.

### Foreground and background (verified)

- **Foreground** (`run_in_background` `false`; 2 runs): the `Agent` tool result comes when the sub-agent ends. Its `content` is a text block that starts `[Subagent hand-back]` and holds the report and the `agentId`. `tool_use_result` has `status` `completed`, `agentId`, `agentType`, `content`, `totalDurationMs`, `totalTokens`, `totalToolUseCount`, `toolStats`, `usage`, and `resolvedModel`. The turn's `result` comes after it.
- **Background** (`run_in_background` `true` in 1 run, unset in 2 runs): the tool result comes at once, `"Async agent launched successfully"`, with `tool_use_result` `{"isAsync":true,"status":"async_launched","agentId",...,"outputFile"}`. With the input unset, `task_started` said `is_backgrounded` `true` and `subagent_stats` counted `unset` 1 and `started_in_background` 1. So an unset input can start a background sub-agent in this version. It is not known if a user setting causes this.
- **A background sub-agent outlives its turn.** In 2 runs the turn's `result` came while the sub-agent ran. Its lines with `parent_tool_use_id` then came after the `result` and after `command_lifecycle` `completed`, with no turn open. `ps` found its command 4 s after the `result`. In the third run the sub-agent ended before the turn's `result`, and its lines came between the main loop's lines.
- **The end of a background sub-agent starts a turn without a user line** (1 run, host idle). After `task_notification` `completed`, the program wrote `system/init`, `status`, the model's `assistant` lines, and a `result` with `"origin":{"kind":"task-notification","producer":"session-task"}` and no `user_message_uuid`. No `command_lifecycle` line came for it.

### Interrupt with `cancel_queued: true` (verified, 2 runs)

- **During a foreground sub-agent's command** (1 run): the `control_response` (`still_queued` `[]`, `cancelled` `[]`) came at once. Then the `Agent` tool result with `is_error` and the rejection text, `task_updated` `killed`, `task_notification` `stopped`, `[Request interrupted by user for tool use]`, and `result` `error_during_execution` with `terminal_reason` `aborted_tools` and `subagent_stats.killed.user` 1. `command_lifecycle` of the user line said `cancelled`. The command was gone 1 s later.
- **While idle, with a background sub-agent running** (1 run, sent 5 s after the turn's `result`): `task_updated` `killed`, `task_notification` `stopped`, then the `control_response` (`still_queued` `[]`, `cancelled` `[]`). The sub-agent's `Bash` got an `is_error` tool result with `parent_tool_use_id` set, then `[Request interrupted by user for tool use]`, also with `parent_tool_use_id`. **No `result` line came.** The command was gone 1 s later. No task-notification turn followed in 46 s.
- So in these runs an interrupt ended every running sub-agent, foreground or background. The earlier note "A background `Bash` task survives an interrupt" is for a `Bash` task of the main loop; it was not run again here.

### `SIGTERM` (verified, 5 runs)

- `SIGTERM` to the program's group: exit status 143 after 0.71 to 0.83 s in each run. In the run with a background sub-agent's command still running, the program first wrote `task_notification` `stopped` for the command's task and an `is_error` tool result `Exit code 137` to the sub-agent. `ps` found no marker process 1 s after the exit.
- The sub-agent's command ran as `python3` under a shell, in the shell's process group, not in the program's group (pgid equal to the shell's pid). This is the same as a main-loop command.

### Not run

- A sub-agent that starts a sub-agent (`spawn_depth` 2), `stop_task` on a sub-agent's `task_id`, and `SIGKILL` with a sub-agent running.
- `SendMessage` to continue a finished sub-agent (the hand-back text names it).

## Program turns (2026-09-30, #240)

Runs on 2026-09-30 with version `2.1.284`, `--model=haiku` (the `init` line reported `claude-haiku-4-5-20251001`), for ticket #240. A Python script drove the program with the flags of `Helyx.Provider.ClaudeCode` (`--output-format stream-json --verbose --include-partial-messages --input-format stream-json --permission-mode bypassPermissions --model=haiku --session-id=<uuid>`) and `--strict-mcp-config`, with no `-p` and no `--replay-user-messages`. Each program ran in a new session (its own process group), in an empty temporary directory. The user's own hooks were active. In each run the prompt (a user line with a `uuid`) asked the model to start `sleep 6` with `Bash` and `run_in_background: true`, reply, and end its turn. A "program turn" is the turn that the program starts by itself when the background task ends. "Observed" means one of these runs, not a contract.

- **Run A**: the prompt only. At the first `message_start` of the program turn, the script sent a second user line with a `uuid`. End of input 8 s after the last `result`.
- **Run B**: replay first: a `user` line with `"shouldQuery": false`, then two `assistant` lines (code word A, code word B). Then the prompt, which also asked for the code words. End of input at the first `message_start` of the program turn.
- **Run C**: replay first: `user` (`shouldQuery: false`), `assistant` (code word A), `user` (`shouldQuery: false`), `assistant` (code word B), `assistant` (code word C). Then the prompt, which also asked for the code words. End of input at the `task_notification` line.

### The end of a background command (observed, A, B, C)

- After the turn's `result`, when the command ended, three lines came within 1 ms: `background_tasks_changed` with `"tasks":[]`, `task_updated` with `patch.status` `completed`, then `task_notification` with `status` `completed`.
- 100 to 150 ms later the program turn started: `system/init`, `status` `requesting`, the stream events and `assistant` lines, then a `result` with `"origin":{"kind":"task-notification","producer":"session-task"}`, `"user_message_uuid":null`, `terminal_reason` `completed`, `num_turns` 1, and the next `result_index`.
- No `command_lifecycle` line came for the program turn.
- The ending task was a `Bash` task of the main loop. A background sub-agent as the ending task was not run today; the one run in "Sub-agents at the end of a turn" had the same `task_notification`, then `init`.

### The user line of a program turn (observed, A, B, C)

- **On stdout, the program turn has no `user` line.** The first line after `task_notification` is its `init`.
- **In the program's own session file, the program turn has a `user` entry** with `"origin":{"kind":"task-notification",...}` and string content `<task-notification><task-id>...</task-id><tool-use-id>...</tool-use-id><output-file>...`. The `assistant` entries of the program turn have that entry as their parent.
- Not observed: the output with `--replay-user-messages`.

### `started` of a normal turn (observed, A, B, C)

- For the prompt: `command_lifecycle` `queued`, `started` 3 to 33 ms later, then `init`, `status`, and `message_start`. So `started` came before every model line of the turn.
- In B and C the `result` lines of the replay came between `queued` and `started`, as in "The connected provider".

### A user line during a program turn (observed, A, 1 run)

- The line was sent at the first `message_start` of the program turn. The program turn had no tool call, so the line came during its text answer.
- `command_lifecycle` `queued` came at once. The line did not join the program turn.
- The program turn ended with its own `result`: `origin` task-notification, `user_message_uuid` `null`, `result_index` 1.
- `started` of the line came 1 ms after that `result`, then a new `init`. The line ran as a turn of its own. Its `result` had `user_message_uuid` equal to the line's `uuid`, `origin` `null`, and `result_index` 2. Then `completed`.
- Not observed: a user line during a tool call of a program turn.

### End of input during a program turn (observed, B and C)

- **B**, end of input at the first `message_start` of the program turn: the program finished the turn, wrote its `result` with `origin`, and exited with status 0 0.65 s after that `result`.
- **C**, end of input at `task_notification`, before the program turn's `init`: the program still started the program turn 150 ms later, wrote its `result` with `origin`, and exited with status 0 0.65 s after that `result`.
- Not observed: end of input while a background task still runs, or after `background_tasks_changed` and before `task_notification`.

### Consecutive `assistant` lines in a replay (observed, B and C)

- **The model used the text of every replayed `assistant` line.** B answered `RED` and `BLUE`; C answered `RED, BLUE, GREEN.`. So two or three consecutive `assistant` lines were accepted.
- Each replayed `user` line gave one `result` (`num_turns` 0, no `terminal_reason`): one in B, two in C. The `assistant` lines gave no output.
- **The session file does not keep the replay order.** In B and C every replayed `assistant` entry comes before the first replayed `user` entry, and the `parentUuid` chain follows the order of the file. C's input order was `user`, `assistant` A, `user`, `assistant` B, `assistant` C. The file order was `assistant` A, `assistant` B, `assistant` C, `user`, `user`, then the prompt.
- Inferred, not observed: the program writes an `assistant` input line to the file when it reads the line, and writes a `user` input line when it takes the line from its command queue (the file has `queue-operation` entries for it).
- **The request to the model was not observed.** So it is not known if the model got the replay in the input order or in the file order. A `--resume` of such a session was not run.

### Not run

- A background sub-agent as the ending task; two background tasks that end at the same time.
- An `interrupt` during a program turn.

## The SDK MCP server shapes (2026-09-29, #203)

Runs on 2026-09-29 with version `2.1.284`, `--model haiku`, for ticket #203. A Python script drove the program with the flags of `Helyx.Provider.ClaudeCode` (`--output-format stream-json --verbose --include-partial-messages --input-format stream-json --permission-mode bypassPermissions --model=haiku --session-id=<uuid>`) and `--mcp-config '{"mcpServers":{"helyx":{"type":"sdk","name":"helyx"}}}'`, with no `--strict-mcp-config`, in a new session (its own process group), in an empty temporary directory. The host offered one tool, `secret_word`, with no input. 4 runs; two runs had two turns. "Verified" means one of these runs, not a contract. "Source only" means the Python Agent SDK at the commit named in "Long-lived session and the control protocol" (`_internal/query.py`, `_internal/sdk_mcp_bridge.py`) or the MCP specification, not a run.

### The handshake (verified, 4 runs)

- `initialize` came as `{"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code",...,"version":"2.1.284"}},"jsonrpc":"2.0","id":0}`, about 1 s after the first user line.
- The program accepted the result `{"protocolVersion":<the asked version>,"capabilities":{"tools":{}},"serverInfo":{"name":"helyx","version":"0.1.0"}}`. The `init` line then listed `{"name":"helyx","status":"connected","source":"sdk"}` in `mcp_servers`.
- `notifications/initialized` came in its own `mcp_message` with no `id`. The host answered the control request with `"response":{"mcp_response":{"jsonrpc":"2.0","result":{}}}`, the SDK's ack for a notification (source). Then `tools/list` came at once.
- The program accepted the `tools/list` result `{"tools":[{"name":"secret_word","description":"...","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}]}`. The model saw `mcp__helyx__secret_word` after `ToolSearch`.
- **No ack for `notifications/initialized`** (1 run): the program waited 30 s, then sent `initialize` again with the next control request id and `notifications/initialized` again. After 30 more seconds with no ack, the server did not connect, and `ToolSearch` said that the configured MCP servers failed to connect. So the ack is needed, and **`initialize` can come more than once per program**. No `control_cancel_request` came for the abandoned control requests.
- With the ack, `initialize` came once per program, also over two turns (3 runs).

### Tool errors (verified, 2 runs, 2 calls each)

- A result `{"content":[{"type":"text","text":"<text>"}],"isError":true}` gave the tool result `{"type":"tool_result","content":"<text>","is_error":true,"tool_use_id":...}`, and `tool_use_result` `"Error: <text>"`. The model repeated the text.
- A JSON-RPC error `{"jsonrpc":"2.0","id":<id>,"error":{"code":-32603,"message":"<text>"}}` gave the same tool result: `is_error` `true` and the message as the content.
- So the model sees the text in both cases, and the transcript cannot tell them apart.

### An open `tools/call` at an interrupt (verified, 1 run)

- Same as the run of 2026-09-27: the program sent `notifications/cancelled` with `params.requestId` equal to the JSON-RPC id of the open `tools/call` and `reason` `"AbortError: remote-cancel"`, in a new `mcp_message` control request. The host acked it with `{"jsonrpc":"2.0","result":{}}`. Then the interrupt response (`still_queued` `[]`, `cancelled` `[]`), an `is_error` tool result with the rejection text, `[Request interrupted by user for tool use]`, and the `result`.
- The program sent no `control_cancel_request`. Its exit status after the end of input was 1 in this run; the cause was not looked for.

### `control_cancel_request` (source only)

- Not seen in any run. The SDK cancels the work of the pending control request with that `request_id` and writes **no** `control_response` for it: "the CLI has already abandoned this request".

### Not run

- Whether the program sends `initialize` again after a successful handshake, for example after `mcp_reconnect`.
- A `tools/call` with arguments, and many calls at once.
- A successful result with `"isError":false` (source only: the probes sent only `isError` `true`). The MCP schema has `isError` as an optional boolean.
- A JSON-RPC error `-32601` for an unknown method (source only: the program sent no unknown method in the probes).

## The order of a replay (2026-09-30, #248)

Runs on 2026-09-30 with version `2.1.284` and `--model=haiku`, for ticket #248. A Python script started the program with the flags of `Helyx.Provider.ClaudeCode` and `--strict-mcp-config`, in a new session and an empty temporary directory. The user's own hooks were active. The input was the replay form of the provider: `user` (`shouldQuery: false`, question one), `assistant` (answer one), `user` (`shouldQuery: false`, question two), `assistant` (answer two), then the prompt. The prompt asked the model to list the earlier messages in order, and to say which question came just before each answer. In runs 1 and 3, `ANTHROPIC_BASE_URL` named a local proxy. The proxy wrote the roles and texts of each request body to a log, and sent the request on to the API.

- **Run 1** (proxy): the script wrote all five lines at once, as the provider does.
- **Run 2** (no proxy): the same as run 1.
- **Run 3** (proxy): the script wrote each `assistant` line only after the `result` of the replayed `user` line before it. It wrote question one; after its `result`, answer one and question two; after that `result`, answer two and the prompt.

### The request of runs 1 and 3 (observed, 1 run each)

- **Run 1: the request did not keep the input order.** Its `messages` were: `user` (the text of a `SessionStart` hook only), `assistant` (answer one), `assistant` (answer two), then one `user` message with the system reminders, question one, question two, and the prompt. The two answers were two `assistant` messages in sequence. The two questions and the prompt were blocks of one `user` message.
- **Run 3: the request kept the input order.** Its `messages` were: `user` (system reminders, then question one), `assistant` (answer one), `user` (question two), `assistant` (answer two), `user` (system reminders, then the prompt).
- Each run made one request to the model.

### What the model said (observed, runs 1, 2, 3)

- **Runs 1 and 2: the model saw the wrong order.** It listed both answers before the questions, and said that no question came before either answer.
- **Run 3: the model saw the input order.** It listed question one, answer one, question two, answer two, and paired each answer with the question before it.
- So the proxy did not cause the order of run 1. Run 2 had no proxy and gave the same answer.

### Not run

- A replay with a `tool_use` and its `tool_result`.
- A replay that starts with an `assistant` line, or that has two `assistant` lines in sequence, with the wait of run 3.
- A `--resume` of a session that has the wrong order.

## `alwaysLoad` on the SDK MCP server (2026-10-04, #472)

One run on 2026-10-04 with version `2.1.288`, `--model haiku`, in an empty temporary directory. A Python script drove the program with `--output-format stream-json --verbose --input-format stream-json --permission-mode bypassPermissions --model=haiku --session-id=<uuid>` and `--mcp-config '{"mcpServers":{"helyx":{"type":"sdk","name":"helyx","alwaysLoad":true}}}'`. These are the flags of `Helyx.Provider.ClaudeCode` without `--include-partial-messages`. There was no `--strict-mcp-config`. The host offered one tool, `bash`, with a `command` string. The prompt asked the model to run `echo hi` with the bash tool of the helyx server. Source of the key: Claude Code docs, "Scale with MCP tool search", code.claude.com/docs/en/mcp, read 2026-10-04.

### What the run showed (observed, 1 run)

- The program did not reject the key on a server of type `sdk`. The handshake was the same as in "The SDK MCP server shapes": `initialize`, `notifications/initialized`, `tools/list`.
- The `init` line listed `{"name":"helyx","status":"connected","source":"sdk"}` in `mcp_servers`, and `mcp__helyx__bash` in `tools`.
- The first tool call of the model was `mcp__helyx__bash` with `{"command":"echo hi"}`. No `ToolSearch` call came before it. The `result` had `subtype` `success` and `num_turns` 2, and the reply was `hi`. The program exited with status 0 after the end of input.

### Not run

- The same run without the key on `2.1.288`. The deferral without the key was observed on `2.1.284` ("Host tools through an SDK MCP server").
