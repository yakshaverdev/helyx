# Review: #726, a start answer after the turn end stopped the provider process

Scope: the working tree on branch `ticket/726-prepare-flake`, base `origin/master` (`94618cf4`). Feature doc: `docs/features/session-lifecycle.md`, "Provider death" and "Ownership".

## Cause

The ticket asked first: a Core race or a test race. It is a Core race (cause 1).

A throwaway copy of `provider_process_test.exs:545` under `.scratch/` waited 1 s for the init, not 30 s, and traced the messages that the session received (`:erlang.trace/3` with `:receive`). With the hands suspended from the prompt to the `turn_end` of the raising prepare, the session got `[:prepare_raised, :provider_start, {:provider_down, :aborted}]`, and no init came. The clause `TurnLoop.handle({:provider_start, ref, {:ok, pid}}, ...)` for a wait stopped the process with `{:shutdown, :aborted}` before `init/3` (#677). The next turn then connected a new process, so the test waited for an init that came only after its own next prompt. The 300 runs in the natural order passed: in them the hands answered before the prepare Task raised. The test in the forced order failed on master with the error of the ticket: `Assertion failed, no matching message after 30000ms` at the `assert_receive` of the init.

## Change

The two clauses become one: at `{:ok, pid}` the session monitors the process and sends it `:start`, in a turn and in the wait after it. So the order of the start answer and the turn end does not decide whether the process runs. An answer in the wait leaves a `:starting` process in `conn`, the state that an answer before the turn end already reached: `connect/1` reuses it, `progress/1` does not wait for it, and `arm_idle/1` arms the idle close at its `provider_ready` or at the end of the wait.

Decision on a point that the ticket did not decide: the removed clause also stopped the process after an abort in `preparing`. That process now runs too, as it did when its answer came before the abort. Reason: one rule for both orders, and a smaller Core (one clause less). To keep the stop only for an abort, `Wait` would need the outcome of the turn. The test of #677 in `hands_busy_test.exs` now asserts the init, the reuse state `:ready`, and the armed idle close; the defect that #677 fixed (a ready process with no idle close) stays covered.

The summary call keeps its stop at a late answer (`Summary.started/2`): its process serves only its call.

## Simplify

Four agents (reuse, simplification, efficiency, altitude). Reuse, efficiency, altitude: clean. The altitude agent judged the summary call a different rule, not the same root cause. Fixed (simplification): the doc bullet said the same fact three times; the test comment told the history of the old behaviour.

## Round 1 (full)

Bounds sensor, base `origin/master`: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`

Codex adversarial review, base `origin/master`: `Verdict: approve`, "No material defect found in the local changes against origin/master." "No material findings."

| Source | Finding | Resolution |
|---|---|---|
| Standards | Judgement: the comment "The follow-up runs on the process of the aborted turn" (`hands_busy_test.exs:52`) claims more than the test asserts. | Fixed: the comment says "The follow-up runs." |
| Standards | Judgement: no test stops a process that the session kept from the wait. | Kept: the monitor is the one clause that the turn path also runs, and the monitor tests of #361 run it. The reviewer's probe (kill the kept process, then `conn: nil`) passed. |
| Standards | The checklist rule "Replaced mechanism". | Kept: the change removes a mechanism and replaces it with nothing; its one test was rewritten in place. |
| Standards | Judgement: one doc sentence of about 37 words. | Fixed: split. |
| Standards | Judgement: Duplicated Code, three tests of `hands_busy_test.exs` repeat suspend, prompt, abort, resume. | Kept: older than this change. |
| Spec | The cause is recorded only in `.scratch/`. | Fixed: this record and the commit message. |
| Spec | The "Released on abort" column of the Ownership row "provider process" did not cover an abort in `preparing`. | Fixed: the row says that such an abort sends no interrupt and keeps the process, also when the start answer comes after it. |
| Spec | The abort decision reverses a test of #677: scope creep? | Kept in this change, recorded above as a decision. The spec reviewer agreed: a split needs more state in `Wait`. |
| Failure path | Not exact: "the next turn takes it" (`session-lifecycle.md:87`); a model switch in the wait closes the process first. | Fixed: "The next turn of its model takes it; after a model switch it closes (`close_switched/1`)." |
| Failure path | None reproduced. Probes passed: a model switch in the wait on a `:starting` process; a kept process whose `init/3` fails; a follow-up queued before ready reuses the pid with no second init; a session stop in the wait. `hands_busy_test.exs` and `provider_process_test.exs:546` passed 10 times. Not reached: real harness providers with a kept `:starting` process. | n/a |

Guarantee table of the changed contract text (from the standards and spec reviewers):

| Guarantee | Proof |
|---|---|
| At `{:ok, pid}` in the turn, the session monitors the process and sends `:start` | `hands_busy_test.exs:24` |
| At `{:ok, pid}` in the wait, the session sends `:start`, and `init/3` runs | `hands_busy_test.exs:61` |
| At `{:ok, pid}` in the wait, the session monitors the process | reviewer probe (kill the kept process, `conn: nil`); the same clause as the turn path |
| A turn that ends before the answer keeps the process: a failure | `provider_process_test.exs:546` |
| The same for an abort | `hands_busy_test.exs:61` |
| The process is `:starting` until its `provider_ready`; the idle close is armed then | `hands_busy_test.exs:31`, `:61` |
| The next turn of its model takes it, with no second init | `provider_process_test.exs:553-555` |
| After a model switch it closes | reviewer probe (abort in `preparing`, `set_model` in the wait, resume: idle with `conn: nil`) |
| `{:error, text}` fails a turn, and in a wait only clears `conn` | `hands_busy_test.exs:87`, `:100` |
| A summary call that ended before the answer stops its process | `summary_test.exs:178` |
| Four events make the process `:ending` | reviewer probe: four writers of `:ending` on `conn` (`wait.ex`, `turn_loop.ex` three times) |

Round 1 reproduced no defect, so the loop ends.

## Accepted holes

- An abort in `preparing` can leave a harness program running until its idle close or the next turn. It could before this change too, when the start answer came before the abort.
- The failure-path reviewer named an older, unreproduced case: a turn that ends `done` in `preparing` with a start that has no answer yet would leave an idle session with `conn.pid` nil, and a model switch then would call `close_switched/1` with no pid. No path to a `done` in `preparing` with a pending start was found: the compaction "unsupported" path ends after the `{:compact, ...}` answer, so the process is ready.
