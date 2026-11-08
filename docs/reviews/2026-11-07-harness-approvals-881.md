# Review of #881: harness approvals through the hook chain

Change: the stream event `{:approval, approval_id, call_id}` and the request `{:approval, turn_id, approval_id, decision}` of `Helyx.Provider`; the check of `approval_id` in `Helyx.Session.Stream.check/1` (`Helyx.Message.approval_id?/1`); the set of chains of a turn (`Helyx.Session.HarnessChains`) and its session module (`Helyx.Session.Server.Approvals`); the chain Task of the hands (`Hands.approve/5`, `Hooks.approve/5`, `Chain.approve/5`); the deny at every turn end before the interrupt; the Codex mapping (`Helyx.Provider.Codex.Approvals`); the research run on codex 0.166.0; `docs/features/hooks.md`, `docs/features/long-lived-harness.md`, and the ADR 0007 update.

The first commit (`7a5227f4`, rebased as `cf43f44a`) stopped at the 45-minute limit after round 1, with the round-1 findings open. The owner decided them on 2026-11-07 (below), and a second `/ship` cycle fixed them in rounds 2 and 3.

Owner decisions of 2026-11-07: finding 1 is fixed in the Codex mapping (own thread and current turn only, any other declined at once, a test with one item id in two threads and two turns); finding 2: AGENTS.md wins, the Core set is `ApprovalChains` / `approval_chains`, and `hooks.md` maps it to ADR 0013's "set of harness chains"; the deny at every turn end stays ("never dropped"); the stub model of the research run stays and the note says so; the other round-1 findings are fixed, and the rewrap of the `hands.ex` moduledoc is undone.

## Round 1 (full)

The state column shows the state after round 1; the resolution of each finding is in "Round 2".

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

## Round 2 (reduced: spec and failure path)

The fix of the round-1 findings, and the two specs and the alias removed from `codex/approvals.ex` after round 1 with no review. Base: `HEAD` (`cf43f44a`). Bounds sensor: `4 candidate functions, 0 flagged, 0 without an answer`. Invariant named in the briefs: a provider's approval request runs the `before_tool` chain of a call only when it is the provider's own request for that call in the current turn.

Resolution of round 1:

| Round-1 # | Resolution |
|---|---|
| 1 | `Codex.Approvals.dispatch/2` maps only a request of the provider's thread and current turn; any other approval request is declined at once. Tests: `turns_test.exs` "one item id in two threads and two turns", "an approval request after the end of the Helyx turn". |
| 2 | `Helyx.Session.ApprovalChains`, `approval_chains`; Core comments say "the provider"; `hooks.md` maps the name to the ADR's. |
| 3 | `hooks.md` "Replaced mechanism" items 6 to 8. |
| 4 | `hooks.md` Bounds rows for a waiting approval chain and the Codex `approvals` map. |
| 5 | Tests in `approvals_test.exs`: the deny and the kill of the chain at a `done`, the cut deny reason, the crash of the chain Task, a call of a closed message, a call open in the tool queue, the order deny, aborted, interrupt at an abort, and a decision after the end of its turn. Codex: `turns_test.exs`, an approval with no item and a v1 request. |
| 6, 7, 8 | Texts fixed: `hooks.md` (the exception of an `:ending` process), ADR 0007 update (decline and error, the text the model reads), `long-lived-harness.md` (the id over 256 bytes). |
| 9 | The `hands.ex` moduledoc is the base text again; `Hands.tool_call/2` moved to `Hands.State` with `chain_call/2` and `chain_id/1`. |
| 10 | `Hooks.start/4` uses `Hands.State.chain_call/2`; the test that asks from a hook Task is renamed. The copied bounds 8 and 16 stay (ADR 0013 sets the set's bounds equal to the tool queue's, as two sets). |
| 12 | The research note states the stub (owner decision). The script stays in `.scratch/`, not committed. |

