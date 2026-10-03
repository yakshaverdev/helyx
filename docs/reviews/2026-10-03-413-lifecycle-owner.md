# Review: TurnLoop matches lifecycle inputs and lists the work Stop ends (#413)

Date: 2026-10-03. Base: `8e73900`. Scope: `lib/helyx/session/server.ex`, `server/turn_loop.ex`, `server/wait.ex`, `server/stop.ex`, `server/steering.ex`, `server/state.ex`, `hands.ex`, `long-lived-harness.md`.

## Invariant

Every lifecycle input (client prompt, steer, follow-up, abort, provider turn start, terminal, `provider_ready`, provider replies, `provider_down`, every non-subscriber `:DOWN`, prepare result, context request, idle timer, the hands' cleanup answer) is matched to the current activity in `Helyx.Session.Server.TurnLoop` and gets the same state change, reply, and reply order as on master; `Stop` ends exactly the work of `TurnLoop.work/1`; the provider monitor stays separate from the hands' `provider_down`; prepare cancellation, the wait before the next turn, and the `aborted` answers before the interrupt stay. Accepted change: a subscriber `:DOWN` matches before the provider monitor clause.

## Line counts

| File | Before | After |
|----|----|----|
| `server.ex` | 367 | 212 |
| `server/turn_loop.ex` | 368 | 393 |
| `server/stop.ex` | 82 | 71 |
| `hands.ex` | 357 | 357 |
| `server/wait.ex` | 12 | 135 |

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

Simplify (4 agents): `work/1` has one clause per activity instead of a `match?/2`. Not taken: a shared armed-kill helper (no new copy); one queue-full check for admission (#415); an `agent_end` data helper in `Wait` (moved code, unchanged).

Altitude (simplify) and spec both said that the turn end, the abort, and the failure now set `activity` in `Wait`, so the lifecycle is in two modules. Judgement, not a defect: keeping them in `TurnLoop` puts it at about 455 lines. "Turn cleanup" in the feature doc is one path (the prepare kill, the `aborted` answers before the interrupt, the hands' cancel, the wait), and the wait struct holds its result. `TurnLoop` still matches every input and chooses the end. The doc reason no longer cites the line count. Open for the owner: accept this split, or rename `Wait` (for example to `Cleanup`), or allow a `.credo.exs` entry for `turn_loop.ex`.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 5 judgement calls | 0 | Fixed: `Wait.reply/3` renamed `Wait.answered/3` (it shared its name with a field and a parameter). Not taken: `Wait` name (open, above); the two prepare kills (`Stop` gets pids, the turn end a `Turn`); the `work/1` map (one shape for `Stop`); the `Steering.queue/3` reply shape (its one caller is admission; #415 reworks it). |
| Spec | 0 missing, 3 out of scope, 3 doc | 0 | Doc fixed: the "Built in #386" turn-loop bullet is marked replaced; the `Wait` comment says that `end_turn/3` and `close_turn/4` make the wait; the crash sentence names `Wait.cleanup/2`. Out of scope, accepted: the `Wait` split (open, above), the subscriber `:DOWN` order (stated in the doc), `Steering.queue/3`. |
| Failure path | 0 | 0 | Clause-by-clause order and match comparison with master; session tests and root suite pass. Not reached: slow tests, plugin tests, a session stop per provider external state (the stop mechanics did not change). |
| Codex adversarial | 0 | 0 | Verdict approve. |

No reproduced defect, so the loop ends.

## Changed tests

None changed or deleted. No test called a moved function.
