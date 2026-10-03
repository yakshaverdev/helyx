# Review: tool scheduling owns its state and returns effects (#395)

Date: 2026-10-03. Base: `origin/master` at `4391711`. Scope: the new `lib/helyx/session/tools.ex`, `lib/helyx/session/server/tools.ex`, `server.ex`, `server/turn_loop.ex`, `turn.ex`, the new `test/helyx/session/tools_test.exs`, `test/helyx/session/provider_process_tools_test.exs`, `apps/coding_agent/test/mix/tasks/helyx.graph_test.exs`, `one-provider-path.md`, and `long-lived-harness.md`.

## Invariant

The Helyx tool requests of a turn keep the rules of master, now decided by the pure struct `Helyx.Session.Tools` (held in `Turn.tools`) whose effects `Helyx.Session.Server.Tools` runs: one call runs on the hands and at most 16 wait in arrival order; a request over that gets the "too many Helyx tool calls" error and runs nothing; a rejected request gets "tool call not run"; a request whose call id runs or waits stops the provider process and fails the turn; an answered id runs again (accepted, #369); a withdrawn running call is killed and gets `aborted` at its hands result, and the next waiting call then runs; a withdrawn waiting call gets `aborted` at once; a request of a turn that is not current gets `aborted`; every open call gets `aborted` at the turn end before the interrupt; each call gets exactly one `tool_result` request.

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer
```

Simplify (4 agents): `end_turn/2` runs its effects through `effect/3`, as the other entry points do; `request/3` and `admit/3` merged into one `cond`; a `step` type. Not taken: one shared `{:error, "aborted"}` constant (three copies outside the diff); keeping the 16-waiting session test (the rejection session test still covers the wiring of the `{:result, ...}` effect).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 4 judgement calls, 1 test gap | 0 | Not taken: a name other than `Tools` for the scheduler (the ticket names `Helyx.Session.Tools`; the runner aliases it `Scheduler`); the thin `result/2` and `cancel/2` of the runner (the server calls them); a `running?/1` accessor for one read in `TurnLoop`; the shared `aborted` constant (above). The limit test "one under": the unit tests take the 17th request (16 waiting, at the limit) and refuse the 18th; fewer than 16 waiting is the order test. |
| Spec | 0 defects, 1 doc, 1 naming note | 0 | Fixed: the #369 history in `one-provider-path.md` named `tool` and `waiting` in `Turn` and a removed session test; a #395 paragraph now states the move and the removed tests. Not taken: `State.tools` (the tool specs) beside `Turn.tools` (the scheduler); no rename without the owner. |
| Failure path | 0 | 0 | Probed through the fake connected provider: 17 taken and the 18th refused, then a cancel of a waiting call makes room for the 19th; an answered id runs again; two cancels of the running call give one `aborted`; an abort with a killed running call and a waiting call answers each once. Not reached: the slow tests, the hands kill timing against a suspended Task (no hands change). |
| Codex adversarial | 0 | 0 | Verdict approve. |

No reproduced defect, so the loop ends.

## Changed tests

- Deleted from `provider_process_tools_test.exs`, now covered by `tools_test.exs`: "over one running and 16 waiting, a request gets an error at once and runs nothing" and "a request with a call id that the turn answered runs again".
- `helyx.graph_test.exs`: the caller of `Hands.run/3` is now `Helyx.Session.Server.Tools.effect/3`, not `run/2`.

## Record split (item 4)

Not split. `Record.persist/2` gives its write-failure notice through `emit/4`, so a persistence module would call the delivery module: the split adds a module and an alias at each caller, and removes no code and no dependency.
