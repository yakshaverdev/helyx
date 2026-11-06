# Review: #834, the resume reads the whole file

Ticket #834, option 2 of the owner (2026-11-06): the resume reads the session file one line at a time, so every file that a session wrote resumes. Base: `d31eda21` (merge base of `ticket/834-resume-reads-all`).

Invariant: `Helyx.Session.File.resume_picked/3` reads a file of any size one line at a time; a line over 64 MiB, or one whose decode passes the 1 GiB heap cap of its own process, is `{:error, {:too_large, text}}`, and the file does not change.

## Bounds sensor (round 1)

```
bounds sensor: 7 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

Simplify: moved the stat-and-open of a regular file into `Scan.with_regular/2`, which `Scan.read_up_to/2` uses too; wrapped doc lines; renamed a test.

| Axis | Finding | Resolution |
|---|---|---|
| Codex | `plugins/bundled/bench/session_append.exs` still called the removed `Reader.read/2` (reproduced: `UndefinedFunctionError`) | fixed: the bench measures `File.resume_picked/3`; its module compiles |
| Spec | the row said a 64 KiB line decodes in the caller "under 3 MiB": a probe measured about 7 MiB for 64 KiB of `[` | fixed: the row gives the measurement of 2026-11-06 (worst of six shapes 6.4 MiB; nested arrays about 65 bytes of heap per byte at 1 MiB, so the largest session-written decode is about 520 MiB, under the cap) |
| Spec | the row said the held reads are "at most the bytes of the file": a probe measured 1.46 times | fixed: the row states at most twice, a read and a line joined from two reads |
| Spec | the replay row of `memory.md` named only the 64 MiB bound of the live queue, not its 1,024 chunks | fixed |
| Spec | the rule "Read as one chain" did not name the `too_large` line | fixed |
| Spec | the snapshot of a hand-edited file can pass the client frame bounds of `tui-attach.md`, a new consequence of no file limit | accepted in `tui-attach.md` decision 13, reported to the owner with the commit |
| Standards | the limits were a bare map of known shape (AGENTS.md: structs over maps) | fixed: `Helyx.Session.File.Reader.Limits` |
| Standards | measurements and history in code comments | fixed: the comments point to the row |
| Standards | a stale test comment ("the file binary itself is off-heap"); a long doc line in `Helyx.Session`; an unclear comment on the decode exit | fixed |
| Standards | the heap error text naming its line had no test | fixed: `file_test.exs` asserts "line 3" |
| Standards | the test of the per-line cap does not prove that the lines together pass it | verified: the test fails on the code before #834 (whole-file cap of 16 MiB), run on 2026-11-06 |
| Failure path | no defect: the line limit at the 1 MiB read edges (six cells), a torn line after a long one, a FIFO, a symlink to it, a folder, a dangling link, `/dev/null` | none |

Not reached by the failure path: a disk read error, a resume of several GB at the open deadline, a FIFO swapped in between the stat and the open (a window from before #834).

## Round 2 (reduced: spec and failure path)

The invariant of the round-1 fixes: every bound or figure that a doc states for the resume is true and has a test or a probe.

| Axis | Finding | Resolution |
|---|---|---|
| Spec | the slow acceptance test used tool calls of `0,`, not the content with the most heap for each byte; the row names nested arrays (probe: 68 bytes of heap per byte at 1 MiB, a call of 8 MiB about 480 MiB) | fixed: the test writes one call of 8 MiB of nested arrays and one of `0,`, resumes with the default cap, and shows that a cap of 384 MiB rejects the nested line |
| Spec | the replay row of `memory.md` stated a new drop behaviour with no test | fixed: the row says only that the replay counts in the bounds of the live queue, the row above |
| Failure path | reproduced: a hand-edited file of 112 MB with integers of 1,000,000 digits resumed in 29,194 ms, past the open deadline of 25,000 ms; the docs said about 5 GB | fixed in the row, in `Helyx.Session.resume/2`, and in `wire-protocol.md`: about 5 GB for a file that a session wrote (no integer over 100 digits), sooner for a hand-edited file; the decode process of a line runs to its end after the kill, at most one line of 64 MiB (as before #834, then the whole file) |

Not reached: a FIFO swapped in between the stat and the open; concurrent resumes; the header scan under concurrent appends; a file that grows during the read.

## Round 3 (reduced: spec and failure path)

| Axis | Finding | Resolution |
|---|---|---|
| Failure path and spec | reproduced: tool calls of dense small values that pass `Helyx.Session.Stream.check/1` and the 8 MiB bound (`[0,0,...]`, `[{},{},...]`, nested arrays), written with `append_message`, resume at 3.0 to 3.9 MB/s: 16 messages, 128 MiB, in 34.6 to 45.3 s. A file of about 85 MB that a session wrote passes the open deadline of 25,000 ms and fails with `{:error, :open_timeout}`; the docs said about 5 GB | **open.** Second finding on the time of the read (round 2), and no fix of 10 lines in one file: the loop stops (`/ship`). The docs now state the measured rates and the open defect; the ticket goes back to the owner |
| Spec | the row said a usage count is at most 10^9; `Helyx.Usage.valid?/1` allows 10^15 | fixed in the row |
| Failure path | the caller holds the decoded transcript with no heap cap, about 16 bytes of heap for each file byte for dense tool calls | accepted by the decision of the owner: the memory bound is the transcript |

Where the time goes was not measured: the decode of one dense line of 8 MiB runs at 16 to 22 MB/s alone; the rest is after the decode (the copy of the term to the caller, `Codec.decode/1` with `Helyx.Message.cap_integers/1`), a guess of the failure-path agent.

Options for the owner, not decided here: the resume load gets its own deadline, or none, since its work is bounded by the file; the read gets faster for dense tool calls; or a file whose read passes the deadline is accepted as the limit, documented as such.

## After round 3: precommit

Credo reported `lib/helyx/session.ex` at 403 lines and a nesting depth of 3 in `Reader.more/6`. Fixed with no change of behaviour: the doc of `resume/2` is rewrapped and shorter, and the split of a new chunk moved into `Reader.chunk/7` with the same three cases. `file_test.exs` with the slow tests passes.
