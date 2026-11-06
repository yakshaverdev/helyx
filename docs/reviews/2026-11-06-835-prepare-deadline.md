# Review: #835, the deadline of the prepare Task for the ModelContext and Compaction plugins

Base: `6a5612b4` (merge base with master). One round.

Invariant: the prepare Task of `Helyx.Session.Server.Prepare.start/2`, at a turn start and at a context request, passes one `:deadline`, the monotonic ms read before it arms its kill plus `deadline_ms.prepare`, to both `build/2` and `compact/2`, so the timer kill never comes before that deadline; the `Helyx.Memory` recall gets the deadline less the current time, as before.

Accepted holes: the `Helyx.Memory` plugin opts get no `:deadline` (the ticket does not ask for it; the recall has its own limit). A plugin that returns just before `:deadline` is not killed by the timer, but the recall and the reply need time of their own, which the moduledoc states.

## Bounds sensor

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

Simplify: rewrapped comments and the moduledoc; cut the budget text from the `Helyx.Compaction` moduledoc (restored by the author: the ticket asks both moduledocs to state the budget); the second deadline of the first test is checked against the clock, not against the first deadline (two Tasks can start in one millisecond).

| Reviewer | Findings | Reproduced defects |
| --- | --- | --- |
| Codex adversarial | none (approve) | 0 |
| Failure path | none; probes: the last clock read of a build before its kill was 0 to 1 ms at or after `:deadline` in 8 runs, the turn failed with `:context_timeout`; a build that returns 1 ms before the deadline gives a turn that ends `:done` | 0 |
| Spec | 3 partial: the upper bound of the test uses the read in the build, not the Task start; nothing pins 10,000 ms; the context request path is not tested | 0 |
| Standards | 5 judgement calls | 0 |

Resolution:

- 10,000 ms not pinned: fixed, the first test asserts `State.prepare_ms() == 10_000`, the value that both moduledocs name.
- Upper bound from the read in the build: kept. The Task start is not visible to a plugin; the bound `before + budget <= deadline <= read + budget` brackets it.
- Context request path: not tested. `Stream.prepare/4` is the only caller of both callbacks, and the prepare Task the only caller of it (spec reviewer, by reading); the turn start and the context request run the same function.
- Literal "10,000 ms" in two moduledocs (standards): kept, the ticket asks the moduledocs to state the budget; the test pins it.
- Repeated budget text in `Helyx.Compaction` (standards): kept short, the ticket asks for it in both.
- Recall budget has no test of its own (standards): the computation `deadline - now` equals the former `ms - elapsed` up to the 1 ms of the clock read; the spec reviewer probed it (recall that hangs with a small left budget gives the notice, the turn ends `:done`).
- Sleep instruction in the prompt text of the test plugin (standards): kept, the shared test plugins take their cases from the last message too.
- Attributes in the middle of the test module (standards): moved to the top.
- A stale comment in the test plugin named a wrong registered name: fixed.

The round reproduced no defect, so the loop ended.

## Precommit

The first run failed on `Helyx.Credo.WallClockUpperBound` at two lower bounds of the test: `deadline >= before + budget`. Each is the order of two instants, the clock read before the prompt and the start of the prepare Task (the deadline less the budget), which load cannot break. The explanation of the check names this case for an inline disable, so each line has one. The rest of the run passed: 811, 1155, and 141 tests with no failure, Dialyzer clean in the three projects.
