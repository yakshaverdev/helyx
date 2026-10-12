# Review: one slot for the provider process, and no derived turn phase (#512)

Scope: `ProviderConn.status` in place of `ready`, the deletion of `Wait.provider`, one `provider_down` path in `TurnLoop`, the deletion of the turn phase `:context`, the field types of `Turn`, `Wait`, `State`, and `ProviderConn`, and the parts of `docs/features/session-lifecycle.md` and `docs/features/one-provider-path.md` that name them.

Invariant: the session holds its provider process in one slot, `State.conn`, with `status` `:starting`, `:ready`, or `:ending`. A process that ends (an answer that stops it, a stop by the session, a switch close, or its `:DOWN` outside a sent turn) stays in `conn` as `:ending` and holds any wait until its `provider_down`. `provider_down` is the only path that clears `conn` and the only caller of `Steering.provider_down`. `connect/1` never reuses an `:ending` conn. Entry points: `TurnLoop.handle/2` for `provider_ready`, `provider_reply`, `provider_down`, `:DOWN`, `idle_close`, `need_context`, and `prepared`; `TurnLoop.admit/3`, `abort/2`, `settle/1`, `stop_provider/2`, and `work/1`. Accepted as before: a sent turn keeps its conn `:ready` after its `:DOWN`, and its `provider_down` fails it. Accepted change: after `stop_provider/2`, the settled ledger entries of that process stay until its `provider_down`, as after any other stop. Open hole with a ticket: #518. The queue rules do not change (#513).

## Simplify

Four agents (reuse, simplification, efficiency, altitude).

- Fixed: the `{:prepared, ...}` guard copied the old phase as a compound condition. It now matches a running prepare Task (`prepare: pid` with `pid != nil`); `prepared/2` picks the path by phase.
- Fixed: `State.provider_pid/1` had one caller left. `work/1` matches `conn` in its own clauses, and the helper is deleted.
- Fixed: the comment on `connect/1` said the guard again in six lines. Cut to two.
- Skipped: a helper for `put_in(state.conn.status, :ending)`. Four one-line sites do not pay for it.
- Skipped: `work/1` returns lists and `Stop.run/1` loops over them, now with at most one pid. `Stop` is outside the ticket, and its loop is correct for one pid.
- Skipped: the `refute` of the provider pid in the `Wait` struct. It is the ticket's test "the provider process is in one slot only", and it fails if a field holds the pid again.

## Replaced mechanism

The change merges two state slots and deletes one derived phase. Built from the code and the tests at `0f3442f`.

1. Parts of the old mechanism and their replacements.

| Old part | Replacement |
| --- | --- |
| `Wait.provider`, set with the reply of an interrupt (`Wait.interrupt/2`) and of an idle close | Deleted. The reply goes to `conn.pid`; an answer that stops the process sets `conn.status` to `:ending` (`Wait.answered/3`) |
| `Wait.answered/3` cleared `Wait.provider` at an answer that keeps the process | The status stays as it is. A `:DOWN` before the answer already set `:ending`, and an answer does not undo it |
| `monitor_down/2` outside a turn: `conn: nil`, the pid moved to `Wait.provider`, an idle session got a `%Wait{}` | `conn.status` is `:ending`; an idle session still gets a `%Wait{}` |
| `monitor_down/2` in `preparing`: `ready: false` | `conn.status` is `:ending` |
| `close_switched/1`: `conn: nil`, `Wait.provider: pid` | `conn.status` is `:ending`, `%Wait{}` |
| `stop_provider/2`: `conn: nil`, then `Wait.provider: pid` | `conn.status` is `:ending` before `Wait.finish/2` |
| Two `provider_down` clauses (the wait's pid, the conn's pid) | One clause on `conn.pid`; any other `provider_down` crashes, as before |
| `Wait.provider_down/2`: cleared `conn` when it matched, and `Wait.provider` and `reply` when the wait was for the pid | `provider_down/3` clears `conn`; in a wait it clears `reply`. A wait's reply always goes to `conn.pid`, so the two rules are the same |
| `Steering.provider_down/1` from four places, one of them the branch in `Steering.end_turn/3` when `conn` is nil | Only from `provider_down/3`. In a failed turn it runs after `Wait.finish/2`, so the notices of `Queue.end_turn/3` come first, as before |
| `progress/1` ended the wait with `provider: nil` | It ends the wait when `conn` is not `:ending` |
| `State.provider_pid/1` and its imports in `Steering`, `Wait`, and `TurnLoop` | Deleted. `work/1` matches `conn` in its own clauses (see Simplify) |
| `work/1`: `Enum.uniq` of the conn pid and `Wait.provider` | The conn pid, of any status |
| `ProviderConn.ready`, read by `start_provider_turn`, `submit/1`, the idle close, `arm_idle/1` | `status: :ready` |
| `{:provider_ready, pid}` matched any conn of that pid | It matches only `:starting`. A process that the session stopped stays `:ending` |
| `ToolRuns.end_turn/2` sent `aborted` to any conn (a stopped process had left `conn`) | Only to a `:ready` conn |
| `connect/1` reused any conn of the turn's model (an ended process had left `conn`) | A guard: never an `:ending` conn. No caller can pass one, so a bug crashes |
| The phase `:context`, set at `{:need_context, ...}`, cleared at `{:prepared, ...}` | `submitted` with `Turn.prepare` set. `{:prepared, ...}` matches a running prepare Task; a second `{:need_context, ...}` needs `prepare: nil`, or it is a bad action, as before; the steer and the interrupt match `submitted` |

