# Hooks: the interface and the tool chain

Ticket #879, follow-up 1 of ADR 0013 (`docs/adr/0013-hooks.md`). The ADR holds the decisions and their reasons; this doc states the shape that the build adds for `before_tool` and `after_tool`. `before_settle` and the continue turn (#880), harness approvals (#881), the approval gate (#882), and the command hook (#883) are later tickets.

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

- **The record.** When the hands start a call Task or a hook Task, they send the session `{:asker, turn_id, pid, {:tool | :hook, call_id}}`. The Task waits for a `:helyx_go` from the session before any plugin code runs (a hook Task arms the kill of its limit first, so the wait counts against the limit). The session sends that go after it handled the record, so it holds the record before the Task can ask: the order is that of one process, the session, which handled the record before it sent the go, not an order of two senders (AGENTS.md, #592). The session does not wait for the hands: it answers the record when it comes, as any message. The session keeps the record in the current turn when the turn id matches, with a monitor of the Task, and drops it at the Task's `:DOWN`; the end of the turn drops every record and its monitor. A record of a turn that is no longer current is not kept: its call does not run, so its Task could not ask; that Task gets its go all the same, and the end of its turn kills it. The start answer of a background run drops the record of its call Task, as the hands drop the Task from the turn, so a later call of the same id in the turn is not the run's. The hands send the start answer with the pid of the run, and `Helyx.Tool.started/1` returns only when the session's go comes, which the session sends after it handled the start answer: so an ask of the run reaches the session after the drop, by the order of the session alone, and gets `{:error, :not_running}`.
- **The check.** `Helyx.Tool.ask/1` and `Helyx.Hook.ask/1` call the session. It takes an ask only when the caller's record is `{:tool, call_id}` for `Helyx.Tool.ask/1` or `{:hook, call_id}` for `Helyx.Hook.ask/1`, with the call id of its context, and that call id runs in the tool queue of the current turn, as before. Any other caller gets `{:error, :not_running}`: a hook Task that calls `Helyx.Tool.ask/1`, a call Task that calls `Helyx.Hook.ask/1`, a background run (its call no longer runs), and a process that a hook or a tool started (it has no record). A process with no call context raises, as before.
- **The end.** At the `:DOWN` of the Task, whatever the cause, its open ask ends with the outcome `:ended`. A hook Task's ask also ends at the answer of the hook that the hands send (`{:hook_answer, ...}`, with the pid of the hook Task): a hook of a chain that goes on and that ends with an open ask (killed at its limit, crashed) ends as a failure, which is always sent, and the hands send it before the record of the next hook, so the order is that of one sender, the hands, and not that of the `:DOWN` against the hands' record. So no question stays open on a client while later hooks run. A hook killed with its call Task or by a cancel sends no answer; no later hook of its chain runs then, and the end of the call or of the turn ends its ask. The end of the call and the end of the turn still end the asks. A Task asks one question at a time (the ask is a call).

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
- `Helyx.Sessions.remove_message/3` keeps every `hook` entry, also one of a removed call, with its copy of the arguments (`session-edit.md`, decision 5 and "What the calls do not remove").

## Replaced mechanism

1. The ask: `Helyx.Tool.ask/1` still calls the session, with the kind of the ask. The session took an ask from any process while its call id ran; now only from the Task whose record, sent by the hands at its start, has that kind and call id. The reply rules (`:no_client`, `:not_running`, the answer, `:not_waiting`) stay. A call Task and a hook Task wait for the session's `:helyx_go` before they run, and a background run waits for it again after its start answer, which the hands now send as `{:started, result, pid}`.
2. The ask's end: the end of the call and of the turn ended an ask; the `:DOWN` of the asking Task now ends it too, and for a hook Task the hook's answer from the hands.
3. The hold: the hands took a hold only from a call Task; now from a hook Task too, released with the hook module's `release/3`.
4. The start answer of a background run went to the session as `{:started, text}`; it is now `{:started, {status, text}, pid}`, so a hook's replace keeps its status, and the session can let the run go on (item 1). `docs/features/print-background-wait.md` names the new shape. **Changed rule:** `Helyx.Session.Background.lost/1` took only a start answer of an ok result ("an error result is no start"); it now takes one of an error result too. Reason: a hook can give a start answer the error status while the run goes on, and the run did start, so a stop that loses it must give its lost end, which tells the model to check its effects. Its test changes with it.
5. Tests: `test/helyx/session/ask_test.exs` sent a raw `{:ask, call_id, tool, request}` call to the session; the call now carries the kind, `{:ask, kind, call_id, tool, request}`.

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
| the session's records of call and hook Tasks | one for each call Task and hook Task of the current turn that lives: at most 8 call Tasks that run at once, and one hook Task for each of them; a call Task that goes on in the background loses its record at its start answer | not reachable: a record goes at the `:DOWN` of its Task or, for a hook Task, at its answer, and all go at the turn end |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| a resource that a hook holds with `Helyx.Tool.hold/1` | the hook in its Task | the hands | `release/3` of the hook, `:deliver`, before the chain goes on | the same, at the Task's `:DOWN`; `:cancel` at its limit and when its call Task dies; the hook frees it itself when the hands are gone (ADR 0004) | `release/3`, `:cancel`, in the cancel of the turn |
| the monitor of a call or hook Task | the session, at the hands' record | the session | its `:DOWN` at the Task's end, or the answer of a hook Task, drops the record; the turn end demonitors the rest | the same | the turn end demonitors it |

## Out of scope

`before_settle` and the continue turn (#880), harness approvals and their chain set (#881), the approval gate (#882), the command hook (#883). The `hook` entries reach no client.
