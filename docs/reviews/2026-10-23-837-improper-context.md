# Review: an improper context list from a plugin (#837)

Change: `checked_context/2` in `Helyx.Session.Stream` rejects an improper `messages` or `tools` list with the existing `{:error, {:bad_context, plugin}}`, through `List.improper?/1` in the body. No new handler, state, or error variant. The two review rows that accepted the improper list (`2026-09-27-199-harness-process.md`, round 6; `2026-09-29-227-checked-prepare.md`, failure path) each get an update note.

Base: `addb2a1a` (merge base). Before the fix, the improper cases of `provider_process_test.exs` that existed then failed (five, among them `improper_compact` with `** (stop) ":badarg"` in the session); after it they pass. Round 1 added three more.

## Bounds sensor

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

Simplify: one comment wording fix in `test/support/interfaces.ex`.

### Standards

No hard violations. Judgement calls:

1. The comment gave a reason only for `messages`, but the check also covers `tools`. Fixed: the comment and `session-stream.md` say that Core and the providers walk both lists.
2. No test for an improper `tools` list from Compaction, and none for `tools` on a connected turn. Fixed: `improper_tools_compact` in `Helyx.Test.PrepareCompaction`, and both tools cases in the connected and the Loop tables of `provider_process_test.exs`.
3. `context.messages ++ :tail` is not an improper list when `messages` is `[]`. Rejected: the test plugins choose the case by the text of the last message, so `messages` is never empty in that branch.
4. The duplicated fixture line in the two test plugins: kept, as the existing `bad_*` cases are duplicated too.

### Spec

No missing requirement, no wrong implementation. Coverage gaps, both fixed:

1. A Summary plan whose context has an improper list: probe only. Fixed: two assertions in `summary_test.exs`, "the plan check of the context build, at its bounds".
2. Improper `tools` from Compaction: see standards 2.

Guarantee table (after the fixes):

| Guarantee | Proof |
| --- | --- |
| ModelContext, improper `messages` or `tools` → `{:bad_context, :model_context}`, next turn succeeds (Loop and connected turn) | `provider_process_test.exs`, tables "failures" and "the context check of a Loop turn" |
| Compaction, improper `messages` or `tools` → `{:bad_context, :compaction}`, next turn succeeds | same tables |
| A Summary plan with an improper list in its context → `{:bad_context, :compaction}` | `summary_test.exs`, "the plan check of the context build, at its bounds" |
| The connected provider process is kept | `provider_process_test.exs`, "fails the turn and keeps the provider process" |
| The reason names the plugin, not the value | both tables compare against `inspect({:bad_context, kind})` |
| List elements are not checked | unchanged; probe of review 2026-09-27 round 6 |

### Failure path

No reproduced findings. Probes through `prepare/4`: improper lists from each plugin and in a Summary plan are rejected; a proper list of 1,000,000 messages passes, and the same list with an improper tail is rejected; `List.improper?/1` is one pass, no more than the append that follows. The check runs before every append to the messages (`turn_loop.ex`, the memory recall in `prepare.ex`, `summary.ex`). No duplicate check. Not reached: a full session turn with an improper Summary plan (now covered at `prepare/4` by the new test).

### Codex

Verdict: approve. No material findings (14 probes).

## Precommit, first run

Failed on test support only: Credo, `Helyx.Test.PrepareContext.build_text` at cyclomatic complexity 10 (max 9), and Dialyzer `improper_list_constr` on the literal `[:tool | :tail]`. Fixed: the two ModelContext improper cases moved to a private `improper/2`, and the test plugins build the improper lists with `++`. Because test code changed after round 1, a reduced round reviewed it.

## Round 2 (reduced: spec and failure path)

### Spec

The first spec agent returned no report and was rerun. No reproduced findings. A probe called each of the four `improper_*` cases of the test plugins: each field is a list for which `List.improper?/1` is true, and `prepare/4` returns `{:bad_context, kind}`, so every case fails without the fix. One wording finding: this record said "the five new cases"; fixed above. Process note from the agent: it copied a probe into `test/` for a few seconds by mistake and deleted it unrun.

### Failure path

No reproduced findings. `build/2` and `compact/2` are called only in `Stream.prepare/4`, and every return, the plan context included, goes through `checked_context/2` before an append. The summary call sends the checked plan context. The memory recall already catches an improper list (`Recall.checked/1`). Not reached: the slow tests, and nested improper lists inside tool specs or message elements (the elements are not checked, as stated).

## Result

Round 2 reproduced no defect, so the loop ends.
