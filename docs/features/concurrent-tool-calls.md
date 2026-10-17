# Concurrent tool calls

Ticket #734.

## Goal

A model that asks for three reads, or three agent runs, in one response gets them at the same time. Before this feature the session ran one Helyx tool call at a time, so the turn took the sum of the calls.

Decisions (ticket #734, orchestrator, owner away):

1. **Opt-in per tool.** `Helyx.Tool` gets the optional callback `concurrent?/0`, default `false`. A call of a concurrent tool runs at the same time as other calls of concurrent tools. A call of any other tool runs alone: it starts when no call runs, and the calls after it wait for its result. Reason: a tool that writes files or runs a shell command can race another call; a tool that only reads, or one that runs its work in its own session, cannot. The bundled `read` is concurrent; `write`, `edit`, and `bash` are not. The agent tool of its own ticket will be concurrent.
2. **A cap.** At most 8 calls run at once in a session turn. The others wait in arrival order, under the existing bounds: at most 16 wait, and the running and waiting calls hold at most 8 MiB of encoded call bytes.
3. **Order.** Each call gets exactly one result. The session sends each result to the provider process when its call ends. The provider construct that orders the results for the transcript stays as it is (see "Where one running call was assumed", item 8).
4. **Failure.** A call that fails does not cancel the others. Its error result goes back as any result does.
5. **Abort.** An abort of the turn ends every running call and every waiting call gets `aborted`, as for the one running call before. The release of the resources of each killed call runs.
6. **No request flag.** The providers do not set a parallel-tool-call flag in a model request.

Further decisions of this doc (owner away; the option that keeps Core smallest and matches the existing code):

- **Arrival order is strict.** Only the first waiting call can start. A concurrent call behind a waiting serial call waits, even with free places. Reason: the model gives the calls in an order; a read after a write in one response must see the write.
- **The session reads `concurrent?/0` once, at the session start or resume** (`Helyx.Tool.concurrent/1`), in the caller, right after `Helyx.Tool.check_available/1` and before it creates any folder or file or reads the sessions directory (`docs/agents/review-checklist.md`, "Inputs from plugins"). Open, older than this feature and shared with `check/0`: `Helyx.Sessions.resume/2` with `:id` and no `:cwd` reads the sessions directory and a file header before `Session.resume/2` runs the checks; it creates nothing. A return other than a boolean raises there, as a bad return of `check/0` does: Core does not contain it. It is not a spec error (`{:bad_tool_spec, label}`): the flag is not part of the spec that the providers get.

## Where one running call was assumed

Step 1 of the ticket. Each place, and what the change does there.

1. **`Helyx.Session.ToolQueue`** (`lib/helyx/session/tool_queue.ex`). `running` was one call id or nil, with `running_bytes`. `request/4` ran a call when `running` was nil; `result/2` took no call id, because only one call could answer. Changed: `running` is a map of call id to its bytes and its `concurrent?` flag; `request/5` takes the flag; `result/3` takes the call id; the start rule is in one function (`start_waiting/2`).
2. **`Helyx.Session.Server.ToolRuns`** (`lib/helyx/session/server/tool_runs.ex`). `result/2` passed the hands' result to the one running call. Changed: `result/3` with the call id. `request/4` reads the flag from the session state.
3. **The session's match of a hands result** (`lib/helyx/session/server.ex`, the clause `tool_queue: %{running: call_id}`). It matched the one running id. Changed: a guard `is_map_key(running, call_id)`. A result for no running call of the current turn is dropped, as before.
4. **The hands** (`lib/helyx/session/hands.ex`). No change. The hands keep each Task by its monitor ref with its turn and call id, so they already run any number of calls. A delivery releases the handles of its own Task only.
5. **The abort and the release.** `ToolQueue.end_turn/1` gave `aborted` to the running id and the waiting ids; it now gives it to every running id and every waiting id. `Hands.request_cancel/2` already kills every Task of the turn and starts one release per tool module with the handles of all its killed Tasks (`docs/features/tool-resource-release.md`, item 5), so the release of each call's handles runs. `Helyx.Session.Server.Wait.finish/2` read `turn.tool_queue.running` as "a call runs": now "the map is not empty". The `turn_end` of #595 still waits for the cleanup answer when any call runs.
6. **The summary call** (`lib/helyx/session/server/summary.ex`). No change: it has no tools, and its tool requests are answered there, outside the queue.
7. **The TUI cells and print mode.** No change. The view model keeps a queue of open cells per call id and closes the cell of each result wherever it is (`Helyx.TUI.ViewModel`), so results in any order render. Print mode prints only assistant messages, notices, and the turn end (`CodingAgent.Print`).
8. **The transcript order.** `Helyx.Provider.Loop` keeps the calls of a message in call order and sends a `tool_result` event only when every call before it has its result (`send_ready/2`). So the transcript keeps call order whatever order the results come in. The harness providers (`Helyx.Provider.ClaudeCode`, `Helyx.Provider.Codex`) map each result to its program request by call id, and the transcript takes the program's own result events, in the program's order. No change.
9. **The texts** that said "one at a time": `docs/features/one-provider-path.md`, `docs/features/session-lifecycle.md`, `docs/features/coding-agent.md`, `docs/agents/review-checklist.md`, the moduledoc of `Helyx.Session`, the `:tool_execution_end` entry of `Helyx.Event`, and the comment of `deliver/3` in `Helyx.Session.Hands`. Changed to the new rule.

## Interface changes

- `Helyx.Tool`: the optional callback `concurrent?() :: boolean()`, and the function `Helyx.Tool.concurrent/1`: the names of the tools of `specs/1` whose callback returns `true`; a tool with no callback is not concurrent; a return that is not a boolean raises.
- `Helyx.Tool.Read`: `concurrent?/0` returns `true`.
- The internal session state field `tools` replaces `tool_modules`: by tool name, the module and its flag of `Helyx.Tool.concurrent/1`. One map keeps the struct at 31 fields, the Credo limit. `Helyx.Session.start/2` and `resume/2` pass the set of concurrent tool names to the session process with the tools.
- No event shape changes. The error text of the count bound changes to `too many Helyx tool calls: 8 run and 16 wait`.

## Replaced mechanism

The one-call queue of `Helyx.Session.ToolQueue`.

1. States and rules. `running: id | nil` becomes `running: %{id => {bytes, concurrent?}}`. The rule "run when nothing runs" becomes: the first waiting call starts when no call runs, or when it is concurrent, every running call is concurrent, and fewer than 8 run. `running_bytes` becomes the sum over `running`. `@max_waiting` (16) and the 8 MiB byte bound stay. The open-id check covers every running id and every waiting id.
2. Removed replies: none. The session still sends exactly one `{:tool_result, ...}` request per call. The one process that sees every request and every hands result of a turn is the session, so the exactly-once guarantee stays in one place.
3. Tests of the old mechanism: `test/helyx/session/tool_queue_test.exs` keeps its properties (open id, rejection, byte bound at, under and over, count bound, results in order for serial calls) with the new arity. `end_turn` keeps "each open call gets `aborted`" and drops "the running one first": several calls run, and the order of the `aborted` answers is not observable, because the transcript closed the open calls before them (`Records.finish/2`) and the provider orders the results itself. `test/helyx/session/provider_process_tools_test.exs`, "the requests of a turn run one at a time, in order", keeps its property: its tools are serial.
4. What users see: calls of `read` in one response overlap. The transcript order does not change for `Helyx.Provider.Loop` providers. The count error text changes.
5. No state without a bound.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| calls that run at once in a turn | 8 (`@max_running`) | the call waits | `ToolQueue.start_waiting/2` |
| calls that wait in a turn | 16 (`@max_waiting`), unchanged | an error result to the provider at once; nothing runs | `ToolQueue.request/5` |
| encoded bytes of the running and waiting calls | 8 MiB together, unchanged | an error result at once; nothing runs | `ToolQueue.request/5` |
| wait of a serial call | until every running call has its result: each has the bound of its tool, or the user aborts | n/a | `ToolQueue.start_waiting/2` |
| delivery of one call behind the release of another | the hands release in their own process, so a result waits for the release of an earlier delivery: at most the release deadline, 20 s | the release reports the handle unconfirmed | `Helyx.Session.Hands`; accepted hole |

Tests at the limits: 8 running and the 9th waits, 16 waiting and the 17th rejected.

Accepted hole: the release of one delivery delays the results of the other calls. `read` has no release, so no bundled tool shows it today. The agent tool (#735) is the first concurrent tool with a release; its ticket decides whether the release moves off the hands loop.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| a tool Task of each running call | `Hands.run/3` | hands | its delivery | the link takes the Task with the hands | `Hands.request_cancel/2` kills every Task of the turn |
| the handles of each running call | the tool's `hold/1` | hands, per Task pid | `release/3` at its delivery | the tool frees them when its Task dies (ADR 0004) | one `release/3` per tool module with the handles of all its killed Tasks |

## Out of scope

- The agent tool: its own ticket.
- A per-file queue that would let `write` and `edit` of different files run together.
- A parallel-tool-call flag in a provider request.
