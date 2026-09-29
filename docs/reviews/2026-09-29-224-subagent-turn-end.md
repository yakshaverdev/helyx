# Review: sub-agents at the end of a turn (#224)

Date: 2026-09-29. Scope: `Helyx.Provider.Codex` (child threads, open tool items at a turn's end, lines with no `threadId`), a test of `Helyx.Provider.ClaudeCode` for a background sub-agent, and `docs/features/long-lived-harness.md` ("Built in #224").

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

## Round 1 (full)

Simplify:

- Reuse: the test helper `agent/2` now uses `started/2` and `completed/2`; the wait loop is a general `settle/2`, as in the Claude Code test. Fixed.
- Simplification: `agent?/1` lost a `nil` check that `line?/2` already proves; the `subAgentActivity` clause matches `agentThreadId` in its patterns. Fixed. Skipped: a split of `end_turn/2` into clauses, and the use of `turn_on/2` in older tests (outside the diff).
- Efficiency: no finding. The interrupted child with no `completed` item is an accepted hole.
- Altitude: the check for a missing string `threadId` covered only `turn/completed`. The schema of codex 0.157.1 requires `threadId` on all four turn and item lines, so the check now covers the four. Fixed.

Standards: 3 low findings. An assert that no event is held at a turn's end (added), the place of the test helpers (moved), and one sentence of the doc (rewritten). Fixed.

Spec: 2 doc defects, fixed: no Bounds row for the `agents` map (added, with the accepted hole), and the "shape of a line" row did not name the new checks (updated). Wording: the test name "interrupts it" (now "interrupts the turn"), the claim that an abort ends background work (now marked as inferred from one run), and the claim that a sub-agent is in the `tasks` list (now cited to the schema text and marked as inferred). One test gap, not fixed: no test for the Claude abort of a foreground sub-agent; the provider code for it did not change.

Failure path: no reproduced finding. Probes: a `wait` in a later turn on a background child (stops with `:tool_running`), and `interacted` in a later turn (the interrupt answers `:agent_running`).

Codex (adversarial review): 1 defect, reproduced and fixed. An `item/completed` with the id of an open command and another type (`webSearch`) cleared the command, and the turn then ended with `:done`. Before the change the turn stopped with `:command_running`. Fix: `again?/3` rejects an `item/completed` of the running turn whose id is open with another type, with `{:malformed, "item/completed"}`. Test: "a completion of an open tool item with another type stops the harness process".

## Round 2 (reduced)

The fix: 11 lines in one code file (`codex.ex`), a clause and no new function. Invariant given to the agents: open work is cleared only by a line that confirms its end.

Spec: no code defect. One gap in the doc, which is now an accepted hole: a sub-agent of a sub-agent. Its lines are on the child thread, which the provider drops, so the child leaves `agents` while its own child can still run. The research did not run this case, so it is reported, not closed. Wording: the #201 section and the moduledoc now say "its type" for the end of a tool item.

Failure path: no reproduced finding. Probes: a completion of an open item as `subAgentActivity`, as `agentMessage`, and with the status `inProgress` (each stops with `{:malformed, "item/completed"}`), two open items with one completed (stops with `:tool_running`), and a completion with another turn's id (stops with `:item_of_ended_turn`).

Round 2 reproduced no defect, so the loop ended.

## Owner decisions

The owner accepted each item below on 2026-09-29. The first three are documented holes with no follow-up tickets; the session end bounds each one. The last item is the rule "sync work ends inside its turn".

- A child thread whose `completed` item never comes keeps the idle close at `:busy` until the session ends.
- `interacted` while an earlier child turn runs: the earlier `completed` removes the child while its new work can run.
- A sub-agent of a sub-agent (above).
- Claude Code: an interrupt while idle ended a background sub-agent in the research; so an abort can end background work of an earlier turn.
- A turn that ends with an open tool item of any type now stops the harness process. A failed turn with an open non-command item therefore fails with `{:harness_stop, :tool_running}`, not with the program's error text.

## Precommit and round 3 (full)

The first precommit run failed on Credo strict: `end_turn/2` had a cyclomatic complexity of 10 (max 9). The choice of the stop reason moved into the new private function `outlives/1`. The change adds a function, so round 3 was a full round, on this change only.

- Simplify and standards: no finding; the extraction keeps every branch and its order. Wording: one moduledoc sentence had no verb (fixed). Skipped: the name `outlives/1`; its comment says that it gives a reason or nil.
- Spec and failure path: no reproduced defect. Wording: the `end_turn` comment lines (fixed).

Round 3 reproduced no defect.

## Round 4 (reduced, after the rebase on #202)

Master got #202 (steer delivery). The rebase conflicts in `codex.ex` (`@turn_fields`, the steer and idle close clauses) and in the feature doc were mechanical; both behaviours stay. A new test covers a steer whose answer is open at a turn end that stops for `:tool_running`: the steer gets no reply, and the session gives it the `:steer_unconfirmed` notice.

The brief named both invariants: no sync work of a turn runs past its end, and a steer reaches the harness at most once and never after its turn ends.

- Spec: no defect. Notes: the doc did not name an interrupt that waits for an earlier interrupt answer and goes out with no new check (the turn end stops the harness process); the doc did not name a steer with `:ok` whose held `userMessage` item is lost at the stop (the session gives the notice, and the steer is not sent again). Both are now in the doc. An abort that crosses a normal turn end keeps the child as background work, as the owner rule says.
- Failure path: no defect. Two probes in the scratchpad: a held steer `userMessage` at a `:tool_running` stop (one stop, no reply, one notice, no resend), and a steer answer after a normal turn end with an open child (`:ok`, then the idle close answers `:busy`). Notes, reported and not chased because each needs a new program behaviour: a child's `completed` item before the `item/completed` of its spawn item keeps the child in `agents` (fail safe, `:busy` until the session end); a `subAgentActivity` item with an unknown or older turn id is taken as valid and can move a child to that turn.

Round 4 reproduced no defect.

## Orchestrator decisions on the round-4 notes

1. A child `completed` item before the `item/completed` of the item that started it: accepted hole. It fails safe (the idle close answers `:busy`), and the session end bounds it.
2. A `subAgentActivity` item with an unknown or older turn id: follow-up ticket #244.

## Codex gate

Round 1: approve, no findings.
