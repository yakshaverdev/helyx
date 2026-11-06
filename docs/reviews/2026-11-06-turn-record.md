# Review: turn record (#553)

Base: `9c25ff2a` (merge base with origin/master), the feature doc commit, and the uncommitted change. Design: `docs/features/turn-record.md`, decisions of the owner of 2026-11-06.

Invariant: for every provider call that a session with a file sends (the turn submit and the answer to a context request, `Helyx.Session.Server.Prepare.prepared/2`), the last `system_prompt` entry before the reply of that call holds the system prompt of that call, cut to 262,144 bytes on a character boundary with `bytes` the full size, or `null`; an unchanged prompt writes no entry; the first call of each session process writes one; a resume keeps nothing of the entry and skips one over the cap or damaged, under the chain check; a system prompt that is not valid UTF-8 fails the build as `bad_context`.

## Round 1 (full)

Simplify: one edit (rewrap of one doc line in `Helyx.Session.Stream`).

Bounds sensor:

```
bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer
```

| Reviewer | Findings | Reproduced defects |
| --- | --- | --- |
| Codex adversarial | 0 (verdict approve) | 0 |
| Failure path | 0; probed the cut with 3- and 4-byte characters at each offset before the cap, `""`/nil/`""` as three entries, and resume after 10 entries | 0 |
| Standards | 1 hard (doc claim of the bundled-prompt test), 1 untested guarantee (hash after a failed write), 4 judgement calls | 0 |
| Spec | 2 contract-text findings (F1 "the one exception" is false: the reader already drops a bad `harness_session` label without a failure; F2 the `bytes` range 0..10^9 is not enforced), 2 untested guarantees (non-UTF-8 from the Compaction plugin; no write by a summary call), 1 scope note (the UTF-8 check also fails a session with no file: stated in the doc) | 0 |

Resolution (wording, doc, and tests; no code defect, so the loop ends after round 1):

- Standards hard finding: the feature doc now says what the test proves: it measures the fixed text and adds the public caps; the private value-line cap of 4,096 bytes is repeated in the test, and a change of it needs the test changed.
- Hash after a failed write: new test `a failed write of the entry turns persistence off and keeps no hash` (the test ModelContext moves the file away during the build, after the user message is written, so the entry write itself fails).
- F1: "the one exception" and "the one entry" removed from the feature doc, `coding-agent.md`, and the reader comment.
- F2: `bytes` is a non-negative integer that the reader does not read; the range is gone.
- Non-UTF-8 from either plugin: `raw_system` and `raw_system_compact` rows in the context check table of `provider_process_test.exs`.
- A `system_prompt` entry that breaks the chain: new test, the resume fails with `invalid_file`.
- No write by a summary call: checked by reading. The summary path is `Prepare.prepared(state, {:summarize, plan})` to `Summary.start/2`, which never reaches `Records.system_prompt/2`. No test.
- Judgement calls kept: the test file is named after the feature, as `persistence_test.exs` and `memory_test.exs` are; the call to `Records.system_prompt/2` in both branches of `prepared/2` is kept, because the two branches differ right after it; `system_hash` with `:unset` is kept, because the field comment names the three states (moved to the file struct after round 1, see below).

## Accepted holes

- A context request while an assistant message is open: that reply is written after the new entry. Only `Helyx.Provider.Loop` sends context requests, and it closes the message first (C2 of `one-provider-path.md`).
- No Core size bound on `Helyx.Context.system` except the entry cap.
- The context of a summary call, the recall message, and the skills carried after a summary are not recorded.
- The first call after each resume writes one entry even when the prompt did not change.

## Precommit after round 1

Credo failed: `Helyx.Session.Server.State` had 32 fields (the cap is 31), and two test plugin functions had a cyclomatic complexity of 10. Fix: the hash moved from the session state into the `Helyx.Session.File` struct (`system_hash`, default `:unset`), and `append_system_prompt/2` compares and sets it. The hash says what the file holds, so it belongs there; a struct of a start or a resume starts with `:unset`, and a failed write raises before the hash changes. The test plugins got a helper each. `file.ex` comments were shortened to stay at 400 lines.

## Round 2 (reduced: spec and failure path)

Base: the merge base `9c25ff2a`, as no snapshot of the round 1 code was kept; the briefs named the parts changed in this round and the invariant to attack.

| Reviewer | Findings | Reproduced defects |
| --- | --- | --- |
| Spec | 0; checked every place that builds or replaces a `%Helyx.Session.File{}` (create, resume, repair, model change, other appends, lock loss, write failure), with probes of the hash after a model change, `""` against nil, and a failed write | 0 |
| Failure path | 0; the same paths by reading, and every way a model call starts | 0 |

No reproduced defect: the loop ends.

Noted, not probed: a compaction turn of a provider that keeps its own history sends no context, so it writes no entry. An assistant message that such a turn adds would have the entry of an earlier call as its prompt, which is the prompt that provider last got from Core.
