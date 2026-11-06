# Hooks: one chain before and after a tool call and before a turn settles

Ticket #563, with #503 folded in (owner decisions of 2026-10-23 and 2026-11-06). Built by later tickets; this ADR changes no code.

User stories:

- A user wants Helyx to ask before `bash` runs. The TUI shows the command; the user allows it, and the call runs. Another call is denied, and the model reads why in the tool result. A Codex file change that the program asks about is denied too; the program reads a decline, which carries no reason.
- A user runs a print session with no client attached. A call that the rules send to the user is denied at once, with a reason, and the session goes on.
- A user has a hook script written for Claude Code. Helyx runs it before each tool call with the same exit code meanings, and its block (exit 2) stops the call.
- A product checks the work at the end of each turn: when its test command fails, the session goes on with one more turn that tells the model what failed.
- A user later reads the session file and sees each call that a hook denied, changed, or failed on, and why.

## Context

- No tool call asks anyone. A Helyx tool runs in a Task of the hands (`Helyx.Session.Hands`) through `Helyx.Session.Hands.Run.tool/3`, with no check before or after. Every Helyx tool call reaches the hands the same way: a `{:tool_call, ...}` of a model provider, and a `{:tool_request, ...}` of a harness provider (`Helyx.Provider`).
- The harness programs have their own tools turned off where the program allows it (ADR 0007, update of 2026-10-17). Claude Code runs with `--tools=`, `--permission-mode bypassPermissions`, and no `--permission-prompt-tool` (`plugins/bundled/lib/helyx/provider/claude_code/program.ex`), so every call of its model is a Helyx tool call through the MCP server of Helyx, and any other `control_request` gets an error (`claude_code.ex`).
- Codex runs with its shell off (`--disable shell_tool --disable unified_exec`, `codex/program.ex`), but no option removes `apply_patch`, `request_user_input`, the `multi_agent_v1__*` tools, or the MCP resource tools (`docs/research/provider-parity.md`, "Codex: options that could remove its own tools"). Its thread runs with the provider options `codex_sandbox` and `codex_approval_policy`, default `danger-full-access` and `never`, and `approvalsReviewer: "user"` (`docs/features/long-lived-harness.md`, "Sandbox and approvals"). With `never` no approval request comes. With another policy one can come: `item/commandExecution/requestApproval` or `item/fileChange/requestApproval`, after the `item/started` of its item (`docs/research/codex-app-server.md`, "Approvals"). Today the provider answers every server request, an approval too, with the JSON-RPC error -32601 (`codex.ex`, `dispatch/2`), which codex 0.157.1 took as a decline. The ticket text of #503 ("answers every approval request with `accept`") predates #627 and no longer holds.
- The Codex provider already gives each tool item of the program's own tools as a `{:tool_call, ...}` with the item id as its call id, the item type as its name (`fileChange`, `commandExecution`), and the item fields as its arguments (`codex/items.ex`). So the call of an approval request is in the transcript before the request comes.
- A running call can ask the clients: `Helyx.Tool.ask/1` emits `:ask`, a client answers with the `answer` operation, `{:error, :no_client}` comes at once when no subscriber can answer, and the end of the turn ends the wait (`docs/features/question-tool.md`). ADR 0011 §4 makes the request of such an ask a UI block, and names `approval` as the kind that comes with this ADR.
- The extension surface is Provider, Tool, ModelContext, Compaction, and Memory (ADR 0009). A gate in Core between the turn loop and `Tool.run/2` would put a policy in Core; a check in each tool, and one in each provider, would be several gates that disagree.

## Decision

### 1. A Hook interface

The extension surface gets a sixth interface, `Helyx.Hook`, mode `:multi`. A hook plugin implements the callbacks of the points that it handles; each callback is optional, and a plugin with none is refused at Core start. Core owns the chain: the order, the time limits, the fail rule of each point, and the record. The plugin owns its policy and its config, which it reads from an application env key named for it (AGENTS.md, "Module naming").

Core knows the points and the answers below, and names no tool, no rule, and no harness.

### 2. The points and the answers

