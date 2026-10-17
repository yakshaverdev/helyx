# Parallel tool calls and subagents: four harnesses

Research for tickets #734 (concurrent tool calls) and #735 (the agent tool). It records observations; the decisions are in `docs/features/concurrent-tool-calls.md` and `docs/features/agent-tool.md`.

Date: 2026-10-17. Research only. Sources:

- Codex: openai/codex @ ce0323f. Paths are under `codex-rs/`.
- pi: badlogic/pi-mono @ 8efd314 (issues now at earendil-works/pi).
- OpenCode: sst/opencode (now anomalyco/opencode) @ 8c173a8. `packages/opencode` is gone. Paths are under `packages/`. The `task` tool is now `subagent` (`core/src/v1/config/migrate.ts:30`).
- Claude Code: the bundle is closed. Facts come from code.claude.com/docs (read 2026-10-17): `sub-agents`, `tools-reference`, `env-vars`, `agent-sdk/agent-loop`, `agent-sdk/subagents`, `agent-sdk/cost-tracking`. They are documented behaviour, not verified code.
- "Inference" marks a conclusion no line states.

## A. Parallel tool calls

### Codex
- Each call starts in its own `tokio::spawn` when its item finishes streaming (`core/src/session/stream_events_utils.rs:345-357`).
- One `RwLock<()>` per step. A parallel-safe tool takes the read lock. Any other tool takes the write lock and runs alone (`parallel.rs:213-217`). The default is not safe (`tools/src/tool_executor.rs:122-124`). Safe: `exec_command`, `view_image`, `tool_search`, and MCP tools whose server sets `supports_parallel_tool_calls` (`core/src/tools/handlers/mcp.rs:142-145`). Serial: `apply_patch`, agent tools. No cap (inference).
- Order: outputs go into a `FuturesOrdered`, so results go to history in call order (`core/src/session/turn.rs:2568-2592`, comment at `parallel.rs:240`).
- Abort: each call has a child cancellation token; interrupt aborts it with "aborted by user after Xs" (`parallel.rs:262-298,376-382`). A failed call does not cancel siblings (`parallel.rs:110-111`).
- Request flag: `parallel_tool_calls: true` is hard-coded (`turn.rs:1680`). It is sent only when the model is not "Responses Lite" (`core/src/client.rs:1083`).

### pi
- The default is `"parallel"` (`packages/agent/src/agent.ts:253`). The coding agent does not change it (`packages/coding-agent/src/core/sdk.ts:411`).
- Preflight (lookup, argument check, hook) runs in call order, then all calls start in `Promise.all` (`packages/agent/src/agent-loop.ts:596-648`).
- Per-tool flag `executionMode: "sequential"`. One sequential tool in the batch makes the whole batch sequential (`agent-loop.ts:516-521`). The built-in `edit` and `write` instead serialize per real file path (`coding-agent/src/core/tools/file-mutation-queue.ts:32`). No cap (inference).
- Order: end events in completion order; result messages after, in call order, to model and session (`agent-loop.ts:638,649-654,274-277`).
- Abort: all tools share one `AbortSignal`; each tool must obey it (`agent-loop.ts:832-835`). A call not started gets "Operation aborted" (`agent-loop.ts:620-627`); a missing result gets a synthetic error (`packages/ai/src/api/transform-messages.ts:179-199`). Bugs here: earendil-works/pi #9994, #8935, #3468. A thrown error becomes an `isError` result, so siblings continue (`agent-loop.ts:845-852`).
- Request flags: `parallel_tool_calls: true` only in the Codex Responses provider (`packages/ai/src/api/openai-codex-responses.ts:564`). `disable_parallel_tool_use` is not used.

### OpenCode
- Own LLM client, not `streamText` (`core/src/session/runner/step.ts:107`). Each `tool-call` event forks a fiber at once, mid-stream (`step.ts:120-134`). No per-tool flag and no cap; every call runs concurrently (inference). Cap request: anomalyco/opencode #50563.
- No `batch` tool in core. Code Mode `execute` runs model-written JS over tools (`core/src/codemode/tool.ts:62-76`).
- Order: parts stored in stream order; results to the model in that order (`core/src/session/message-updater.ts:303-316`, `core/src/session/runner/to-llm-message.ts:216-232`).
- Abort: interrupt stops all tool fibers; unsettled calls get "Tool execution interrupted" (`step.ts:150-152,216-225`). A `Tool.Error` fails only that call. One permission rejection rejects all pending asks (`core/src/permission.ts:276-294`).
- Request flags: core never sets them (inference). The provider layer can map them: Anthropic `disable_parallel_tool_use` (`ai/src/protocols/anthropic-messages.ts:555-577`), OpenAI `parallelToolCalls` (`ai/src/protocols/open-responses.ts:795-800`).