2. Removed replies: none. The interrupt and idle close replies, and the order of `provider_down` against `:DOWN`, are as before. The session process sees every message that the order depends on.

3. Tests of the old mechanism. Every provider-end test in `provider_process_test.exs`, `provider_process_tools_test.exs`, `loop_test.exs`, and the plugin tests runs unchanged. Changed: four tests in `stream_events_test.exs` asserted `conn: nil` right after the `turn_end` of a stopped process; the process now stays `:ending` until its `provider_down`, so they accept `nil` or `:ending`. New: the interrupt test asserts that the pid is only in `conn`, and the idle-end test asserts `:ending` and a wait while the hands hold the release.

4. Properties that clients see and that change:
- An abort in `preparing`, after the `:DOWN` of a process that an earlier turn started, replies after that process's `provider_down`. Before, the wait could end at the hands' answer, and the next turn waited for the `provider_down` in `preparing`. The wait is bounded by the hands' release deadline.
- After `stop_provider/2`, the settled ledger entries of that process count in the 32 steers until its `provider_down`, as after any other stop. Before, they left at once.

5. States with no bound: none new. An `:ending` process ends at its armed kill, its close bound, or its exit, and the hands send `provider_down` within their release deadline.

## Round 1

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 8 candidate functions, 0 flagged, 0 without an answer
```

Standards (3 doc findings, judgement calls):

- Fixed: no "Replaced mechanism" inventory (`docs/agents/review-checklist.md`, "Specs and bounds"). The section above holds it. The change has no feature doc of its own, and `session-lifecycle.md` states the contract, not its history.
- Fixed: the comment on `ProviderConn` and `session-lifecycle.md` did not name the switch close as a writer of `:ending`. Both name the four writers now, and the doc names the functions that hold the wait and refuse the reuse (`TurnLoop.progress/1`, `TurnLoop.connect/1`).
- Fixed: the comment of `ToolRuns.end_turn/2` said "not `:ending`"; the match is `:ready`.
- Fixed: `other` in the `provider_down/3` guard is `started_by`.
- Fixed: the sentence on a context request in "Turn states" is split, and says where a steer goes.
- Rejected: a helper for the four `:ending` writes (see Simplify).
- Rejected: `stopped?/1` is weaker than `conn: nil`. The `provider_down` of a stopped process can come before or after the test reads the state.

Spec (2 findings):

- Fixed: the ticket asks for field types "so Dialyzer checks that `activity` is `:idle | Turn.t() | Wait.t()`", and no spec used `State.t()`. `TurnLoop.handle/2`, `TurnLoop.work/1`, `Wait.finish/2`, `Wait.answered/3`, and `Wait.abort/2` have specs now. Limit, probed: Dialyzer checks success types, so one clause of `handle/2` that sets `activity: :bogus` passes; it reports only a function whose every path breaks the type. A full check needs a tagged union, which the ticket declines.
- Fixed: `one-provider-path.md` named `Turn.phase` for an open context request. It names `Turn.prepare` now.
- Recorded: the ledger after `stop_provider/2` and the abort reply after a `:DOWN` in `preparing` (see "Replaced mechanism", item 4). The ticket deletes the branch in `Steering.end_turn/3` that cleared the ledger at once.
- Noted: the ticket test "a turn that starts while the provider process is `:ending`" is the prompt in the wait after an idle `:DOWN`; no turn starts while a process is `:ending`. The `preparing` case is the existing test of an earlier turn's process.

Failure path (2 findings, reproduced):

- Fixed (doc): the `ProviderConn` comment and the lifecycle doc said that every answer that stops the process makes it `:ending`. A `{:turn, ...}` error answer leaves it `:ready` in a sent turn, as before: its `provider_down` fails the turn. Both texts name the interrupt and idle close answers now, and the comment states the sent turn.
- Accepted: with 32 sent steers, a bad provider output, and the hands' release held, a steer gets `{:error, :queue_full}` until the `provider_down`. Recorded in "Replaced mechanism", item 4. It is bounded by the release deadline.
- Checked and clean: `provider_down` is the only exit from `conn`; a late `provider_ready` of an `:ending` process; an interrupt `:ok` after a `:DOWN`; `{:prepared, ...}` keyed on the prepare pid; `work/1`; `Wait.answered/3` never sees a nil `conn`.
- Not reached: the session stop with a dead `:ending` process, and `close_switched/1` with a `:starting` process (read only).

Codex: approve, no findings.

Round 1 result: no defect in the code. The spec finding added function specs, which changes the spec of five functions, so round 2 is a full round. The branch is rebased on `c208bfe` (#511).

## Round 2 (full)

Fix of round 1, without tests and Markdown: specs on five functions, one renamed guard variable, and comments in `state.ex`, `tool_runs.ex`, `turn_loop.ex`. It changes the spec of five functions, so the round is full.

Simplify (one agent, four angles, on the fix only):

- Fixed: the stop reason in the spec of `Wait.finish/2` is `Helyx.Message.stop_reason()`.
- Fixed: the `ProviderConn` comment repeated the list of the events that make a process `:ending`, and its sentence on a sent turn read as a general rule. It names the statuses and links "Provider death", which lists the events and the sent-turn case.
- Fixed: `one-provider-path.md` uses one wording for an open context request in both places.
- Skipped: specs on the other public functions of `TurnLoop` and `Wait`. Under success typing they add little (see round 1), and `turn_loop.ex` is at 397 of its 400 lines.

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

Standards (wording and judgement calls only):

- Fixed: the `Wait` moduledoc said that both parts are answers of the provider process. Only `reply` is; `hands` is the answer of the hands.
- Fixed: the comment of `Wait.answered/3` on an earlier `:DOWN`, the comment of `ToolRuns.end_turn/2` (no request goes to an `:ending` process, and a `:starting` one has none), and the comment of the `provider_ready` clause.
- Fixed: `one-provider-path.md` (two places) and the bad output bullet of `session-lifecycle.md` name `TurnLoop.handle/2`, which holds the context request clauses.
- Rejected: possible Feature Envy, `Wait.answered/3` writes `conn.status`. The lifecycle doc names it as one of the four writers of `:ending`, and the answer arrives in the wait.

Spec (no defect):

- Fixed: the inventory had no row for `State.provider_pid/1`. It has one now.
- Noted again: the ticket test "a turn that starts while the provider process is `:ending`" has no assert of `:ending` in the `preparing` test. The session reads its `:DOWN` at a time the test does not control, so a state read after the test's own `:DOWN` races. The idle-end test asserts `:ending` while the hands hold the release.
- Recorded already: the two client-visible changes (item 4). Both are bounded by the hands' release deadline.
- Checked: `Steering.provider_down` after `fail_turn` gives the same event order, since `Queue.end_turn/3` settles every ended entry first. The snapshot shows neither `phase` nor `conn`, so the render path does not change. #518 is not harder to fix: the process stays in `conn` during the wait.

Failure path (no defect; three probes through the session, all pass):

- The switch close of a `:starting` process: the abort replies `:ok`, the conn is `:ending`, a late `provider_ready` is dropped, and the next prompt starts a new process.
- The session stop with a dead `:ending` process ends cleanly; `work/1` closes the dead pid.
- An abort in a wait that only an `:ending` process holds replies after its `provider_down`; then `conn` is nil and the session is idle.
- Noted, not new: `ToolRuns.late/4` still sends to a process that ends, as before.
- Not reached: a `:DOWN` of the turn's own `:starting` process in `preparing`, then `{:prepared, ...}` before its `provider_down` (read only); a provider process that traps exits and never ends after `stop_provider/2` (a hole from before the change).

Codex: approve, no material findings.

Round 2 result: no reproduced defect. The loop ends. The fixes of this round are comments and docs only.

## Gate

Rebased on `50d13ba` (#508, #517). They change no file of the session server. `HELYX_SLOW=1 .claude/skills/ship/precommit.sh` passed: 603 tests and 2 properties in the root (1 excluded), 432 and 26 in the other projects, 0 failures, Dialyzer 0 errors, no warnings.
