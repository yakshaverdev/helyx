# The command hook

Ticket #883, follow-up 5 of ADR 0013 (`docs/adr/0013-hooks.md`, §8). The ADR holds the decisions and their reasons: the exit code meanings, the fail rule of each point (§5), the process group and its release (§3). This doc sets what the ADR leaves to it: the config, the JSON on standard input, the answer shapes on standard output, and the output bound. The `before_settle` point (#880, `docs/features/before-settle.md`) runs the command as a `Stop` hook.

## Goal

A user runs a hook script, such as one written for Claude Code, before and after each Helyx tool call, and before the session settles, with no Elixir code: `Helyx.Hook.Command` is a bundled hook plugin that runs a command from its config at a point and maps its exit code and its output to an answer of the point (`docs/features/hooks.md`).

## Interface changes

### Config

The plugin reads the application env key `:command_hook` of `helyx_plugins` (AGENTS.md, "Module naming"):

```elixir
config :helyx_plugins, :command_hook,
  before_tool: [command: "~/.helyx/hooks/check.sh", limit_ms: 30_000, tools: ["bash"]],
  after_tool: [command: "jq -c . >> /tmp/calls.log"],
  before_settle: [command: "mix test >&2 || exit 2", limit_ms: 300_000]
```

- The value is a keyword list whose keys are points, `:before_tool`, `:after_tool`, and `:before_settle`. The value of a point is a keyword list: `command`, a non-empty string of valid UTF-8 with no NUL byte, required; `limit_ms`, the limit of the hook at the point; and at the two tool points `tools`, a list of tool names, strings. `before_settle` runs for no tool, so `tools` is an unknown key there.
- A point with no entry, and a call whose tool is not in the `tools` of the point, get the default answer at once (`:allow`, `:keep`, `:settle`) and run no command. No `tools` is every tool. A key that is there has a value of its type: `nil` is no value, so `before_tool: nil` and `tools: nil` are a broken config (below), not a missing key.
- `tools` is a filter of the config, not of the model: a command for `bash` only runs for no other call, which saves a process start for each call of another tool and lets a script written for one tool stay as it is. A script can also filter by `tool_name` itself.
- `limit/1` gives the `limit_ms` of the point as the config has it, and 60,000 when the point or its `limit_ms` is missing, or when the top or the entry of the point is broken (the run then reports it): the default is a minute, since a `before_tool` command holds its call while it runs, and a longer check sets its own. Core reads it once at its start and checks it (`docs/features/hooks.md`, "Core start"), so a `limit_ms` that is not an integer from 1 to 600,000, `nil` included, stops the start with `{:invalid_hook_limit, Helyx.Hook.Command}`. A change of the env after the start changes the command, not the limit.
- The rest of the config is read at each run of the hook. At each run the top of the value and the entry of the point are checked, the smallest unit that the run reads (AGENTS.md). A top that is not of this shape (not a keyword list, a key that is not a point, a point twice) is a failed hook at each point; an entry that is not (not a keyword list, `nil` included, any other key, a key twice, no `command`, a value of another type, `nil` included) is a failed hook at its point (ADR 0013 §5): `before_tool` denies the call with the reason `its config :command_hook is invalid: <path>`, `after_tool` keeps the result with a notice, and `before_settle` settles with a notice. Reason: a broken gate must not let a call through, and a run time check gives the path of the bad value, where a Core start error could only name the limit.

### The run

- The command runs as `bash -c <command>` in the `cwd` of its input, the session folder: of the call at the tool points, and of the session at `before_settle` (decision of 2026-11-08: Core gives the `before_settle` hooks the session folder, `docs/features/before-settle.md`), in its own process group under the perl watchdog (`Helyx.Watchdog`): the hook Task holds the group with `Helyx.Tool.hold/1` before the command runs, and `release/3` is `Helyx.Watchdog.Group.release/3` (ADR 0004, ADR 0013 §8).
- Standard input is the JSON below, then end of file.
- Standard output and standard error are read apart. The watchdog merges them in its port, so a small perl relay of this plugin (`command/relay.pl`), in the same group, runs the command with a pipe for each and writes each read to the port as one frame: a tag byte (`o` or `e`), four bytes of length, and the bytes, at most 65,536. When the command exits, the relay reads what the pipes hold and exits with its status, 128 plus the signal for a signal death. A port stream that is not a frame is a failed hook.
- **The answer is what the command wrote before it exited.** A child that the command left running, with the pipes open, does not hold the hook, and what it writes after the exit is not part of the answer and is not read: when the relay sees the exit (it looks every 50 ms), it reads what the pipes hold then, at most 16 reads of each, and exits; what a child wrote by then is read. Reason: a command that starts a background job and exits 0 is a normal case, such as a script that starts a formatter or a log upload; holding the hook to the job's end would hold the call for it, and reading its later output as the answer would let a job decide a call that its command already answered.
- The relay is the command's reaper, as the watchdog is the relay's: it ignores TERM, HUP, and SIGPIPE, so the TERM of a release reaches the command with its grace (ADR 0004), and the relay reaps the command and exits after it; once the port is gone it drops the rest of the output. The relay sets TERM and HUP to their default action at its start, as libuv, the process spawn of Node, resets each signal of a child to its default (`uv_spawn`): Helyx can run with one ignored (a server started under `nohup` ignores HUP), an ignored signal is dropped even while it is blocked, and a shell cannot trap a signal that was ignored when it started. Then TERM and HUP are blocked across the relay's fork, so the command starts with the default action of each; one that came while they were blocked stays pending in the relay, which sends it on to the command after the fork. So no TERM is lost in the fork: every sender signals the whole group (the watchdog, `Helyx.Watchdog.Group.release/3`, and the kernel's HUP to an orphaned group), so one sent before the fork reaches the command through the relay, and one sent after it reaches the command itself, while the relay's own copy is dropped. A TERM that comes between the fork and the relay's read of its pending signals reaches the command twice, its own copy and the forwarded one; nothing bounds when the command runs in that window. A release already sends more than one TERM (the watchdog's when the port closes, and the one of the hands' `:cancel`), so a second one is no new case for a command. Sending it once would need a new mechanism: the command would wait for a go from the relay before it runs. A KILL ends both at once, as it ends any parent in a group.
- The hook Task is killed at its limit (`docs/features/hooks.md`); its port closes with it, so the watchdog stops the group (TERM, its grace, KILL), and the hands release it with `:cancel`.

