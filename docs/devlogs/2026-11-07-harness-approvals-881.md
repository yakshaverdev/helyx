# 2026-11-07: harness approvals through the hook chain (#881)

Follow-up 3 of ADR 0013, built by the ticket worker.

Done:

- The research run of the ticket on codex 0.166.0: an `apply_patch` approval under `untrusted` and `read-only`, answered with `decline`, `accept`, an error, and no answer with `turn/interrupt` (`docs/research/codex-app-server.md`). The program ran against a local stub of the Responses API, with a fresh `CODEX_HOME`, so no request went to a real model.
- `{:approval, approval_id, call_id}` and `{:approval, turn_id, approval_id, decision}` in `Helyx.Provider`; the check of the id in `Helyx.Session.Stream.check/1`; the session's set of chains of a turn and its checks; the chain Task of the hands; the deny at every turn end before the interrupt; the Codex mapping to `accept` and `decline`; the docs and the ADR 0007 update.

Broke on the way: `hands.ex` passed 400 lines; its moduledoc was rewrapped (same words) and the call context moved to `Hands.Hooks`.

Second cycle (owner decisions of 2026-11-07, after the first commit): the Codex mapping binds a request to the provider's thread, its current turn, and an open item of the type that its method names, and declines any other at once; Core stops the provider at a Helyx tool request for a call with a pending approval, so one call id never has two chains in the hands (review round 2). The Core set is `Helyx.Session.ApprovalChains`, since AGENTS.md forbids Core to name a harness; `hooks.md` maps it to ADR 0013's "set of harness chains". The deny at every turn end stays, as the ADR's "never dropped" reads. The stub model of the research run stays (the no-network rule). The round-1 tests, the replaced-mechanism rows, and the bounds rows were added, and the rewrap of the `hands.ex` moduledoc was undone; `Hands.tool_call/2` moved to `Hands.State` to keep the file under 400 lines.

Open after review round 3, the last: an approval request for a Helyx call that Core answered, and a tool request for a call whose approval request was answered, are not caught, because the session keeps no owner of a call id once its tool request or approval ended (review record, findings 21 and 22). The first breaks ADR 0013 §4. The fix is one map for each turn from call id to its owner; it is a mechanism change past the small-fix round, so it is not in this commit.

Third cycle (2026-11-08): rebased over #880, with the approval chain in `Helyx.Session.Hands.Approval` beside `Hands.Settle`. The session derives the owner of a call id where it can (tool queue, approval set, transcript) and keeps `owners` in `Helyx.Session.Turn` for the open calls whose request Core answered, which no state holds; bounded by the open calls, 2 × 1,024. Findings 21 to 24 are fixed. Round 1 found another defect on the binding (two calls with one id in one message lose their owner, finding 25), so the cycle stopped there with findings 25 to 31 open; two of them are questions for the owner (the "Not covered" case against ADR 0013 §4, and the open-call scope against "of this turn").

Fourth cycle (2026-11-08): findings 25 to 31 resolved by the orchestrator's decisions: an owner stays while an open call keeps its id, the accepted hole of a call that opens after its answered tool request is stated as the one exception to ADR 0013 §4, the texts say "open call", and the missing tests are added. Round 1 found a reused id across messages inheriting an ended call's owner (finding 33), another defect on the binding, so the cycle stopped with findings 33 to 39 open; the decided fix is the same-message scope of `drop/2`.

Findings 33 to 39 closed by the orchestrator's decisions of 2026-11-08: a reused call id taking an earlier call's owner is accepted under #369 and stated in `hooks.md`; the texts name the accepted exception, the Bounds row of `owners` names the drop rule, the approval tests wait the single test wait, and a test shows the drop at the `aborted` results of a close.

The ticket has no triage comment; the decisions come from ADR 0013 and the owner's and orchestrator's answers of 2026-11-07 and 2026-11-08.
