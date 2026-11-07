# Review of #881: harness approvals through the hook chain

Change: the stream event `{:approval, approval_id, call_id}` and the request `{:approval, turn_id, approval_id, decision}` of `Helyx.Provider`; the check of `approval_id` in `Helyx.Session.Stream.check/1` (`Helyx.Message.approval_id?/1`); the set of chains of a turn (`Helyx.Session.HarnessChains`) and its session module (`Helyx.Session.Server.Approvals`); the chain Task of the hands (`Hands.approve/5`, `Hooks.approve/5`, `Chain.approve/5`); the deny at every turn end before the interrupt; the Codex mapping (`Helyx.Provider.Codex.Approvals`); the research run on codex 0.166.0; `docs/features/hooks.md`, `docs/features/long-lived-harness.md`, and the ADR 0007 update.

The ticket worker hit the 45-minute limit of `/ship` after round 1. The commit holds the code as round 1 reviewed it. The findings below are open: none was fixed after the review, and no round 2 ran.

## Round 1 (full)

Bounds sensor (base `d3840c0c`):

```text
bounds sensor: 8 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/codex.ex:224  SIZE  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call"
```

The flag names the existing `item/tool/call` clause. The failure-path agent checked it: an approval id over 256 bytes fails the turn through the generic path. Not a finding.

| # | Source | Finding | Reproduced | State |
|---|---|---|---|---|
| 1 | Codex (high) | `Codex.Approvals.dispatch/2` drops `threadId` and `turnId`. A request of a child thread, or of an earlier program turn, whose `itemId` equals an open call of the current turn runs the `before_tool` chain of that call: the hooks check that call's arguments, and their allow goes to the child's operation. | yes, Codex probe in memory (a constructed program line); no real program was run | **Open.** Proposed fix: map only a request whose `threadId` is the provider's thread and whose `turnId` is its current program turn; answer any other approval request with `decline` at once, with no chain. Then a test with one `itemId` in two threads and in two turns. |
| 2 | standards (hard) | AGENTS.md: "Core code does not name" a harness or a program. `Helyx.Session.HarnessChains`, the `harness_chains` field of `Helyx.Session.Turn`, and Core comments ("the program waits for it", "the program, not the hands, gives the result") name them. ADR 0013 §3 itself uses "the set of harness chains" for the turn's set. | n/a (rule) | **Open, question for the owner:** which term wins, the term of ADR 0013 or the AGENTS.md rule? Proposed fix: `ApprovalChains` and `approval_chains`, and "the provider" in Core comments. |
| 3 | standards, spec | No "Replaced mechanism" rows in `docs/features/hooks.md` for: the -32601 answer to every server request (now only to the requests that are not mapped); the wider guard of `Asks.ask/5`; `Hooks.start/4`, which no longer goes through `Hands.tool_call/2`; the renamed Codex test "a server request that is no approval of an item gets an error". | n/a (doc) | Open |
| 4 | spec | Bounds rows missing from `docs/features/hooks.md`: a waiting chain's wait (ADR 0013 Bounds: the limits and release deadlines of the hooks of the chains ahead of it), and the `approvals` map of the Codex state. | n/a (doc) | Open |
| 5 | spec, standards | Guarantees with no test, only a reviewer probe: the hands kill a running chain at a `done` (spec probe P1); a deny reason is cut by `cut_result/1` (P2); a crash of the chain Task is a deny (P3); a call of a closed message of the turn with no result runs the chain (P4); a call open in the tool queue is denied (P5); the deny comes before the `aborted` answers of the tool requests and the interrupt (P6). With no test and no probe: "a decision of a turn that ended is dropped", and "an approval request outside a Helyx turn, or a v1 method, gets -32601". | probes P1 to P6 passed | Open: tests to add |
| 6 | spec | The text "at any end of the turn the session denies each pending request" (`hooks.md`) and "the session answers each request once" (`Helyx.Provider`) do not state the exception of `Approvals.end_turn/2`: no request goes to a provider process that is `:ending`. | n/a (text) | Open |
| 7 | spec | The ADR 0007 update says "denied, as before". Before, the answer was the error, which the model reads as `approval request failed`; now it is `decline`, read as `patch rejected by user` (research note). Only the item status is as before. | n/a (text) | Open |
| 8 | spec | `long-lived-harness.md` does not say that a JSON-RPC id whose JSON is over 256 bytes stops the provider process (the generic path). | n/a (text) | Open |
| 9 | standards (judgement) | The `Helyx.Session.Hands` moduledoc was rewrapped from about 72 to about 94 columns (same words) to keep `hands.ex` under 400 lines. | n/a | Open, judgement: the file is at 398 lines |
| 10 | standards (judgement) | `Hooks.start/4` copies the shape of `Hands.tool_call/2`; `HarnessChains` copies the bounds 8 and 16 of `ToolQueue`; `Hooks.call_context/3` is used by `Hands.start/4`; `chain_id/1` returns a call id; the test "a call Task's Helyx.Tool.ask/1 ..." asks from a hook Task. | n/a | Open, judgement |
| 11 | standards | No devlog | n/a | Devlog added |
| 12 | spec | The research script's comment names a mode `none`; the script has `interrupt`. The first try with `gpt-5-codex` is not reproducible from the script, which names `gpt-6-luna`. | n/a | Open (the script is in `.scratch/`, not committed) |

## Precommit

The first precommit run failed in Dialyzer (`plugins/bundled` and `apps/coding_agent`): the specs of `Helyx.Provider.Codex.Approvals` named `Helyx.Provider.Codex.State.t/0`, which does not exist. A second run failed in Credo (`%State{}` in a `@spec`). The two specs are removed, as the other Codex helper modules have none. This change to the specs only came after round 1 and was not reviewed; no code path changed.

The spec agent reran the research script against the local stub (`decline`, `accept`, `error`, `interrupt`) on codex 0.166.0, and every claim of the research note matched.

Failure path: no reproduced defect. Probes: the `approval_id` bounds at the check (1 byte, 256 bytes multibyte, empty, 257 bytes, a cut character, invalid UTF-8, a call id that is not a binary); a pending id with a 5 MB call id that is not valid UTF-8 (the generic failure, its text cut and valid); 25 requests through a live session (8 run, 16 wait, the 25th denied, the second request for a waiting call denied, a decision starts the next one, the abort denies all 24 before the interrupt, each answered once); a turn that ends at `done` while a chain runs (denied, the hook Task killed, the next turn's approval allowed). Not reached: the Codex fake end to end with an oversized string id and the order of the decline and the interrupt on the program's input; chains while the hands refuse after an unconfirmed release; a suspended window between a chain result and the turn end; a session stop with pending requests. Noted, not a finding: each request reads the open calls of the whole transcript, and the requests denied at once have no count bound in a turn.
