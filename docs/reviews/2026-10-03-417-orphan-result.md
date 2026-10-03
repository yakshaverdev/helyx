# Review: #417, the resume repair drops a tool result with no open call

Branch `ticket/417-orphan-result`, base `origin/master` `8e73900`.

Invariant: after `Session.resume/2` (the only entry point) applies `Transcript.abort_unanswered/2` to the branch read from disk, every tool result answers exactly one call of the assistant message right before its run of tool results, and every call there has exactly one result. The repair drops each result that answers no open call (an unknown id, a second result for one call, a result after a later message, a result with no assistant message before it), inserts `aborted` results as before, and moves each resume count forward by the inserts at or before it and back by the drops before it, so `Transcript.resumable/3` gives the same answer. The file is not rewritten (ADR 0001). Accepted: a count exactly at an insert point can come from an entry written before the crash; both readings give the same `resumable/3` answer.

## Changed tests

- `transcript_test.exs`, "a result after a later message does not answer the call": the late result was kept before; now it is dropped (ticket target 1). Renamed to say so.

## Target 4, the TUI mount

The test is at the Core level: `persistence_test.exs` resumes a file with all three kinds of orphan result and asserts that the subscribe snapshot, which a TUI client mounts from, holds only paired results. On master, `Helyx.TUI.ViewModel` skips a result with no open cell, so a TUI mount test passes with or without this change. The crash at mount exists only with the code of #407, which merges after this ticket and can add the TUI mount test.

## Round 1 (full)

Simplify: four agents. Applied: none in code. The altitude agent found that the first diff reverted #412; the cause was a base older than master, fixed by a rebase onto `8e73900`. Skipped: carry a running shift inside `repair/5` in place of the `inserts` and `drops` lists (simplification agent; each resume count needs its own position check, so it is not simpler).

Bounds sensor:

```
bounds sensor: 6 candidate functions, 1 flagged, 0 without an answer
  lib/helyx/session.ex:126  SIZE  def resume(core \\ Helyx.Core, opts) do
```

The flag is on a function where the diff changes only the doc and a comment; the file read keeps its 64 MiB cap.

| Axis | Finding | Resolution |
| --- | --- | --- |
| Codex | Verdict approve, no findings (7,381 generated transcripts: pairing, a second pass, and `resumable/3` at every count) | none |
| Failure path | No defect reproduced. Probed: 3,000 random transcripts with every count from 0 to n (a second pass, `open_calls/1` empty, counts in range, the same last assistant message after the drop); the live writers write no stray result | none |
| Standards, spec | `coding-agent.md`, the `tool_call_id` rule: the count sentence named only the inserted results | Fixed: it also subtracts the dropped results, and an inserted or a dropped result is never an assistant message |
| Spec | The same rule cites `abort_unanswered/1` | Fixed: `/2` |
| Spec | The bounds row "Session file on resume" names only the inserts | Fixed: it names the drops and the one integer kept per drop |
| Standards | `session.ex` doc line not reflowed | Fixed |
| Standards | `abort_unanswered/2` now also drops; the name hides that | Kept: the ticket names the function, and the comment calls it the read-time repair |
| Standards | Offsets in `pair/2` and input indexes in `repair/5` are two coordinate systems | Kept: one conversion at one line, with the comment |

Round 1 reproduced no defect, so the loop ends.
