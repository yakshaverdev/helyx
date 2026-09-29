# Review: a late subAgentActivity item and the turn of a child (#244)

Date: 2026-09-29. Scope: `Helyx.Provider.Codex` (`turn_notification/3`, the `agents` map), two tests in `codex_test.exs`, and `docs/features/long-lived-harness.md` ("Built in #224").

Invariant: a `subAgentActivity` item adds an unknown child with the item's turn id and moves a known child only to the running turn. So a late item with an older or unknown turn id never takes a child away from its turn, and an abort of that turn still answers `:agent_running`. The kind `completed` removes the child with any turn id, as before.

Decision: the ticket offered two rules ("reject an item whose turn id is not the running turn or a known turn, or keep the first turn id of each child"). The fix is the second rule, with one exception that #224 already accepted: an item with the running turn's id, such as `interacted` in a later turn, moves the child to the running turn (#224 round-1 probe). Only one turn runs at a time, so a child moves only off a turn that has ended.

Accepted hole: an unknown child whose first item has a turn id that is not the running one is kept as background work of that turn. An abort of the running turn then does not stop the program for it. This needs a lost `started` item, which the research did not see.

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

## Round 1 (full)

Simplify: 2 findings on one line, fixed. The `Map.update/4` with an inline `if` closure is now two `case` clauses (`Map.put/3` when the turn is the running one, `Map.put_new/3` otherwise). Skipped: the cost of the closure (efficiency), which the fix removed anyway. Reuse: no finding.

Standards: no hard violation. Fixed: the second new test now carries `(#244)`, and the moduledoc line wrap. Skipped: a helper for the `text_delta` wait predicate (it was repeated before this diff), and one statement of the rule instead of three (moduledoc, state comment, clause comment each serve a different reader).

Spec: no defect. Fixed: the feature doc now says that a late item with an older turn id was not observed in the research. Fixed: the second test now also sends a late `interrupted` item with the ended turn's id after the move, so a known ended turn id is covered, not only an unknown one. Noted: the rule is a mix of the two rules the ticket offers; recorded above as a decision.

Failure path: no reproduced finding. Checked by reading: a nil `state.turn` between turns (the item falls to `Map.put_new/3`), the order of `turn/started` and items, and `completed` with any turn id. Not reached: a run of a real codex binary.

Codex (adversarial review): approve, no findings (144 direct notification checks).

Round 1 reproduced no defect, so the loop ended.

## Precommit

The first run failed on one root test, `Helyx.Session.HandsTest` "cancel releases with :cancel and reports an unconfirmed handle" (`assert_received` found an empty mailbox). The diff does not touch the root project, and the test passed 5 of 5 runs alone, so it is a flaky test under load. The second run passed.