### Claude Code
- Read-only tools (Read, Glob, Grep, tools with `readOnlyHint`) run concurrently; Edit, Write and Bash run sequentially (docs `agent-sdk/agent-loop`, `agent-sdk/custom-tools`).
- Cap: `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY`, "maximum number of read-only tools and subagents that can execute in parallel (default: 10)" (docs `env-vars`).
- Order: not documented. The API requires one `tool_result` per `tool_use`, all in the next user message before any text, and sets no execution order (platform.claude.com/docs `tool-use/parallel-tool-use`, 2026-10-17).
- Failure: one failed call cancels its siblings, "Sibling tool call errored" (anthropics/claude-code #22264, open; #29770). Not in docs.
- `disable_parallel_tool_use` is a `tool_choice` field; with `auto` it allows one call per response (API docs above). Whether Claude Code sets it: unknown.

## B. Subagents

### Codex (feature `multi_agent`, stable, on by default; `multi_agent_v2` off; `features/src/lib.rs:1482-1492`)
1. Tools (V1): `spawn_agent(message|items, agent_type, fork_context, model, reasoning_effort)` returns `{agent_id, nickname}`. Also `send_input`, `wait_agent(targets, timeout_ms)`, `close_agent`, `resume_agent` (`core/src/tools/handlers/multi_agents_spec.rs:166-285,610-646,887-914`). `wait_agent` returns statuses; `Completed` carries the child's last message. No usage (`core/src/agent/status.rs:8-11`).
2. The child is a new thread and session in the same process (`core/src/thread_manager.rs:1989-2008`). Fresh context by default. `fork_context=true` copies parent history without tool calls, reasoning or token records (`core/src/agent/control/spawn.rs:83-125`). Config cloned from the parent, then a role layer (`core/src/agent/child_config.rs:71-165`).
3. Roles: built-in `default`, `explorer`, `worker` (`core/src/agent/role.rs:346-385`). User roles in `[agents.<name>]` config, or `*.toml` files in an `agents/` folder of each config layer (`agent-roles/src/loader.rs:76-80`).
4. Depth default 1: "Agent depth limit reached. Solve the task yourself." The child at the limit gets no agent tools (`core/src/config/mod.rs:266`, `spawn.rs:76-79`, `core/src/tools/spec_plan.rs:728-734`). Open threads default 6 (V1) or 4 including root (V2) (`config/mod.rs:256-257`). Error: "agent thread limit reached" (`protocol/src/error.rs:131-132`). `wait_agent` timeout 30 s (10 s to 1 h). No run-time limit.
5. Child end: a watcher injects `<subagent_notification>` into the parent without a turn (`core/src/agent/control.rs:457-583`). `close_agent` closes the child and its subtree (`core/src/agent/control/legacy.rs:50-122`). Parent interrupt does not reach children (inference from `core/src/session/handlers.rs:60-62`). Resume after crash: `resume_agent` reloads from rollout and resumes Open descendants (`core/src/agent/control/resume.rs:14-36`).
6. One rollout per child, source `SubAgent{parent_thread_id, depth, ...}` (`protocol/src/protocol.rs:3039-3051`). TUI: history rows, `/subagents` picker, Alt+arrows (`tui/src/multi_agents.rs:106-112`).
7. Usage per thread; not added to the parent (inference). Optional shared rollout budget (`core/src/rollout_budget.rs:18-28`).
8. The child inherits approval policy and sandbox; roles cannot loosen them (`child_config.rs:179-202`, `role.rs:36-48`). Approvals show in the current view with the thread name (`tui/src/app/thread_routing.rs:242-246`).
9. Issues: max_depth not enforced (#46704); V2 bypasses max_threads (#33447); memory growth with many subagents (#23260, #23749); 15 agents freeze the TUI (#24668); parent missed completion after interrupt (#9607).

### pi (no core subagent: "skips features like sub-agents and plan mode", `README.md:19`; example extension `packages/coding-agent/examples/extensions/subagent/index.ts`)
1. Tool `subagent`, one mode of `{agent, task}`, `tasks[]`, or `chain[]` (`index.ts:440-516`). The model gets final text (50 KB cap per task); usage goes to `details` for the UI (`index.ts:161-178,667-680`).
2. Child is a `pi --mode json -p --no-session` OS process with fresh context; agent body via `--append-system-prompt`, `tools` via `--tools` (`index.ts:237-348`).
3. Markdown: `name`, `description`, `tools`, `model`. Folders `~/.pi/agent/agents`, `.pi/agents`; project agents need confirmation (`agents.ts:34-139`).
4. `MAX_PARALLEL_TASKS = 8`, `MAX_CONCURRENCY = 4` (`index.ts:34-35`). No depth or time limit. A child can load the extension again, so recursion is possible (inference).
5. Abort: SIGTERM, then SIGKILL after 5 s (`index.ts:408-418`). The SIGKILL guard `!proc.killed` is true after SIGTERM, so it rarely fires (inference). No background mode.
6. No child session file; child messages live in the tool result `details`. UI collapsed, Ctrl+O expands (`index.ts:147-166,835-845`).
7. Usage summed per run in the UI only (inference).
8. pi has no approvals (`coding-agent/docs/security.md:3,33`).

### OpenCode
1. Tool `subagent(agent, description, prompt, model?, sessionID?, background?)` (`core/src/tool/plugin/subagent.ts:29-48`). Result `<subagent sessionID=".." state="completed">last text</subagent>`; no usage (`subagent.ts:258-265`, `core/src/session/subagent-job.ts:55-60`).
2. New session with `parentID` in the same process, fresh context (`subagent.ts:185-211`). System prompt from the agent. Tools filtered by agent and inherited permissions; `general` and `explore` deny `subagent` (`core/src/plugin/agent.ts:94,115`).
3. Markdown in `{agent,agents}/**/*.md` under `.opencode` or the global config dir, or `agents` in `opencode.json`. `mode: subagent|primary|all`; a primary agent cannot be a subagent (`core/src/config/plugin/agent.ts:21-24`, `subagent.ts:136-137`).
4. Depth `experimental.subagent_depth`, default 1: "Subagent depth limit reached (1)..." (`subagent.ts:118-133`). No concurrency cap, no timeout; only the agent's `steps`.
5. Foreground: tool-fiber interrupt interrupts the child (`subagent.ts:235-239`); background children are not cancelled (inference). Background end injects a `<subagent>` message (`core/src/session/subagent-completion.ts:37-44`). Resume by `sessionID`. After a crash, stale calls fail with the child's id (`core/src/session/runner/llm.ts:362-383`).
6. Child session row with `parentID`; deleting a parent deletes children (`core/src/session.ts:289-297,381-382`). TUI keys: picker, previous/next child, parent (`tui/src/config/keybind.ts:138-141`).
7. Cost per session; the client sums the family (`client/src/solid/data.ts:1414-1422`).
8. Spawn is a permission action `subagent` on the agent id (`subagent.ts:138-151`). Child asks show in the root session view (`tui/src/routes/session/index.tsx:197-213`).
9. Issues: reply lost after interrupt (#54658, open); silent child end on network error (#44596); RAM growth (#16697).

### Claude Code (docs)
1. Tool `Agent` (was `Task`). Inputs in docs: `description`, `prompt`, `subagent_type` (default `general-purpose`; `fork` forks), `model`, `run_in_background`, `name`, `isolation`. The parent gets only the final result; background results arrive as a later notification.
2. Same session, own context window. Fresh context: own system prompt plus CLAUDE.md and git status. A fork gets full history, the same prompt, tools and model, and shares the prompt cache. Tools inherited minus a fixed list.
3. Markdown + YAML frontmatter (`name`, `description`, `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `background`, `isolation`, ...). Folders: managed, `--agents` JSON, `.claude/agents/`, `~/.claude/agents/`, plugin `agents/`. No shared standard: Codex and OpenCode do not read `.claude/agents` (grep).
4. Depth 3; at the limit `Agent` is withheld. 20 running, then `Concurrent subagent limit reached` with "do not retry"; resumes skip the check. Stall timeout 10 min. SDK `maxBudgetUsd` stops background subagents (docs `env-vars`, `agent-sdk/subagents`).
5. Background is the default. Resume with `SendMessage` to the id or name, history kept, also after a restart. Main-turn interrupt: #78151 (open) says it silently kills background subagents.
6. Transcript `~/.claude/projects/{project}/{sessionId}/subagents/agent-{agentId}.jsonl`. SDK messages carry `parent_tool_use_id`. UI: tree panel under the prompt; open a transcript and type into it.
7. SDK `total_cost_usd` and `modelUsage` include subagents; `usage` does not (`agent-sdk/cost-tracking`).
8. Inherits the parent mode. When the parent is `default`, `dontAsk` or `plan`, the agent's `permissionMode` applies (for example `acceptEdits`), but never `bypassPermissions`. Background prompts surface in the main session with the agent's name.
9. Issues: recursive spawn, 3 requested and 24 ran (#82565, #68619); interrupt kills background agents silently (#78151); rejecting an Agent call does not stop it (#83392); child MCP processes not reaped (#66280); child usage undercounted (#84223); memory leak (#23239).

## (a) Comparison

| | Codex | pi | OpenCode | Claude Code |
|---|---|---|---|---|
| Parallel run | yes, from mid-stream | yes, after stream | yes, from mid-stream | yes, read-only only |
| Who may run in parallel | per-tool flag, default serial | all, unless a sequential tool in batch | all | read-only (`readOnlyHint`) |
| Cap | none | none | none | 10 |
| Result order to model | call order | call order | call order | call order (API rule) |
| One call fails | siblings continue | siblings continue | siblings continue | siblings cancelled (#22264) |
| Request flag | `parallel_tool_calls: true` | only Codex provider | not set | unknown |
| Subagent tool | `spawn_agent` + wait/send/close/resume | `subagent` (extension) | `subagent` | `Agent` + `SendMessage` |
| Child runs as | thread in process | OS process | session in process | same session, own context |
| Context | fresh or filtered fork | fresh | fresh | fresh or full fork |
| Definitions | TOML roles | Markdown | Markdown / JSON | Markdown |
| Depth default | 1 | none | 1 | 3 |
| Open at once | 6 (V2: 3) | 4 of 8 tasks | none | 20 |
| Background | yes (wait tool) | no | yes | yes, default |
| Child transcript | own rollout | none | own session | own JSONL |
| Usage into parent | no (inference) | UI only | summed in client | SDK cost yes |
| Approvals | inherit; routed with label | none | inherit; root view | inherit; routed with name |

## (b) Same in all four
- Results go to the model in call order; display can follow completion.
- The aim is one result per call, even on abort; pi and Codex fill gaps with an error result.
- The child returns final text only; fresh context is the default.
- Agent types are files: name, description, tools, model, prompt body.
- The child inherits the parent's permission policy (Claude Code allows a per-agent mode, except bypass).
- The parent model does not see the child's token usage.

## (c) Where they differ, and the trade-off
- **Parallel policy.** Codex and Claude Code opt in per tool (safe; a mutating tool blocks the batch). pi and OpenCode run all (fast; file races, so pi adds a per-file queue).
- **Start time.** Codex and OpenCode start mid-stream (lower latency; batch unknown at first start). pi waits for the full message.
- **Sibling failure.** Claude Code cancels siblings (protects ordered edits; costs retries). Others keep siblings (cheaper; the model must handle partial success).
- **Child isolation.** pi uses an OS process (kill isolation; no approvals, no transcript). Others run in process (shared approvals, storage, resume; a runaway hurts the host, Codex #23260).
- **Fork.** Codex and Claude Code can fork history (no re-explaining; more tokens per child, #82565).
- **Depth.** 1 (Codex, OpenCode) blocks recursion. 3 (Claude Code) allows trees and showed runaway spawn.
- **Wait.** Codex: explicit `wait_agent`. Claude Code, OpenCode: pushed completion message. pi: blocking call.
- **Abort reach.** OpenCode foreground and pi: reaches the child. Codex: does not. Claude Code: kills background children silently (#78151).

## (d) Open questions for a BEAM design (child session in the same Core)
1. Is the child linked or only monitored by the parent tool Task? A link makes abort reach the child; a monitor lets a background child outlive the turn.
2. On parent abort, what is the child's state, and what result does the parent get? Three harnesses had lost-result bugs here (Codex #9607, OpenCode #54658, Claude Code #78151).
3. Is the subagent tool parallel-safe? Codex: serial. Claude Code: in the shared cap.
4. Where are the limits checked: depth from the parent chain (OpenCode walks `parentID`), open count per root session? What error text tells the model not to retry?
5. Which approvals route to the root session's client, and is an approval for "the rest of the session" shared with the child?
6. Does the child usage go into the parent's event stream, the root's total, or only the child session?
7. How does a background child's end reach the parent: a message into the parent mailbox that starts a turn, or one that waits for the next turn?
8. After a server restart, does the child resume from its own stored session, and is the open edge stored on the parent or the child?
9. Is a subagent a Tool plugin on the public session API, so Core has no subagent concept and the limits live in the plugin?
10. Is a history fork in scope? If so, does it go through ModelContext?