| Point | When | What the hook gets | Answers |
|---|---|---|---|
| `before_tool` | before a Helyx tool call runs, and when a provider asks for a decision on a call of a tool of its own (§4) | the tool name, the arguments as Core checked them, the cwd, the session id, the turn id, the call id, and `provider`: nil for a Helyx tool, or the id of the provider whose own tool it is | `:allow`, `{:allow, reason}`, or `{:deny, reason}` |
| `after_tool` | after a Helyx tool call returned its result, before the hands cut it and deliver it | the same as `before_tool` with `provider: nil`, and the result `{:ok \| :error, text}` | `:keep`, or `{:replace, {:ok \| :error, text}}` |
| `before_settle` | after a turn ended with a stop reason that the provider gave (not `:aborted`, not `:error`, and not a compaction turn), before the session takes its queues | the session id, the turn id, and the stop reason | `:settle`, or `{:continue, text}` |

- A `reason` and a `text` are strings of valid UTF-8. The model reads a deny as the error result of the call: the hook named and its reason, cut as any result (`Helyx.Message.cut_result/1`). A replaced result is cut the same way, so a hook cannot pass the result bound.
- Arguments are not changed by a hook. A hook that changed them would change what an earlier hook of the chain allowed.
- `after_tool` runs only on a result that the hands made: a Helyx tool call, including the start answer of a background run. The end of a background run is a user message, not a tool result, and gets no `after_tool`. A harness tool result is what the program's model already read, so no hook can change it.
- **Continue.** `{:continue, text}` starts the next turn at once, ahead of the queued follow-ups, with `text` as a user message whose origin kind is `:hook`, with the name of the hook module as its id (a string of at most 256 bytes, as every origin id). A turn ends at the provider (`stream_end`; a harness completes its own turn), so Core cannot reopen it; one Helyx turn for each provider turn keeps the turn ids and the abort as they are. The turns that hooks start in a row are bounded by a count that the feature doc sets; the count resets at a turn that a client message starts, and past it the session settles and emits a `:notice`.

### 3. Several hooks on one point

- **A fixed order:** the order of the hook plugins in the plugin list of Core.
- **A deny wins.** The chain of `before_tool` runs in order and stops at the first deny; the call runs only when every hook allowed it. So a later hook, such as one that asks the user, is not asked about a call that an earlier one denied.
- `after_tool` hooks run in order, each on the result that the hook before it left. `before_settle` hooks run in order, and the first `{:continue, text}` ends the chain.
- **A time limit for each hook.** A hook gives its limit for each point, an integer of milliseconds that Core checks once at its start, from 1 to 600,000 (10 minutes); any other value stops the start with `{:invalid_hook_limit, module}`. The limit of a hook that asks the user is the bound of the wait for the answer.
- **Where it runs.** The chain of a Helyx tool call runs from the call's Task of the hands. Each hook runs in a Task of the hands of its own, with the call's context (`Helyx.Tool.context/0`), and the hands track it as they track a call Task: the hook module is the owner of its handles. A hook that starts an OS process holds it with `Helyx.Tool.hold/1` and implements the optional `release/3`, as a tool does; the hands call it when the hook ends, at its limit, and at an abort, with the rules of ADR 0004, and the chain goes on only after that release, or after its deadline, as for a call. A handle that a release leaves unconfirmed is the one of a tool: from then on the hands refuse tool calls, provider starts (`Helyx.Session.Hands`), and hook starts. A refused hook start is a failed hook, handled by the rule of its point (§5): a `before_tool` chain denies, an `after_tool` or `before_settle` chain goes on with a `:notice`. This is intended: a leaked process group of a hook is the same risk as one of a tool, and a hook that starts after it could leak another. Today the hands take a hold only from a call Task and drop a hold from any other process (`Helyx.Session.Hands`, `call({:hold, ...})`), so this is new hands work, not a reuse. So the abort of a turn ends a running hook as it ends the call. The chain of a harness request (§4) runs in a Task of the hands under the call id of the request, with the same context and the same rules. It takes no place of the tool queue (`Helyx.Session.ToolQueue`): the program, not the hands, gives the result of that call, and a queue place ends with a result. The turn keeps its own set of harness chains: at most 8 run at once and at most 16 wait, in arrival order, as the tool queue bounds its calls; a request past them is denied at once. The chain of `before_settle` runs in one Task of the hands, at most one for a session. A chain runs one hook at a time, so at most 17 hook Tasks run at once in a session: one for each of the 8 tool calls that run at once (`docs/features/concurrent-tool-calls.md`), one for each of the 8 harness chains that run, and one for `before_settle`. The session never waits for a hook in its own process.
- **A hook asks.** A hook asks the clients with `Helyx.Hook.ask/1`, which takes the path of `Helyx.Tool.ask/1`: the `:ask` event with the call id and the tool name, and the `answer` operation, with the same bounds and `{:error, :no_client}`. The session takes an ask for a call id of the current turn that runs in the tool queue or in the set of harness chains, as it takes one for a running call today; any other gets `{:error, :not_running}`, a `before_settle` hook too in the first version. The ask records the hook Task that asked, a check that the build adds, since today the session checks the call id only (`Helyx.Session.Server.Asks`). The session monitors that Task when it takes its first ask, and at its `:DOWN`, whatever the cause (an answer and a normal end, the limit, a crash, an abort), ends the asks of that Task that are still open with the outcome `:ended`, so each client closes the question. So a hook killed at its limit leaves no question open on a client while the hooks after it run. An answer that comes after the `:DOWN` finds no ask and gets `{:error, :not_waiting}`, as a late answer does today.