### The JSON on standard input

The field names are those of the Claude Code hook format (`docs/research/claude-code-hooks.md`), so a script that reads `.tool_input.command` reads the command of the `bash` tool; the values are those of Helyx.

| Field | Value |
|---|---|
| `hook_event_name` | `"PreToolUse"` at `before_tool`, `"PostToolUse"` at `after_tool`, `"Stop"` at `before_settle` |
| `session_id`, `turn_id` | the ids of the session and of the call's turn, or of the ended turn |
| `cwd` | the session folder, the working directory of the command |
| `stop_reason` | `before_settle` only: the stop reason of the ended turn, such as `"end_turn"` |
| `tool_name` | the tool points only, as each field below: the tool name, such as `"bash"` |
| `tool_input` | the arguments as Core checked them, a JSON object |
| `tool_use_id` | the call id |
| `provider` | `null` for a Helyx tool call; the provider id for a call of a provider's own tool (#881) |
| `tool_response` | `after_tool` only: `{"status": "ok" \| "error", "text": …}`, the text cut as the hands cut a result (`Helyx.Message.cut_result/1`), so the command reads what the model would read |

### Exit codes and answers

| Exit | `before_tool` | `after_tool` | `before_settle` |
|---|---|---|---|
| 0, standard output only white space, or plain text (its first byte that is not white space is not `{`, in the kept head; white space is what JavaScript's `trim()` drops, as Claude Code trims its hook output before it looks for `{`: the JSON white space, form feed, vertical tab, the Unicode space separators (Zs), the line and paragraph separators, and the byte-order mark, not NUL) | `:allow` | `:keep` | `:settle` |
| 0, standard output a JSON object | the answer of its shape (below) | the answer of its shape (below) | the answer of its shape (below) |
| 2 | `{:deny, stderr}` | `{:replace, {status, text <> "\n\nThe hook Helyx.Hook.Command added: " <> stderr}}`, the status of the result kept | `{:continue, stderr}`: one more turn with `stderr` as its user message (ADR 0013 §8) |
| any other, a signal death, a start that failed | a failed hook: the call is denied | a failed hook: the result is kept, with a notice | a failed hook: the session settles, with a notice |

`stderr` is standard error made valid UTF-8; empty or only white space, it is `the command exited with status 2`. The text of a failed hook is `the command exited with status <n>`, with `: <stderr>`, trimmed of white space at both ends, when standard error holds more than white space, `the command did not start: <reason>`, or the reason of the shapes below; Core cuts it at 4,000 bytes (`Helyx.Reason.text/1`) and the entry and the notice at 4,096. Plain text on standard output at exit 0 is no answer: a script may print what it did, and only an object that starts with `{` is read as an answer.

The shapes of a JSON object on standard output at exit 0. A field that is `null`, and a text field that is `""`, count as missing.

- `before_tool`: `hookSpecificOutput.permissionDecision` `"allow"` or `"deny"`, with `hookSpecificOutput.permissionDecisionReason`; and the older `decision` `"approve"` or `"block"`, with `reason`. A deny or a block in either field denies, with the reason of the first field that denies and has one (`permissionDecision` first), or `the command denied the call` with none. An allow with a reason is `{:allow, reason}`; with neither field, `:allow`.
- `after_tool`: `decision` `"block"` with `reason`, and `hookSpecificOutput.additionalContext`: each text that is there is added to the result as at exit 2, the reason first. With neither, `:keep`.
- `before_settle`: `decision` `"block"` with `reason` is `{:continue, reason}`, or `{:continue, "the command asked for one more turn"}` with no reason; `continue` `false` settles, ahead of a block: Helyx reads it as the stop that the Claude Code schema text describes ("Whether Claude should continue after hook"), and at `before_settle` the stop is the settle. With neither, `:settle`.
- A failed hook, at every point: stdout that is not a JSON object after its `{`; an object with a repeated key, at any depth (`Helyx.JSON.decode/2`, `:unique_keys`): a decoder that keeps the first value and a JavaScript reader that keeps the last would give two answers, and a reader of untrusted text fails closed (`docs/agents/review-checklist.md`); `hookSpecificOutput` that is not an object; `continue` that is not a boolean. At the two tool points also `continue` `false`: Helyx reads it as a stop of the agent, which a hook that answers for one call cannot give (the binary holds the text "Whether Claude should continue after hook", `docs/research/claude-code-hooks.md`).
- A failed hook at `before_settle`: `decision` with another value than `"block"`, and `reason` of another type than a string.
- A failed hook at `before_tool`: a field above of another type than a string; a `permissionDecision` with another value than `"allow"` and `"deny"`, such as `"ask"` and `"defer"`; a `decision` with another value than `"approve"` and `"block"`; and `hookSpecificOutput.updatedInput`, whose name asks for new arguments (a hook does not change arguments, ADR 0013 §2).
- A failed hook at `after_tool`: `decision` with another value than `"block"`; `reason` or `additionalContext` of another type than a string; and `hookSpecificOutput.updatedMCPToolOutput`, whose name asks for a new output (this plugin adds text only).
- Each other field is ignored, such as `permissionDecision` at `after_tool` and `before_settle`, and `stopReason`.

The continue turn, its origin (`%{kind: :hook, id: "Helyx.Hook.Command"}`), and the bound of 8 turns in a row that hooks start are Core's (`docs/features/before-settle.md`).

## Replaced mechanism

None. The plugin is new; the hands and the watchdog do not change, and Core only adds `cwd` to the `before_settle` input (`docs/features/before-settle.md`).

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| the time of a run | the hook's limit, `limit_ms`, 1 to 600,000 ms, default 60,000, checked at Core start; then the release deadline of the hands | killed by the hands, a failed hook; the group gets `:cancel` (`docs/features/hooks.md`) |
| standard output kept | 262,144 bytes (four times the result bound, room for a reason at that bound with JSON escapes), in the hook Task | read and dropped; at exit 0, a kept head that starts an object or is only white space is a failed hook, since no answer can be read whole; a head of plain text is the default |
| standard error kept | 262,144 bytes | read and dropped; the kept head is the reason or the added text, cut later as a result, or the text of a continue |
| a frame of the relay | 65,536 bytes of data and 5 of head; one partial frame kept between two reads | a length over it is a failed hook |
| the JSON on standard input | the arguments, at most the 8 MiB of an open message (`Helyx.Session.Turn`), and a result cut at 65,536 bytes, which JSON escapes can make six times larger: under the 16 MiB of unread input that the watchdog keeps (`Helyx.Watchdog`) | not reachable |
| a deny reason, a result with an addition | `Helyx.Message.max_result_bytes/0`, cut by the hands | cut |
| the text of a continue | the `reason` of standard output, at most 262,144 bytes, or the kept standard error made valid UTF-8, at most 786,432 bytes (each of its 262,144 bytes an invalid one, made U+FFFD of 3 bytes); under the 4 MiB of a client text that Core checks (`Helyx.Session.Hands.Run`, `docs/features/before-settle.md`) | not reachable |
| the text of a failure | 4,000 bytes (`Helyx.Reason.text/1`), 4,096 in the entry and the notice | cut |
| the config | read at each run: a keyword list of three points, each of three keys at most; `tools` is a list of the config, not of the model | a failed hook |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the command's process group (command, relay, and their children) and the watchdog | `Helyx.Watchdog.start/4` in the hook Task | the hands, held before the command runs | the hands call `release/3` with `:deliver` when the hook Task ends: a KILL of what the command left | the port closes with the Task, so the watchdog TERMs and KILLs the group; the hands release with `:deliver`, or with `:cancel` at the limit | `release/3`, `:cancel`, in the cancel of the turn, or of the ended turn at `before_settle` |
| the port | `Helyx.Watchdog.start/4` | the hook Task | closed at the Task's end | closed at the Task's end | closed when the cancel kills the Task |

## Out of scope

- `stop_hook_active` of the Claude Code `Stop` input: the `before_settle` input does not say whether a continue started the ended turn, and Core bounds the turns that hooks start in a row at 8 (`docs/features/before-settle.md`). A script that reads it gets no field.
- Several commands at one point, and a match on the tool name by pattern: `tools` names tools; a script can filter by `tool_name`.
- A full replace of a result; `transcript_path`, `permission_mode`, and the env names of Claude Code (`CLAUDE_PROJECT_DIR`).
- The tool names and argument shapes of Claude Code: Helyx sends its own (`bash` with `command`, not `Bash`).
