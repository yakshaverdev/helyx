# 2026-11-07: harness approvals through the hook chain (#881)

Follow-up 3 of ADR 0013, built by the ticket worker.

Done:

- The research run of the ticket on codex 0.166.0: an `apply_patch` approval under `untrusted` and `read-only`, answered with `decline`, `accept`, an error, and no answer with `turn/interrupt` (`docs/research/codex-app-server.md`). The program ran against a local stub of the Responses API, with a fresh `CODEX_HOME`, so no request went to a real model.
- `{:approval, approval_id, call_id}` and `{:approval, turn_id, approval_id, decision}` in `Helyx.Provider`; the check of the id in `Helyx.Session.Stream.check/1`; the session's set of chains of a turn and its checks; the chain Task of the hands; the deny at every turn end before the interrupt; the Codex mapping to `accept` and `decline`; the docs and the ADR 0007 update.

Broke on the way: `hands.ex` passed 400 lines; its moduledoc was rewrapped (same words) and the call context moved to `Hands.Hooks`.

Open: the change hit the 45-minute limit after review round 1, and the findings of that round are not fixed (`docs/reviews/2026-11-07-harness-approvals-881.md`). The first is a defect: the Codex mapping does not check the thread and the turn of a request. The second is a question for the owner: Core names "harness" in `HarnessChains`, which ADR 0013 names and AGENTS.md forbids.

The ticket has no triage comment; the decisions come from ADR 0013.