| # | Source | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 13 | failure path | An approval request for a Helyx tool call whose tool request has not come yet runs a chain; the tool request then runs a second chain on the same call id. Both hook Tasks have the id `{:hook, call_id}`, so `Hooks.orphans/3` at the end of the tool Task kills the approval chain's hook, and the chain Task waits forever: the provider gets no answer until the turn ends. Through Codex: a `dynamicToolCall` item, an approval for it, then its `item/tool/call`. | yes, `Helyx.Test.Connected` probe (no answer in 3.5 s; control 1 s) | Second finding on the binding of a request to its call (round 1 #1), so the mechanism is fixed, not the path: Core keeps one chain for each call id, and a tool request for a call with a pending approval request stops the provider (the generic path), as the opposite order is a deny. Codex binds a request to an open item of the type that its method names, as its tool path binds `item/tool/call` to an open `dynamicToolCall`. Tests: `approvals_test.exs` "a tool request for a call with a pending approval request stops the provider" (fails without the check), `turns_test.exs` "an approval request for an item of another type, or for no open item". |
| 14 | failure path | Codex sends Core an approval for a `dynamicToolCall` item (constructed; no evidence that a real program does it). | yes, CodexFake | Fixed with 13. |
| 15 | spec | Two Core comments still said "harness" (`approval_chains.ex`, `server/approvals.ex`). | n/a (rule) | Fixed. |
| 16 | spec | "Any other request of these two methods gets `decline` ... or with another shape": a request with no `params` got -32601. | yes, spec probe | The mapping reads `params` from the request, so one with no `params` is declined; the text names the integer or string id. Test: `turns_test.exs` request 4. |
| 17 | spec | The Codex `approvals` Bounds row had no number and said "at the latest at the end of its turn", which does not hold for a request of an ended turn. | n/a (text) | Row rewritten (24 wait for a chain; a late request is denied when the session handles it). |
| 18 | spec | The devlog was stale; `hooks.md` did not record that Codex itself declines the child-thread request that ADR 0013 §4 names as a Core deny. | n/a (text) | Fixed. |
| 19 | spec | Credo alias order in `server/approvals.ex` after the rename. | yes, Credo | Fixed. |
| 20 | spec | `Helyx.Provider`: "a process that the session stopped gets no answer" is not true for a late request (`Approvals.late/4` answers the sender). | n/a (text) | Reworded: at most one answer, and one for every request of a process that the session did not stop. |

The spec agent checked that nothing depended on the removed specs and alias. Not reached by the failure-path budget: an approval during a compaction turn, a request of the old program in the window of `Program.replace`, a resumed thread whose item ids repeat, the bounds of waiting chains.

## Round 3 (reduced: spec and failure path, the last round)

The fixes of round 2 (findings 13 to 20). Base: `HEAD`, scope named in the briefs. The invariant named in the briefs: a provider's approval request runs the `before_tool` chain of a call only when it is the provider's own request for that call in the current turn, and one call id never has two chains in the hands at once.

The round-2 fix holds: the reproduction of finding 13 now stops the provider and fails the turn, and across a turn boundary the hands hold only the new turn's Tasks of a call id (the cancel of the old turn ends its Tasks first). The spec agent found no conflict of the new Core stop with ADR 0013, and the Codex item-type check agrees with the research note (the `item/started` of the item comes first).

