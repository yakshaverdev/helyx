# 2026-11-07: harness approvals through the hook chain (#881)

Follow-up 3 of ADR 0013, built by the ticket worker.

Done:

- The research run of the ticket on codex 0.166.0: an `apply_patch` approval under `untrusted` and `read-only`, answered with `decline`, `accept`, an error, and no answer with `turn/interrupt` (`docs/research/codex-app-server.md`). The program ran against a local stub of the Responses API, with a fresh `CODEX_HOME`, so no request went to a real model.
- `{:approval, approval_id, call_id}` and `{:approval, turn_id, approval_id, decision}` in `Helyx.Provider`; the check of the id in `Helyx.Session.Stream.check/1`; the session's set of chains of a turn and its checks; the chain Task of the hands; the deny at every turn end before the interrupt; the Codex mapping to `accept` and `decline`; the docs and the ADR 0007 update.

Broke on the way: `hands.ex` passed 400 lines; its moduledoc was rewrapped (same words) and the call context moved to `Hands.Hooks`.

Second cycle (owner decisions of 2026-11-07, after the first commit): the Codex mapping binds a request to the provider's thread, its current turn, and an open item of the type that its method names, and declines any other at once; Core stops the provider at a Helyx tool request for a call with a pending approval, so one call id never has two chains in the hands (review round 2). The Core set is `Helyx.Session.ApprovalChains`, since AGENTS.md forbids Core to name a harness; `hooks.md` maps it to ADR 0013's "set of harness chains". The deny at every turn end stays, as the ADR's "never dropped" reads. The stub model of the research run stays (the no-network rule). The round-1 tests, the replaced-mechanism rows, and the bounds rows were added, and the rewrap of the `hands.ex` moduledoc was undone; `Hands.tool_call/2` moved to `Hands.State` to keep the file under 400 lines.

Open after review round 3, the last: an approval request for a Helyx call that Core answered, and a tool request for a call whose approval request was answered, are not caught, because the session keeps no owner of a call id once its tool request or approval ended (review record, findings 21 and 22). The first breaks ADR 0013 §4. The fix is one map for each turn from call id to its owner; it is a mechanism change past the small-fix round, so it is not in this commit.

The ticket has no triage comment; the decisions come from ADR 0013 and the owner's answers of 2026-11-07.
