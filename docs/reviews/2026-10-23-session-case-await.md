# Review: SessionCase.await/2 delegates to Events.wait_until/3 (#844)

Base: `4036916e` (merge base with origin/master). Change: `test/support/session_case.ex` only.

Invariant: `await/2` polls its condition every 10 ms and flunks with "timed out waiting for <what>" once `Events.wait_ms()` passes on a monotonic deadline, as `Events.wait_until/3` does.

## Bounds sensor

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

| Axis | Findings | Reproduced defects |
|---|---|---|
| Standards | 0 hard; judgement calls: Middle Man (kept: one cap and one message format for 28 callers), `wait_ms()` passed only to reach the text argument (kept: the ticket's form) | 0 |
| Spec | 1 minor scope note: the new alias also shortens `final_message/1`, and the comment is reflowed (-13/+7 instead of about -8/+3) | 0 |
| Failure path | 0 | 0 |
| Codex adversarial | approve, no material findings | 0 |

Scope note resolution: kept. The alias serves the new `await/2`; leaving one full `Helyx.Test.Events` name beside the alias would be inconsistent. Same file, no behaviour change.

Spec guarantee table for the changed comment (probes by the spec agent, `.scratch/review-spec-1/`, deleted):

| Guarantee | Proof |
|---|---|
| Polls every 10 ms | probe: 11 ms between calls (`events.ex` `poll/3` sleeps 10 ms) |
| For the cap of a wait | probe: a 20 ms predicate flunked at 30027 ms with a 30000 ms cap |
| Flunk text "timed out waiting for <what>" | probe: "timed out waiting for the thing" |
| Only for a state that no process tells by a message | caller guidance, not a guarantee; the callers read Registry, mailbox lengths, memory, `:sys.get_state` |

Ticket claims checked: 28 callers of `await` (26 in `test/helyx/**`, 2 in `session_case.ex`), all with two arguments; `reason_crash_test.exs` imports `await: 2`; no caller uses the return value (now `:ok`, was `nil`).

No round reproduced a defect; the loop ends after round 1.