| # | Source | Finding | Reproduced | State |
|---|---|---|---|---|
| 21 | failure path | An approval request for a Helyx call that Core answered, before the provider's own `tool_result` event closes it, runs the `before_tool` chain with `provider` set, and the provider gets `:allow`: `Approvals.open_call/2` leaves out only the calls that run or wait in the tool queue. This breaks ADR 0013 §4 ("a request whose call id names no open harness call of the turn ... gets `{:deny, reason}` at once") and the moduledoc of `Helyx.Session.Server.Approvals`. Codex reaches it only if the program reuses an item id (constructed; no evidence). | yes, `Helyx.Test.Connected` probe | **Open defect.** Third finding on the binding of a call id to its owner (rounds 1 and 2), so the fix is the mechanism: one map for each turn from call id to its owner (a Helyx tool request or a call that the provider runs itself), set by the first tool request or approval request and checked by both. That adds functions and is over 10 lines, so no small-fix round applies (`/ship`). Not fixed. |
| 22 | failure path | A Helyx tool request for a call id whose approval request was answered runs the call in Helyx (with its own `before_tool` chain, `provider: nil`); the check of round 2 looks only at pending approval requests. No two chains run at once. | yes, `Helyx.Test.Connected` probe | **Open**, same mechanism as 21, fixed by the same map. Reaches Codex only through a reused item id. |
| 23 | spec | The comment at `lib/helyx/session/server/approvals.ex:9` says "Every request gets exactly one answer, as long as the provider process lives"; a process that the session stopped (`:ending`) lives and gets no answer. The contract texts (`Helyx.Provider`, `hooks.md`) are exact. | yes, spec probe | **Open** (a comment; no code changed after the last round). |
| 24 | spec | Two guarantees have only a probe, no test: a tool request for a call whose approval chain waits (not runs) stops the provider; an approval request for a call that waits in the tool queue is denied. | probes passed | Open (tests to add) |

Not a finding: a program that sends one JSON-RPC id twice while the first is pending, with no hook, makes `Codex.Approvals.answer/3` raise at the second deny (`Map.pop!`), so the provider process crashes and the turn fails: the generic path, and no real program is known to do it. Two item types for one item id bind to the latest type, and Core takes the latest call of the id; the binding holds.

Not reached: the background-run variant of finding 21, an approval in a compaction turn through Core, and a probe of the `Program.replace` window (read only).

The loop ends here: round 3 reproduced defects whose fix does not meet the conditions of the small-fix round. The commit holds the code as rounds 2 and 3 reviewed it; findings 21 to 24 are open.

## Third cycle (2026-11-08): the owner of a call id

Owner decisions of 2026-11-07: findings 21 and 22 are defects (21 breaks ADR 0013 §4), the third finding on the call-id binding. The owner of a call id is derived from the state that the session and the hands hold; a store only where a case cannot be derived, bounded by the turn's existing bounds. Finding 23 is fixed and the two tests of finding 24 are added. If a round finds another defect on this binding, the reviewed code is committed and reported.

Before the change, the branch was rebased over #880 (`before_settle`): `Helyx.Session.Hands.Approval` follows the shape of `Hands.Settle` (request, start), `tool_call/2` moved from `Hands` to `Hands.State` with `chain_call/2` and `chain_id/1`, which also take the settle chain Task, and the unused `Settle.chain/2` went. `hands.ex` keeps master's moduledoc and has 394 lines.

The change: `owners` in `Helyx.Session.Turn`, the owner (`:tool` or `:approval`) of each open call that a request named, set by `Helyx.Session.Server.Approvals.own/3` and dropped by `Records` at the call's result. Derived with no store: a call that runs or waits in the tool queue, a call whose approval chain runs or waits, a call with its result. Not derivable: a Helyx call that Core answered before the provider's result (the session drops the ref of the result request, `ProviderRequest.ask/3` arms only a kill, the hands drop the Task), and an answered approval (`ApprovalChains.result/3` drops it). Bound: an entry only for an open call, at most 2 × 1,024 (`Turn` `@max_message_blocks`). Tests: `approvals_test.exs` "the owner of a call id" (the three for findings 21 and 22 fail without the checks), and the two of finding 24.

## Round 1 of the third cycle (full)

Base: the merge base `9bebab64` (both commits after the rebase and the uncommitted change). Bounds sensor:

```text
bounds sensor: 9 candidate functions, 2 flagged, 0 without an answer
  lib/helyx/session/ask.ex:22  WAIT  def await_go do
  plugins/bundled/lib/helyx/provider/codex.ex:224  SIZE  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call"
```

The first launch of the three agents died with a killed session; they were run again. The Codex review had ended before the kill.