### 4. Harness tools

- **Claude Code**: its own tools are off, so every call of its model is a Helyx tool call, and the chain of §2 covers it. No `--permission-prompt-tool` is needed.
- **Codex**: an approval request for a call of its own tools goes through the same `before_tool` chain. A provider gives a new stream event `{:approval, approval_id, call_id}`: `approval_id` is the provider's own id of the request, 1 to 256 bytes of valid UTF-8, the bound of an origin id (`Helyx.Message`), checked in `Helyx.Session.Stream.check/1`, and unique among the pending requests of the turn (for Codex, made from the JSON-RPC id of the request), and `call_id` names an open call of the turn that the provider runs itself, as ADR 0011 §3 rules for a provider block. The session runs the chain with that call's name and arguments and `provider` set to the provider id, records it (§6), and answers with a new request `{:approval, turn_id, approval_id, :allow | {:deny, reason}}`. The answer names the request, not the call, so the answers to two requests of one call never mix. An `approval_id` outside its bytes, or equal to the id of a request that is still pending (its chain runs or waits), is a malformed event: the provider process stops and the turn fails, the generic path. The check reads the set of harness chains that the turn keeps anyway (§3); the session keeps no list of the ids of requests that ended, and an ended id is not checked, as the tool queue does not check an answered call id (`Helyx.Session.ToolQueue.request/5`; no real provider reuses an id, #369). The provider answers the program: `accept`, or `decline`. Core names no harness: the event and the request are provider constructs, as a tool request is.
- A call has at most one pending request, read from the same set; a second one for the same call id, and a request whose call id names no open harness call of the turn, such as an approval of a child thread, whose items Helyx drops, gets `{:deny, reason}` at once: the program waits for an answer, so it is never dropped.
- With no `before_tool` hook, a Helyx tool call runs, as today, and a harness approval request is denied, as today (ADR 0007, update of 2026-10-20): the program's policy asked for a decision, and none was made.
- At an abort, the session denies each approval request that has no answer, then sends the interrupt; the stop of the provider process stays the backstop.

### 5. A failed hook

A raise, a throw, an exit, a hook past its limit, and a return that is not an answer of its point are a failed hook (owner decision of 2026-11-06):

- `before_tool` fails closed: the call is denied, and the tool result says which hook failed and how.
- `after_tool` and `before_settle` fail open: the result stays as the hook before it left it, or the session settles, and a `:notice` event names the failed hook.

A failed hook does not fail the turn, and is not retried.

### 6. The record

Each answer of a hook is one entry of the session file, of a new type `hook`, that the session writes when it gets the answer: every answer of a `before_tool` hook, an allow too, and every answer of the other points that is not the default (a replace, a continue, or a failure). The chain sends each answer to the session as the hook gives it, a failure of the hook too, before it starts the next hook. An entry holds the point, the turn id, the call id or nil, the hook module, and its answer with its reason or its failure, cut at 4,096 bytes. So the user can later see what was allowed and why, and by which hook (#503). The outcome of a chain is not stored: it follows from its entries (the first deny, or an allow from each hook) and from the result of the call. A `keep` and a `settle` are not recorded: nothing changed.

- **The call in the entry.** The first entry that a chain on a call writes also holds the tool name and the JSON of the arguments, cut at 4,096 bytes at a character boundary, with a flag that says it was cut; the later entries of the same chain hold the call id only. So the entry stands alone: a Codex call stays in the open assistant message until its first result (`Helyx.Session.Server.Records`), and a hook can allow it, and the program act on it, before the file holds it. A copy is needed, not derived: the transcript cannot supply a call that a crash kept out of the file. The cut bounds the copy, as #503 asks for the arguments of a record.
- **An abort.** The answers that reached the session before the abort are saved; the hook that runs at the abort gave no answer and has no entry, and the hooks after it never run. The abort itself is the turn's end, `:aborted`, in the transcript.
- **No entry.** A request that Core denies at once (no `before_tool` hook, past the 8 running and 16 waiting chains, a second request for one call, or no open call, §4) has no entry: no hook decided it, as no hook decides a Helyx call that runs with none.

The entry holds no result: the result of a Helyx call is in the transcript, and the program gives the result of a harness call. The reader keeps no state from the entry and checks its shape; a bad entry is dropped and logged, the smallest unit (AGENTS.md). The entries reach no client in the first version.

### 7. The approval gate: the first hook plugin

`Helyx.Hook.Approval` is a bundled hook plugin on `before_tool` with the requirements of #503:

- Its rules come from its config first: for each tool name, with `provider` nil or a provider id, `allow`, `deny`, or `ask`. The rule shape, its matching, and the default rule are in its feature doc.
- `ask` asks the clients with `Helyx.Hook.ask/1` (§3), the ask of ADR 0011 §4, with a request that is an `approval` UI block (the vocabulary of `docs/features/ui-blocks.md`), and the `answer` operation. No new wire path. The answer allows or denies, and the allow or deny names the user as its reason; any other answer is a deny.
- No answerer: with `{:error, :no_client}` (no client attached, a print run, or a child session of the agent tool, which has no client) the gate denies at once, and the reason says so. The wait for an answer is bounded by the limit of the hook (§3), and past it the call is denied (§5). An abort ends the pending ask with the call, and the ask ends with the outcome `:ended`.
- An automatic reviewer that allows calls by itself and a sandbox are out of scope: the gate decides, it does not isolate.

### 8. A command hook

`Helyx.Hook.Command` is a bundled hook plugin that runs a command from its config at a point, with the call as JSON on its standard input, and keeps the exit code meanings of the Claude Code hook format, so the exit code of a hook script written for it means the same in Helyx:

- Exit 0: success; standard output can carry an answer in JSON (its shapes are in the feature doc).
- Exit 2: block, with standard error as the reason: a deny at `before_tool`; at `after_tool`, the result with standard error added for the model; at `before_settle`, `{:continue, stderr}`.
- Any other exit: an error of the hook, which §5 handles per point. At `before_tool` this differs from Claude Code, where the call goes on: Helyx fails closed (owner decision of 2026-11-06).

The command runs in its own process group, held with `Helyx.Tool.hold/1`; the plugin's `release/3` ends the group, and the hands call it as §3 states (ADR 0004). Its output is read up to a bound that the feature doc sets.

## Bounds

| Input | Bound | Over it |
|---|---|---|
| the time of one hook at one point | its limit, 1 to 600,000 ms, checked at Core start | a failed hook (§5) |
| hooks on one point | the plugin list of Core | none at run time; each hook has its limit, and the abort ends the chain |
| a deny reason, a replaced result | `Helyx.Message.max_result_bytes/0`, 65,536 bytes, as a tool result | cut (`Helyx.Message.cut_result/1`) |
| the text of a continue | the bound of a user message text, as a follow-up: `Helyx.Session.Input.max_text_bytes/0`, 4 MiB | a failed hook (§5) |
| turns that hooks start in a row | a count that the feature doc sets, reset by a client message | the session settles, with a `:notice` |
| the reason or failure of a `hook` entry; the JSON of the arguments in it | 4,096 bytes each | cut at a character boundary; the arguments with a cut flag |
| `hook` entries | one for each answer of a `before_tool` hook, and one for each answer of another point that is not the default; at most one for each hook of the plugin list on one chain; each holds no result, and only the first of a chain holds the cut arguments | the 64 MiB of the session file, as every entry |
| chains of harness requests of a turn | 8 run and 16 wait, a set of their own beside the tool queue; one pending request for each call | denied at once; a second request for one call is denied |
| `approval_id` | 1 to 256 bytes of valid UTF-8, unique among the pending requests; no ids of ended requests are kept | a malformed event: the provider process stops |
| hook Tasks of a session at once | 17: 8 tool call chains, 8 harness chains, and one `before_settle` chain, one hook at a time in each | not reachable: each chain is bounded above |
| a waiting harness chain | the sum of the limits of the hooks of the chains ahead of it | the abort ends it |
| the request of an approval ask, its answer | 65,536 and 16,384 bytes of JSON (ADR 0011 §4) | the rules of the ask |
| the output of a command hook | a bound that the feature doc sets | the feature doc names it |

## Considered options

- **A gate in Core between the turn loop and `Tool.run/2`.** Rejected: the policy would be in Core, and the next permission feature would add a second gate.
- **A check in each tool and each provider.** Rejected: several gates that disagree, and a harness request would have its own.
- **A hook that changes the arguments.** Rejected: it would change what an earlier hook of the chain allowed.
- **An allow that ends the chain.** Rejected: a deny wins, so every hook must see a call that runs.
- **Fail open everywhere, or fail closed everywhere.** Rejected by the owner: a broken gate must not let a call through, and a broken check after a call must not stop the session.
- **Continue as the same turn.** Rejected: a turn ends at the provider, and a harness completes its own turn.
- **Accept a harness approval with no hook.** Rejected: it would change the answer of today, and the program asked because its policy wanted a decision.

## Consequences

- AGENTS.md and the README list Hook with Provider, Tool, ModelContext, Compaction, and Memory. ADR 0007 gets an update: approvals go through the chain of this ADR.
- An older Helyx reader refuses a session file with a `hook` entry ("entry the writer never produces", `lib/helyx/session/file/reader.ex`), so a file that a newer Helyx wrote does not resume on an older one.
- The origin kind `:hook` is a new value of `origin` in the wire `message`, so the wire protocol number changes with it (ADR 0008 §7).
- **Accepted hole: Codex with the default policy.** With `codex_approval_policy` `never`, the program asks for no decision, so its own `apply_patch`, `request_user_input`, sub-agent, and MCP resource tools run with no hook. A session that must gate them runs with another policy. A `read-only` thread with an `apply_patch` was not run on codex 0.163.0 (research note, "Not run").
- **Accepted hole: sub-agents.** A child session of the agent tool has no client, so the gate denies every call that its rules send to the user there.

The follow-up feature tickets, for the owner to file:

1. **The Hook interface and the tool chain.** `Helyx.Hook` with `before_tool` and `after_tool`, the order, the limits and their check at Core start, the fail rule, the hook Tasks of the hands with their hold and release, `Helyx.Hook.ask/1` with the monitor of the hook Task that asks, the refusal of hook starts after an unconfirmed release, the `hook` entry of the session file and its reader, and `docs/features/hooks.md`. AGENTS.md and the README. Blockers: none.
2. **Before settle and the continue turn.** `before_settle`, the origin kind `:hook`, the count of turns in a row, and the wire change with a new protocol number. Blockers: ticket 1.
3. **Harness approvals through the chain.** The stream event and the request of §4, the `approval_id` check against the pending requests, in `Helyx.Provider` and `Helyx.Session.Stream.check/1`, the Codex mapping to `accept` and `decline`, the deny at an abort, and an update of ADR 0007. First a research run on the current codex: an approval request with `untrusted` and `read-only`, for `apply_patch`. Blockers: ticket 1.
4. **The approval gate.** `Helyx.Hook.Approval`: the rules and their config, the `approval` kind in `docs/features/ui-blocks.md` with its answer shape, the deny with no client, and the TUI renderer. Blockers: ticket 1, and the build of ADR 0011 that adds the UI block check to `Helyx.Tool.ask/1` and the vocabulary document.
5. **The command hook.** `Helyx.Hook.Command`: the config, the JSON on standard input and the answer shapes on standard output, the exit codes of §8, the process group, and the output bound. Blockers: ticket 1; its `before_settle` part, ticket 2.
