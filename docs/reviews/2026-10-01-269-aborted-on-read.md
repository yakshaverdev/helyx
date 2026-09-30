# Review: #269, add aborted tool results on read, never write at resume

Scope: `git diff origin/master` on `ticket/269-aborted-on-read`. `Session.resume/2` applies `Transcript.abort_unanswered/2` to the branch and the harness session counts that `Session.File.resume/3` reads. `Server.init/1` writes nothing.

## Checked names

- `write_aborted/1` never existed under that name (`git log -S` over all refs finds nothing). The resume write was an inline block in `Server.init/1`: `Transcript.open_calls/1` mapped to `aborted` results and `append_message/2` for each. The diff removes that block.
- `Transcript.open_calls/1` and its comment on a reused call id exist.
- The #262 text existed in the `Session.start/2` doc and in `docs/features/coding-agent.md` (the accepted hole in the persistence section). Both are replaced.
- The #266 newline repair runs in `Session.File.resume/3` (`repair/2`). It stays: the next append needs its entry on a line of its own. It writes no entry.

## Simplify

- Reuse: one `{:error, "aborted"}` helper for all five sites. Skipped: the other four sites are outside the diff.
- Efficiency: a fast path for a transcript with no open calls. Skipped: one O(n) pass per resume, small next to the JSON decode.
- Altitude: add why `open_calls/1` and the insert rule differ. Fixed in the comment.
- Round 2: `List.duplicate/2` for the insert positions. Fixed. Move the count shift into `Session.File`. Skipped: the file module states that answering open calls is the session's job.

## Round 1 (full)

Bounds sensor: `bounds sensor: 5 candidate functions, 1 flagged, 0 without an answer` / `lib/helyx/session.ex:156  SIZE  def resume(core \\ Helyx.Core, opts) do`.

| Axis | Finding | Resolution |
|---|---|---|
| Spec, Codex (high) | `Session.File.harness_sessions/1` counts file messages, without the inserted results; the live session counted them. After a resume `Transcript.resumable/3` drops too few messages, and can resume a harness session that never read the replay. Reproduced (Codex probe) | fixed: `abort_unanswered/2` raises each count by the results inserted at or before it; unit test and a resume test on the session state |
| Spec | no resume test with a file written before #269 | covered by the unit test "unchanged"; the old write put the results at the same place |
| Spec | the ticket says "right after each assistant message"; the code puts them after that message's results | kept: this is where a live abort puts them, and done-when 2 holds |
| Standards | a comment line over 120 characters; a stale `open_calls/1` comment; long doc sentences; a test match with unused names | fixed |
| Standards | two rules for "what answers a call" (judgement call) | kept, with a comment: after the pass no call is open, so the rules agree |
| Failure path | none reproduced; 20,000 random transcripts: idempotent, only inserts, no open call after | none |

## Round 2 (full)

The fix is more than 15 lines, touches two code files, and changes the arity of `abort_unanswered`. Bounds sensor: the same single flag.

| Axis | Finding | Resolution |
|---|---|---|
| Failure path | a harness session entry written before the crash, right after a message with an open call, gets a count one higher after the resume (3 against 2). Reproduced with a scratch connected provider | not a defect: the feature doc states this case. The skipped message is the inserted result, never an assistant message, so `resumable/3` gives the same answer; the agent could not make it choose a wrong id. The comment and the doc now name the case |
| Spec | none reproduced. The bounds row "Session file on resume" did not state the results inserted outside the heap cap | fixed in the row |
| Spec | the newline repair could move to the first append | kept: the ticket allows it, and the doc states why it stays |
| Spec | a resumed harness session gets no replay, so it does not see the inserted results | older than #269 (master behaves the same); out of scope |
| Standards | unclear subject in the count comment; one `@type` for the harness session map; the nested reverse; the test reads internal state (judgement calls) | comment fixed; the others kept (the state read follows ten other tests in the file) |
| Codex | approve, no findings | none |

Round 2 reproduced no defect, so the loop ends after round 2.
