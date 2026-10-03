# Review: Provider.Loop sends all tool calls of a message at once (#362)

Date: 2026-10-03. Base: `origin/master` at the branch point (`820aa57`). Scope: `lib/helyx/provider/loop.ex`, `test/helyx/provider/loop_test.exs`, `plugins/bundled/test/helyx/provider/openai_test.exs`, and `docs/features/one-provider-path.md`.

## Invariant

At the end of a model message, `Helyx.Provider.Loop` sends a `tool_request` for every valid call of the message at once, in call order, each with a request id unique in the node (`System.unique_integer/1`). It keeps each result by request id and sends the `tool_result` events with the model call id in call order, each when every earlier call has its result. When no call is open, it sends the held steers and one `need_context`. Entry points: `request/3` (`tool_result`, `context`, `steer`, `interrupt`, `turn`) and `info/2` (model Task messages). The session owns the queue, the run one at a time, and the 16-waiting cap. The helper trusts Core to send exactly one result for each request id and a context only after a `need_context`. It drops results of a turn that is not live.

Accepted: a message with more than 17 valid calls gets the session's "too many Helyx tool calls" error for some calls, and the count depends on how fast the first calls end. This is a known ceiling of the session bound, stated in the feature doc. Before #362 the helper sent one request at a time, so the bound never applied to a model's calls.

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 26 candidate functions, 0 flagged, 0 without an answer
```

Simplify (4 agents): the request id is made when the call joins the list, so `dispatch/2` is one comprehension and the entry has no nil id. Not changed: `Helyx.Session.Id.new/0` for the request id (it is random and session-internal; `unique_integer` is unique by construction); ordering the results in the session for every provider (it changes `server.ex`, which #361 owns; a follow-up); sending the rejection with the `tool_request` so that `Tools` answers it (a change of the event shape, out of scope); a guard for a stray result (no caller can send one).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 2 docs, 6 judgement calls | 0 | The doc still said the helper runs calls one at a time (replaced-mechanism row, "Removed replies", the test paragraph), and it had no #362 entry for the removed parts. Fixed: a #362 paragraph lists `tool`, `n`, the `:next` message, `context?`, and the removed tests. Taken: `flush`/`next` renamed `send_ready`/`request_context`; a test variable that shadowed `request/2` renamed; a doc sentence rewritten. Not taken: a struct for the call entry, renaming the shared "serial" fixture. |
| Spec | 3 docs, 1 test gap | 0 | The Decisions entry still named the per-turn counter; the reason to keep `steers` was not recorded; "at once" for a rejected result was misleading. Fixed. The interrupt test sent the interrupt before the `aborted` results; it now follows the session order (`aborted` results, then the interrupt). |
| Failure path | 1 behaviour change | 0 in the helper | Over 17 valid calls in one message, 0 to 3 calls got "too many" (N = 18, 20; five runs). It is the session bound that #358 put in the session, now reached by a model's fan-out. Recorded as a known ceiling in the feature doc; open item for the owner. Abort with tools running, abort with a held steer, results out of order, and a repeated call id gave no defect. |
| Codex adversarial | 1 defect, not in this diff | 0 in this diff | `origin/master` moved to #365 during the review, so the Codex diff held `plugins/bundled/lib/helyx/provider/codex/order.ex`. Its finding (a steer between the calls of a partial message records a completed call `aborted`) is in #365, not in #362. Reported to the orchestrator. |

No reproduced defect in this diff, so the loop ends.
