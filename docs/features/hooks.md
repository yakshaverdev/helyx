# Hooks: the interface and the tool chain

Ticket #879, follow-up 1 of ADR 0013 (`docs/adr/0013-hooks.md`). The ADR holds the decisions and their reasons; this doc states the shape that the build adds for `before_tool` and `after_tool`, and, with #881, for harness approvals. `before_settle` and the continue turn (#880, `docs/features/before-settle.md`), the approval gate (#882), and the command hook (#883) are later tickets.

## Goal

A product or a user adds a check before and after each Helyx tool call without a change to a tool or to Core: a hook plugin. Core owns the chain (order, limits, fail rule, record); the plugin owns its policy (ADR 0013 §1).

## Interface changes

### `Helyx.Hook`, mode `:multi`

```elixir
@callback before_tool(call()) :: :allow | {:allow, String.t()} | {:deny, String.t()}
@callback after_tool(call_with_result()) :: :keep | {:replace, {:ok | :error, String.t()}}
@callback limit(point()) :: pos_integer()
@callback release(handles :: [term()], mode :: :deliver | :cancel, deadline :: integer()) :: [term()]
@optional_callbacks before_tool: 1, after_tool: 1, release: 3
```

- `call()` is a map: `tool` (name), `arguments` (as Core checked them), `cwd`, `session_id`, `turn_id`, `call_id`, and `provider`, which is nil for a Helyx tool call. `after_tool` gets the same map with `result`, `{:ok | :error, text}`, the result before the hands cut it.
- `before_settle` (`docs/features/before-settle.md`) gets `settle()`, a map: `session_id`, `turn_id`, `stop_reason`, and `cwd`, the session's folder, the same folder as the `cwd` of a call.
- `Helyx.Hook.ask/1` asks the clients from a hook Task, with the request rules, the event, and the answers of `Helyx.Tool.ask/1`.

### Core start

Core reads the hook plugins of the plugin list, in its order, and for each one the points that it exports (`before_tool/1`, `after_tool/1`):

| Value | Answer |
|---|---|
| a hook plugin that exports no point | the start stops with `{:no_hook_point, module}` |
| `limit/1` not exported, or `limit(point)` not an integer from 1 to 600,000 for a point that the plugin exports | the start stops with `{:invalid_hook_limit, module}` |

`limit/1` runs once per point at start; a raise there is not contained, as for every start callback of Core. The ADR names `{:invalid_hook_limit, module}` and says that a plugin with no point is refused; the name `{:no_hook_point, module}` is set here.

### The chain of a Helyx tool call

The call Task of the hands runs: the `before_tool` chain, then the tool, then the `after_tool` chain, then returns the result to the hands, which release the tool's handles, cut the text, and deliver it.

- `before_tool` hooks run in plugin order and the chain stops at the first deny or failure. A deny gives the error result `the hook <Module> denied the call: <reason>`; a failure gives `the hook <Module> failed: <how>; the call was not run`. Both are cut by `Helyx.Message.cut_result/1` in the hands, as any result.
- `after_tool` hooks run in plugin order, each on the result that the hook before it left. `{:replace, result}` passes the new result on; a failure keeps the result that the hook before it left, and the session emits a `:notice`: `the hook <Module> failed after the call <call id>: <how>`, with `<how>` cut at 4,096 bytes. An answer that reaches the session after its turn ended (an abort raced it) is written, with no notice.
- A background run (`Helyx.Tool.started/1`): the `after_tool` chain runs on the start answer, in `started/1`, before the hands deliver it; its status is kept, so a replace with `{:error, text}` gives an error start result while the run goes on. The end of the run gets no hook. A start answer in an error result counts as a start at a resume, so a run that the stop lost still gets its lost end (`Helyx.Session.Background.lost/1`). A call that took no place with `Helyx.Tool.background/0` runs no hook in `started/1`, which raises; its error result gets the `after_tool` chain as any result.
- The tool's own handles are released when the call delivers, after the `after_tool` chain, as before hooks. A handle that this release leaves unconfirmed makes the delivered result the fixed error of an unreleased resource, whatever the hooks answered; their `hook` entries stay, a log of the answers (ADR 0013 §6), not of the outcome.
- A failed hook is a raise, a throw, an exit, a hook past its limit, a return that is not an answer of its point (a reason or a text that is not a string of valid UTF-8 included), a hook start refused after an unconfirmed release, and a hook whose handles its release left unconfirmed.