| # | Source | Finding | Reproduced | State |
|---|---|---|---|---|
| 25 | failure path | Two calls with one id in one assistant message: `Records.record_result/3` drops `owners[id]` at the result of the first, and the second stays open with no owner. Then an approval for a Helyx call runs its chain, or a Helyx tool request for a call that an approval named runs. `Records` takes such ids on purpose ("a result goes to the first open call with its id"); `Helyx.Provider.Loop` rejects a repeated id, and Codex item ids are unique. Two chains never run at once (the tool queue and the approval set still catch it). | yes, `Helyx.Test.Connected`, both orders | **Open defect on the binding**, so the cycle stops here (owner decision). Proposed fix: drop the owner only when no open call keeps the id. |
| 26 | spec | The "Not covered" case of `hooks.md` (a call that opens only after Core answered its Helyx tool request, then an approval for it runs the chain) breaks ADR 0013 §4 ("a request whose call id names no open harness call of the turn ... gets `{:deny, reason}` at once"), so it cannot be an accepted hole. No provider of the repository reaches it: `Helyx.Provider.Loop` and Codex send the call before its tool request (`loop.ex`, `codex/tools.ex`), and Claude Code sends no approval request. | yes, spec probe P1 | **Open question for the owner.** A contract rule "a Helyx tool request follows its call" would close it with no store; Claude Code's order is not verified, and a Claude Code sub-agent's calls never join the transcript, so the rule cannot be checked for every provider. |
| 27 | spec | The owner's rule says "an answered approval of this turn" and "a Helyx call of this turn (running, waiting, or answered)"; the code covers them while the call is open. After the call's result its id is an ended id, and `owners` drops it, so a Helyx tool request for a call whose approval was answered runs once the call has its result (test "after its result a call id is an ended id"), and an approval for a reused id of an answered Helyx call runs (spec probe P3), as does a tool request for a call that opened after an approval for it was denied (P2). The `Helyx.Provider` line, the hooks.md clause "(... or it was answered)", and the `ToolRuns` comment say "of the turn". | yes, P2 and P3; the test | **Open, question for the owner:** "of this turn" needs a store of every call id that a request named in the turn, and a turn has no bound on its calls, so it cannot be bounded by the turn's existing bounds; the code keeps the open-call scope, which ADR 0013 §4 and #369 leave unchecked after the end. The texts must then say "open call". |
| 28 | standards | No test that a provider process that the session stopped (`:ending`) gets no deny (`Approvals.end_turn/2`). | n/a (test) | Open |
| 29 | standards | No test of the owner that the deny with no `before_tool` hook records (a Helyx tool request after it). | n/a (test) | Open |
| 30 | standards | The "Derived, with no store" item of `hooks.md` says a pending request needs no store, but `owners` also records it at the request; the next item says so. | n/a (text) | Open |
| 31 | spec | The test "a call that opens after its tool request" relies on the session taking the provider's `tool_call` before the hands' result: two senders (AGENTS.md, #592). | n/a (test) | Open: gate the hook until the snapshot shows the call. |
| 32 | Codex (high) | An immediate error result of a Helyx tool request (arguments rejected, the byte bound, past the 16 waiting) records the call as Helyx's, so a later approval for it is denied. | n/a | **Rejected:** the provider named the call as a Helyx call, and an error result is Core's answer, so the call is an answered Helyx call by the owner's rule; the deny fails closed. |

Judgement calls of the standards review, open: `Map.put_new` in `put_owner/3` where every caller checks first; `owners` also holds the derivable pending requests, so each check is written twice; two writers of `owners` (`Approvals`, `Records`); the context merge of a call in three places of the hands; `turn.approval_chains.running` read in `Wait`; the names `@second`, `chains?`, `kind_name`; the unused `approval_id` of the `{:run, ...}` effect; `Message.approval_id?/1` on the bound of an origin id.

The failure-path agent found the other paths of the mechanism held: steer, `message_end`, results of an earlier message, a compaction, a program turn, a new turn, the bound, background runs, and the settle chain after the rebase. Not reached: the Codex fake end to end, a hands refusal while a chain runs, a suspended window between a decision and the turn end, a session stop with pending requests.

The cycle ends after round 1: finding 25 is another defect on the binding. The commit holds the code as round 1 reviewed it; findings 25 to 31 are open.

## Fourth cycle (2026-11-08)

Orchestrator decisions of 2026-11-08, logged for the owner, on the open findings of the third cycle: 25, fix (drop an owner only when no open call keeps the id; a test of two calls with one id in one message); 26, accepted in writing as a stated hole with its reason, and `hooks.md` names it as the one exception to the deny of ADR 0013 §4; 27, keep the open-call scope, and the three texts say "open call"; 28 to 31, fixed (two tests, the "Derived" sentence, the test that relied on two senders); 32 stays rejected. Owner rule of 2026-11-08: decide from prior art without asking, take the simplest choice that keeps the written rules, and list it under "Assumptions". A further defect on the binding ends the cycle: the reviewed code is committed and reported.

The change: `Approvals.drop/2` (the only writer of `owners` with `own/3`) keeps an owner while an open call keeps the id; `Records` calls it after a result joins. Tests in `approvals_test.exs`: two calls with one id in one message (both orders), the owner that the deny with no hook records, a stopped provider process gets no deny (a send trace of the session; a send to the dead process is traced as `send_to_non_existing_process`), and the test of a call that opens after its tool request is gated on the session's `message_update` event. Each new test fails without the code that it guards (checked by a one-function mutation).

## Round 1 of the fourth cycle (full)

Base: the merge base `9bebab64`. Bounds sensor:

```text
bounds sensor: 9 candidate functions, 2 flagged, 0 without an answer
  lib/helyx/session/ask.ex:22  WAIT  def await_go do
  plugins/bundled/lib/helyx/provider/codex.ex:224  SIZE  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call"
```

The failure-path agent died at the usage limit of the model account and was run again.

| # | Source | Finding | Reproduced | State |
|---|---|---|---|---|
| 33 | Codex (high), spec (c)3 | A reused id across messages inherits an ended call's owner: an old call gets its `aborted` result at the close of the next message while that open message holds a new call with the same id, and `drop/2` keeps the owner because `open_call/2` also finds the open message's call. Then an approval request for the new call is denied as a Helyx call, or a Helyx tool request for it stops the provider as an approved call. This breaks the written ended-id rule (ADR 0013 §4, #369: an ended id is not checked) and the "Ended ids" item of `hooks.md`. Only a reused call id reaches it; no provider of the repository reuses one. | yes, spec probes P2b and P2c | **Open defect on the binding**; the cycle ends here. Decision, not built: `drop/2` keeps the owner only while another open call of the same message keeps the id (`Transcript.open_calls/1`, not the open message), so a reused id in a later message starts with no owner, as the ended-id rule says; a test of each direction. |
| 34 | standards, spec | The `Helyx.Provider` line ("an approval request for an open call that a Helyx tool request named is denied") and "no open call is both" (`hooks.md`, the `ToolRuns` comment) state no exception; the accepted hole of finding 26 is one. | yes, spec probe P1 | Open: point to the exception in `hooks.md`. |
| 35 | spec | The Bounds row of `owners` says "an entry goes at its call's result", without the `aborted` result and the open call that keeps the id. | n/a (text) | Open |
| 36 | standards | `next_request/2` in `approvals_test.exs` gives up after 5,000 ms (`flunk`), a second cap beside the single wait of `test_helper.exs` (`Helyx.Test.Events.wait_ms/0`, #295, #193). From the second cycle. | n/a | Open: use `wait_ms()`. |
| 37 | standards | No test of the drop at an `aborted` result (a close or a steer) with two calls of one id; the "Ended ids" items have probes only. | probes passed (failure path: three calls with one id, a steer) | Open |
| 38 | standards (judgement) | `drop(state, _call_id)` also takes a state whose activity is no turn, which no caller makes (AGENTS.md: no fallback for a state that no caller can make). | n/a | Open: narrow it to `%State{activity: %Turn{}}`. |
| 39 | spec | Test "a call that opens after its tool request" accepts any deny; `reason =~ "no open call"` would make it stricter. | n/a | Open |
| 40 | standards (judgement) | Finding 26 of this record still said "Open question for the owner" while `hooks.md` cites the decision. | n/a | Resolved by the decisions of this cycle above. |

Judgement calls, open: the open-calls lookup in both `Records.tool_result/3` and `Approvals.open_call/2`, and `drop/2` reads the open calls again for each result with an owner; "ended ids" for a call id whose request ended, not the call; the trace switched off outside `on_exit` (the session dies with the test).

Failure path: no new path. Probes: three calls with one id (the owner stays to the third result), a taken steer with two open calls of one id (no owner left), a result of an earlier message's call while a new message is open, the turn end. Observations, not findings: a later call with a reused id can get the owner `:tool` at the answer of an earlier Helyx call through `own/3` (a reused id, and a deny is the safe side); at a `done` close the closed message's calls stay in `partial` until the turn becomes the `Wait`, so `drop/2` keeps their owner, and nothing reads it. Not reached: the Codex request ids, the bounds of the approval set at the limit, races of a decision with the turn end, an ask of a hook Task after its chain ended.

The cycle ends after round 1: finding 33 is another defect on the binding. The commit holds the code as round 1 reviewed it; findings 33 to 39 are open.

## Precommit of the fourth cycle

The first run failed in the root tests: `approvals_test.exs` "a call of a closed message of the turn with no result is open" (from the second cycle) took the hook's report with `assert_received` after a provider report. The two come through two proxies, so two senders, and AGENTS.md (#592) allows no reliance on their order. Lines 111, 112, and 307 now use `assert_receive`. This test-only change came after round 1 and had no review round, because finding 33 ends the cycle; it changes no assertion, only the wait.

The second run failed in one root test from #879, unchanged by this ticket: `hooks_test.exs:741` "the hands send the answer of a hook killed while it asks with its pid, before the next record" waited 30 s for `{:asking, hook}`. `Helyx.Test.Hook.Short` has a limit of 100 ms, which counts the hook Task's wait for the session's go (`docs/features/hooks.md`); under the load of the parallel precommit the hook can be killed before its first line, so the test waits for a message that never comes. It passed 10 of 10 alone and with the seed of the run (34 of 34). The hook start of a call Task takes the same path as before the rebase (`Hands.State.chain_call/2` finds a call Task as `tool_call/2` did). Not fixed here: a test of #879 that bounds the start of a hook by wall-clock time (AGENTS.md, #193); precommit ran again.

## Resolution of findings 33 to 39 (2026-11-08)

Orchestrator decisions of 2026-11-08, logged for the owner: finding 33 is accepted under #369 (reused call ids are not checked) and stated in `hooks.md` beside the ended ids, with `drop/2` unchanged; findings 34 to 39 are built as proposed; no review round, the Codex gate follows.

| # | Resolution |
|---|---|
| 33 | `hooks.md`, "The owner of a call id": the item "Reused ids, not checked (#369)" states that a reused call id can take the owner of an earlier call of the id, both ways (`drop/2` and `own/3`). |
| 34 | The `Helyx.Provider` line names the accepted exception with a link to `hooks.md`; "no open call is both" in `hooks.md` and the `ToolRuns` comment says "apart from the accepted hole". |
| 35 | The Bounds row of `owners`: an entry goes at its call's result or `aborted` result when no other open call keeps its id. |
| 36 | `next_request/2` of `approvals_test.exs` waits `wait_ms()`, the single wait of `test_helper.exs`. |
| 37 | Test "at the aborted results of a close the owner goes with the last open call of its id": two calls of one id, an allowed approval, a close that gives both their `aborted` results, then a Helyx tool request for the ended id runs; it fails when `drop/2` never drops. |
| 38 | `drop/2` takes only a state whose activity is a turn. |
| 39 | The test "a call that opens after its tool request" asserts the deny reason "no open call". |

