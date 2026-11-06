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

`Helyx.Tool.ask/1` and `Helyx.Hook.ask/1` go to the hands, which know each Task: the hands pass an ask on to the session only when the caller is the call Task of the call id of its context (`Helyx.Tool.ask/1`) or a hook Task of that call (`Helyx.Hook.ask/1`). Any other caller gets `{:error, :not_running}`: a hook Task that calls `Helyx.Tool.ask/1`, a call Task that calls `Helyx.Hook.ask/1`, a background run, and a process that a hook or a tool started (it has no hands in its process dictionary). A process with no call context raises, as before.

The session then checks that the call id runs in the tool queue of the current turn, as before, and monitors the asking Task with each ask that it takes. At the `:DOWN` of that Task, whatever the cause, the ask ends with the outcome `:ended`, so no question stays open on a client while later hooks run. The end of the call and the end of the turn still end the asks, and remove their monitors. A Task asks one question at a time (the ask is a call), so one monitor for each ask is one monitor for each asking Task.

The pass through the hands waits while the hands release the handles of another Task (ADR 0004).

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

## Replaced mechanism

1. The ask: `Helyx.Tool.ask/1` called the session; it now calls the hands, which pass it on with the caller's pid. The session took an ask from any process while its call id ran; now only the call Task of the call or a hook Task of it. The reply rules (`:no_client`, `:not_running`, the answer, `:not_waiting`) stay.
2. The ask's end: the end of the call and of the turn ended an ask; the `:DOWN` of the asking Task now ends it too.
3. The hold: the hands took a hold only from a call Task; now from a hook Task too, released with the hook module's `release/3`.
4. The start answer of a background run went to the session as `{:started, text}`; it is now `{:started, {status, text}}`, so a hook's replace keeps its status. `Helyx.Session.Background.lost/1` took only a start answer of an ok result; it now takes one of an error result too, since a hook can give it that status. Its test changes with it.
5. Tests: `test/helyx/session/ask_test.exs` sent a raw `{:ask, …}` call to the session; it now goes through the hands.

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

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| a resource that a hook holds with `Helyx.Tool.hold/1` | the hook in its Task | the hands | `release/3` of the hook, `:deliver`, before the chain goes on | the same, at the Task's `:DOWN`; `:cancel` at its limit and when its call Task dies; the hook frees it itself when the hands are gone (ADR 0004) | `release/3`, `:cancel`, in the cancel of the turn |
| the monitor of an asking Task | the session | the session | removed at the answer, the call end, or the turn end | its `:DOWN` ends the ask | removed at the turn end |

## Out of scope

`before_settle` and the continue turn (#880), harness approvals and their chain set (#881), the approval gate (#882), the command hook (#883). The `hook` entries reach no client.