### Hook Tasks of the hands

- Each hook runs in a Task of the hands of its own, under the turn and the call id of its call. The call Task asks the hands with a call and waits; the hands start the hook Task and answer the call Task after the release of the hook's handles. So the session never waits for a hook. A request from a Task that is no call Task of a turn, such as a call Task that a cancel killed after it sent the request, gets no answer.
- The hook Task arms its own kill at the OTP timer server as its first act (`:timer.kill_after/1`), so the limit holds while the hands are busy with the release of another Task. A kill at or after the limit is a hook past its limit; its handles get `:cancel`.
- The hook Task has the call's context (`Helyx.Tool.context/0`), takes holds with `Helyx.Tool.hold/1`, and the hook module's `release/3` gets its handles: with `:deliver` when the hook ends, with `:cancel` at its limit and at an abort or a stop, with the release deadline of ADR 0004.
- When the call Task dies while one of its hooks runs (a linked process that dies, for example), the hands kill the hook Task and release its handles with `:cancel` before they deliver the call's error result.
- Once a release left a handle unconfirmed, the hands refuse each hook start (a failed hook), as they refuse tool calls and provider starts.
- A hook Task is no tool call: `Helyx.Tool.background/0` answers it with an error, and `Helyx.Tool.started/1` raises.

### The caller check of an ask

The session checks the caller of each ask (ADR 0013 §3), and the session never waits for the hands to do it.

- **The record.** When the hands start a call Task or a hook Task, they send the session `{:asker, turn_id, pid, {:tool | :hook, call_id}}`. The Task waits for a `:helyx_go` from the session before any plugin code runs (a hook Task arms the kill of its limit first, so the wait counts against the limit). The session sends that go after it handled the record, so it holds the record before the Task can ask: the order is that of one process, the session, which handled the record before it sent the go, not an order of two senders (AGENTS.md, #592). The session does not wait for the hands: it answers the record when it comes, as any message. The session keeps the record in the current turn when the turn id matches and the call has no result in the transcript or is open again (a request that names an answered call, #369, gets none), with a monitor of the Task, and drops it at the Task's `:DOWN`; the result of the call in the transcript drops the records of its call and hook Tasks with their monitors (#878, `docs/features/ui-blocks.md`), and the end of the turn drops every record and its monitor. A record of a turn that is no longer current is not kept: its call does not run, so its Task could not ask; that Task gets its go all the same, and the end of its turn kills it. The start answer of a background run drops the record of its call Task, as the hands drop the Task from the turn, so a later call of the same id in the turn is not the run's. The hands send the start answer with the pid of the run, and `Helyx.Tool.started/1` returns only when the session's go comes, which the session sends after it handled the start answer: so an ask of the run reaches the session after the drop, by the order of the session alone, and gets `{:error, :not_running}`.
- **The check.** `Helyx.Tool.ask/1` and `Helyx.Hook.ask/1` call the session. It takes an ask only when the caller's record is `{:tool, call_id}` for `Helyx.Tool.ask/1` or `{:hook, call_id}` for `Helyx.Hook.ask/1`, with the call id of its context, and that call id runs in the tool queue of the current turn, as before. Any other caller gets `{:error, :not_running}`: a hook Task that calls `Helyx.Tool.ask/1`, a call Task that calls `Helyx.Hook.ask/1`, a background run (its call no longer runs), and a process that a hook or a tool started (it has no record). A process with no call context raises, as before.
- **The end.** At the `:DOWN` of the Task, whatever the cause, its open ask ends with the outcome `:ended`. A hook Task's ask also ends at the answer of the hook that the hands send (`{:hook_answer, ...}`, with the pid of the hook Task): a hook of a chain that goes on and that ends with an open ask (killed at its limit, crashed) ends as a failure, which is always sent, and the hands send it before the record of the next hook, so the order is that of one sender, the hands, and not that of the `:DOWN` against the hands' record. So no question stays open on a client while later hooks run. A hook killed with its call Task or by a cancel sends no answer; no later hook of its chain runs then, and the end of the call or of the turn ends its ask. The end of the call and the end of the turn still end the asks. The result of the call in the transcript ends them too, as it ends the records, and its caller, a Task that can still run, as after an `aborted` result at a taken steer, gets `{:error, :not_running}`: an ask is an input UI block, and no block of a call comes after its result (#878). A Task asks one question at a time (the ask is a call).

### The `hook` entry of the session file

The hands send each answer of a hook to the session as they deliver it, before the call Task starts the next hook; the session appends one entry (ADR 0013 §6):

```json
{"type": "hook", "point": "before_tool", "turn_id": "…", "call_id": "…", "hook": "Acme.Hook.Gate",
 "answer": "allow" | "deny" | "replace" | "failed", "reason": "…" | null,
 "tool": "bash", "arguments": "{…}", "arguments_cut": false}
```

- Every answer of a `before_tool` hook is written, an allow too; an `after_tool` hook writes only a replace or a failure.
- `reason` is the reason of an allow or a deny, or the text of a failure, cut at 4,096 bytes at a character boundary; a replace has none.
- `tool`, `arguments`, and `arguments_cut` are only in the first entry that a chain writes on a call (one chain is one point on one call): `arguments` is the JSON of the arguments, cut at 4,096 bytes at a character boundary, and `arguments_cut` says whether it was cut. The call Task makes this copy, so the session encodes nothing large.
- A resume reads no `hook` entry (a log only). The reader checks the shape: a bad entry is dropped and logged, and the chain goes on.
- A chain with no closing answer in the file counts as not run: a saved call with no result gets the interrupted result at the resume, as before.
- `Helyx.Sessions.remove_message/3` removes every `hook` entry whose `call_id` is a call of the removed messages, with its copy of the arguments and its reason, and keeps every other one, relinked to one chain (`session-edit.md`, decision 5).

### Harness approvals (#881)

A provider asks for a decision on a call of its own tools (ADR 0013 §4); Codex does for an approval request of the program (`docs/features/long-lived-harness.md`, "Server requests"). The set of approval chains of a turn (`Helyx.Session.ApprovalChains`, the field `approval_chains` of `Helyx.Session.Turn`) is the set that ADR 0013 §3 and §4 name the set of harness chains: Core names no harness (AGENTS.md).

- **The event and the request.** `{:approval, approval_id, call_id}` is a stream event of `Helyx.Provider`, and `{:approval, turn_id, approval_id, :allow | {:deny, reason}}` a request to the provider, answered with `:ok` as a tool result is. `Helyx.Session.Stream.check/1` takes the event when both ids are strings and `approval_id` is 1 to 256 bytes of valid UTF-8 (`Helyx.Message.approval_id?/1`); any other is a malformed event, and the provider process stops. The provider process sends it to the session with its pid, as a tool request, so a request of a turn that is not current is denied too.
- **The checks of the session**, in order (`Helyx.Session.Server.Approvals`): an `approval_id` that is pending in the turn's set of approval chains is a contract break, and the provider process stops, as for an open tool call id. A `call_id` that names no open call that the provider runs itself (a call of the open assistant message, or of the last closed message with no result, that is no Helyx call: "The owner of a call id" below) is denied at once. With no `before_tool` hook the request is denied at once. Then the set (`Helyx.Session.ApprovalChains`): a second request for a call with a pending one is denied at once; 8 chains run and 16 wait, in arrival order, and a request past them is denied at once. These denials have no `hook` entry. ADR 0013 §4 gives an approval of a child thread as a request that Core denies; Codex declines one itself and Core never sees it (`docs/features/long-lived-harness.md`, "Server requests").
- **The owner of a call id.** An open call of the turn belongs to one owner: Helyx, when a Helyx tool request named it, or the provider, when an approval request named it. An approval request for an open call that a Helyx tool request named (it runs, waits, or was answered) is denied at once, as ADR 0013 §4 rules for a request that names no open call that the provider runs itself. A Helyx tool request for an open call that an approval request named (its chain runs or waits, or it was answered) breaks the contract: the provider process stops and the turn fails, as for a tool request whose call id is open in the tool queue (`Helyx.Session.Server.ToolRuns`). So the hands never run two chains, and two hook Tasks, on one call id, and no open call is both, apart from the accepted hole below. The scope is the open call: once a call has its result, its id is an ended id, which ADR 0013 §4 and #369 leave unchecked, but for an approval request for an id that a Helyx tool request of the turn named, which is denied (#878, below).
  - Derived from the state that the session holds: a call that runs or waits in the tool queue is a Helyx call; a call whose approval chain runs or waits in the set of approval chains is the provider's; a call with a result in the transcript is no open call, so an approval for it is denied, and a tool request for it is an ended id, not checked (#369).
  - Not derivable: a Helyx call that Core answered, and a call whose approval Core answered, while the call has no result yet. A harness provider's call gets its result in the transcript only from the provider's own `tool_result` event, the session keeps no request that it answered (`ToolRuns` drops the ref of a result that it sent, and `ApprovalChains.result/3` drops the request), and the hands drop a Task when it delivers. So `owners` in `Helyx.Session.Turn` keeps the owner of each open call that a request named. It is set when the session takes the request, and when it answers a Helyx tool request whose call opened after the request (`Helyx.Session.Server.Approvals.own/3`). So it also holds the owners of the pending requests, which are derivable: one write covers both. An entry goes at its call's result or `aborted` result (`Approvals.drop/2`), unless another open call keeps the id (two calls of one message can share an id: a result answers the first open one), and all go with the turn.
  - Ended ids, not checked (#369): a Helyx tool request for a call that opened after an approval request for it was denied with no open call. An approval request for an open call whose id a Helyx tool request of the turn named, also one of an earlier message that Core answered, is denied: the session keeps the Helyx call ids of the turn (`docs/features/ui-blocks.md`, #878).
  - Reused ids, not checked (#369, orchestrator decision of 2026-11-08): `owners` is keyed by the call id, so a call id that a later message reuses can take the owner of an earlier call of the id. When the earlier call gets its result, or its `aborted` result at a close, while the open message holds the new call, the owner stays for the new call: an approval request for it is denied, or a Helyx tool request for it stops the provider. And the answer of an earlier Helyx tool request can give the new call the owner `:tool` (`own/3`). No provider of this repository reuses a call id (`docs/reviews/2026-11-07-harness-approvals-881.md`, finding 33).
  - **Accepted hole, the one exception to the deny of ADR 0013 §4, past the bound of the Helyx call ids:** the session keeps the id of each Helyx tool request of the turn, at most 256 ids and 65,536 bytes (`helyx_calls`, `docs/features/ui-blocks.md`, #878), so an approval request for a call that opened only after the session answered its Helyx tool request is denied, as ADR 0013 §4 rules. A request past that bound keeps no id, so a call that opens only after the session answered such a request has no owner, and an approval request for it runs the `before_tool` chain. Reasons: no provider of this repository reaches it, since Codex sends a tool request only for an open `dynamicToolCall` item, whose `item/started` gave the call (`Helyx.Provider.Codex.Tools`), `Helyx.Provider.Loop` sends a message's calls before their tool requests, and Claude Code sends no approval request; and the set of a turn is bounded (orchestrator decisions of 2026-11-08, `docs/reviews/2026-11-07-harness-approvals-881.md`, finding 26, and #878).
- **The chain.** The hands run the `before_tool` chain of the call in a Task of the turn, with the context of a call Task, the hook input with `provider` set to the provider id, and the deny and failure texts of a Helyx call as the reason; each hook runs in a hook Task as for a Helyx call, with the same entries. The chain Task runs no plugin code, holds nothing, and has no ask record. Its decision goes to the session as `{:approval_result, turn_id, call_id, decision}`, a deny reason cut by `Helyx.Message.cut_result/1`; a crash of the chain Task is a deny. A decision of a turn that ended is dropped.
- **Asks.** A hook Task of an approval chain asks with `Helyx.Hook.ask/1` while its chain runs in the set and its call has no result: the result of the call in the transcript ends the records of its Tasks and their asks (#878, `docs/features/ui-blocks.md`), so an ask of the chain after it gets `{:error, :not_running}`, and the chain decides without it; any other Task of that call id gets `{:error, :not_running}`.
- **The end of the turn.** At any end of the turn the session denies each pending request, before the `aborted` answers of the open tool requests and before an interrupt; the hands kill the running chains, also at a `done`. ADR 0013 §4 names the deny at an abort; the deny at every end follows from its rule that a request is never dropped. The exception, as for the `aborted` answers of tool requests: no request goes to a provider process that is `:ending`, which the session stopped; the stop of the process ends its requests.

## Replaced mechanism

1. The ask: `Helyx.Tool.ask/1` still calls the session, with the kind of the ask. The session took an ask from any process while its call id ran; now only from the Task whose record, sent by the hands at its start, has that kind and call id. The reply rules (`:no_client`, `:not_running`, the answer, `:not_waiting`) stay. A call Task and a hook Task wait for the session's `:helyx_go` before they run, and a background run waits for it again after its start answer, which the hands now send as `{:started, result, pid}`.
2. The ask's end: the end of the call and of the turn ended an ask; the `:DOWN` of the asking Task now ends it too, and for a hook Task the hook's answer from the hands.
3. The hold: the hands took a hold only from a call Task; now from a hook Task too, released with the hook module's `release/3`.
4. The start answer of a background run went to the session as `{:started, text}`; it is now `{:started, {status, text}, pid}`, so a hook's replace keeps its status, and the session can let the run go on (item 1). `docs/features/print-background-wait.md` names the new shape. **Changed rule:** `Helyx.Session.Background.lost/1` took only a start answer of an ok result ("an error result is no start"); it now takes one of an error result too. Reason: a hook can give a start answer the error status while the run goes on, and the run did start, so a stop that loses it must give its lost end, which tells the model to check its effects. Its test changes with it.
5. Tests: `test/helyx/session/ask_test.exs` sent a raw `{:ask, call_id, tool, request}` call to the session; the call now carries the kind, `{:ask, kind, call_id, tool, request}`.
6. The Codex server requests (#881): every server request got the JSON-RPC error -32601, an approval request too. Now an approval request of the provider's thread and its current turn, for an open item of the type that its method names, goes to Core; any other `item/commandExecution/requestApproval` or `item/fileChange/requestApproval` with an integer or string id gets `decline` at once; and only the other server requests keep the error (`docs/features/long-lived-harness.md`, "Server requests"). The Codex test "every server request gets an error, an approval request too" is now "an approval request with no item is declined at once; any other server request gets an error".
7. The ask check (#881): the session took an ask for a call id that runs in the tool queue; it now also takes one of a hook Task (`Helyx.Hook.ask/1`) for a call id whose approval chain runs in the set of approval chains (`Helyx.Session.Server.Asks.ask/5`).
8. The hook start (#881): `Helyx.Session.Hands.Hooks.start/4` took a hook only from a call Task, found with `Helyx.Session.Hands.tool_call/2`; it now also takes one from the chain Task of an approval request, found with `Helyx.Session.Hands.State.chain_call/2`. `tool_call/2` moved to `Helyx.Session.Hands.State` with it.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| a hook's limit | 1 to 600,000 ms, checked at Core start | the start stops with `{:invalid_hook_limit, module}` |
| one hook's run | its limit, armed at the OTP timer server by the hook Task, then the release deadline of ADR 0004 | killed: a failed hook; the handle unconfirmed refuses later hook starts and calls |
| hook Tasks at once | one for each of the 8 calls that run at once in a turn | not reachable: a chain runs one hook at a time |
| a deny reason, a replaced result | `Helyx.Message.max_result_bytes/0`, cut in the hands | cut |
| the reason or failure of a `hook` entry; its arguments JSON | 4,096 bytes each | cut at a character boundary; the arguments with `arguments_cut: true` |
| `hook` entries of a chain | one for each hook of the point on one call | the 64 MiB of a session file line, as every entry |
| the text of an after_tool failure notice | the failure text, cut at 4,096 bytes | cut |
| an ask request and answer | as `Helyx.Tool.ask/1`: 64 KiB and 16 KiB of JSON | as before |
| the set of approval chains of a turn | 8 run and 16 wait; one pending request for each call | denied at once |
| `owners` of a turn: the owner of each open call that a request named | one entry for each open call: the calls of the open assistant message and of the last closed message with no result, at most 2 × 1,024 (`Turn.max_message_blocks/0`, the block bound of an assistant message); an entry goes at its call's result or `aborted` result when no other open call keeps its id, and all go with the turn | not reachable: an entry is set only for an open call |
| a waiting approval chain | for each hook of the chains ahead of it, its limit and the release deadline of ADR 0004 (ADR 0013, Bounds) | the end of the turn denies it |
| the approval requests that the Codex provider keeps (`approvals` of its state) | one for each request that Core has not answered yet: at most 24 wait for a chain (8 run and 16 wait), and the others only for the session to handle them, which denies them at once; a request of an ended turn is denied when the session handles it (`Helyx.Session.Server.Approvals.late/4`) | the stop of the provider process ends them |
| an `approval_id` | 1 to 256 bytes of valid UTF-8, unique among the pending requests of the turn; no ended ids are kept | a malformed event: the provider process stops |
| hook Tasks at once, with approval chains | one for each of the 8 calls and the 8 approval chains that run at once | not reachable: a chain runs one hook at a time |
| the session's records of call and hook Tasks | one for each call Task and hook Task of the current turn that lives: at most 8 call Tasks that run at once, and one hook Task for each of them and for each of the 8 approval chains that run; a call Task that goes on in the background loses its record at its start answer | not reachable: a record goes at the `:DOWN` of its Task, for a hook Task at its answer, at the result of its call in the transcript, and all go at the turn end |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| a resource that a hook holds with `Helyx.Tool.hold/1` | the hook in its Task | the hands | `release/3` of the hook, `:deliver`, before the chain goes on | the same, at the Task's `:DOWN`; `:cancel` at its limit and when its call Task dies; the hook frees it itself when the hands are gone (ADR 0004) | `release/3`, `:cancel`, in the cancel of the turn |
| the monitor of a call or hook Task | the session, at the hands' record | the session | its `:DOWN` at the Task's end, the answer of a hook Task, or the result of the call in the transcript drops the record; the turn end demonitors the rest | the same | the turn end demonitors it |

## Out of scope

The approval gate (#882), the command hook (#883). `before_settle` and the continue turn are in `docs/features/before-settle.md` (#880). The `hook` entries reach no client.
