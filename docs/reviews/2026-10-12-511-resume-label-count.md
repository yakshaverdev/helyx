# Review: #511 The resume label counts assistant messages

Invariant: a resume label of a provider holds the number of assistant messages before it on its branch. `Records.resume_id/3` (named `Records.resume/3` before #510) writes it live through `Transcript.assistant_count/1`, and `Branch.resume_ids/2` derives it on read from the message entries with the role `assistant`. `Transcript.resumable/3` gives the resume id only when the transcript has more assistant messages than that count and its last assistant message came from that provider with no `:aborted` or `:error` stop. `Transcript.repair/1` inserts and drops only tool results, so it returns only the transcript and no count shifts. The file format does not change, and the fork rule of #282 still drops the labels at a fork. Accepted and out of scope by the ticket: entry ids on messages replace the count when branching needs them (`docs/reviews/2026-10-12-domain-review.md`, A4 and section 12).

## Replaced mechanism

The old mechanism: a label stored the number of all messages before it, and `Transcript.repair/2` shifted each count by the tool results it inserted at or before it and dropped before it.

| Old part | Now |
| -------- | --- |
| Live count `length(state.transcript)` (`Records.resume/3`, `Records.resume_id/3` after #510) | `Transcript.assistant_count/1` |
| Read count of every message entry (`Branch.resume_entry/2`) | Only message entries with the role `assistant`. `Codec.decode/1` rejects any other role on the same branch, so the two counts agree |
| `repair/2` returned `{transcript, shifted}`; `walk/5` kept `inserts` and `drops`; `pair/2` gave the offsets of stray results | Deleted. `repair/1` returns the transcript; `pair/2` gives the open calls and the kept results |
| `resumable/3` dropped `count` messages, then took the last assistant message | It counts the assistant messages and takes the last one in one pass, and needs more than `count` |
| `last_assistant/1`, public, with its test | Private (`count_and_last_assistant/1`); no other caller |
| Test "a program session count moves past the results inserted before it" | The property moves to the random test: the answer with the inserts equals the answer of the label's place in the file |
| Test "a count moves back by the results dropped before it, and forward by the results inserted" | The same random test, which generates stray, second, and late results |
| Persistence tests of the shifted counts (3, 4) | They now assert the assistant count (1) after the repair |
| `file_test.exs`, the restored label with the messages before it | Adds an assistant message and its result before the label, so the count (1) shows that a user message and a tool result do not count |
| `file_test.exs`, the fork test of #282 | Appends assistant replies in place of user messages, so the counts (1, 2) stay non-zero and show the per-branch count |
| Claude Code and Codex turn tests of the stored label | Counts 1 and 3 become 0 and 1: the assistant messages before the label |

No property that users or clients see changes: the resume decision is the same. No new state, so no new bound.

## Round 1 (full)

Simplify: `Transcript.assistant_count/1` in place of an inline count in `Records` (reuse, simplification, altitude); the comments in `branch.ex` and `transcript.ex` no longer repeat the argument that the repair keeps the count. Skipped: the test reference repeats the model and stop check of `resumable/3`, on purpose, as an independent reference. Efficiency: no finding.

Bounds sensor:

```
bounds sensor: 7 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | failure path, spec | The random test generator used `1..Enum.random(0..n)`, which counts down to two items at 0: it never made an empty file or a reply with no tool call, and it printed a deprecation warning. Reproduced | Fixed: `1..n//1` |
| 1.2 | spec | The ticket asks to compare with the old rule; the test compares with the label's place in the file | Kept, and the test comment states it: on the unrepaired file the old count needed no shift, so dropping the messages before the label's place is the old rule |
| 1.3 | spec, standards | No "Replaced mechanism" inventory | Fixed: the section above |
| 1.4 | standards | The `branch.ex` comment named the decode only as "the `Codec` decode" | Fixed: names `Codec.decode/1` |
| 1.5 | standards | Judgement calls: the private helper that returns `{count, last}` was named `last_assistant/1`; the test reference `at_place/2` | Renamed to `count_and_last_assistant/1` and `expected_resume/2` |
| 1.6 | Codex | Approve, no material findings | None |
| 1.7 | failure path | 300 random files resumed through `Session.File.resume/2`, `repair/1`, and `resumable/3`, compared with the label's place: 0 mismatches. Not reached: forks with labels in the random probe, a file lost in the middle of a turn | None |

The fix, counted without test files and Markdown, changes 15 code lines (a comment and a rename) in two code files, so round 2 is full. It also changes the test generator (1.1).

## Round 2 (full)

Simplify: the comment reflow of round 1 left a ragged line in `branch.ex`; fixed. The suggested `Stream.repeatedly` form of the generator was tried and dropped for `1..n//1`, which is shorter (standards).

Bounds sensor, base `8d1abd1` (the state that round 1 reviewed):

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | standards, spec | Row 1.1 named `1..n//1` while the code used `Stream.repeatedly`; the last line of round 1 left out the test change | Fixed: the code uses `1..n//1` again; the line names the test change |
| 2.2 | spec | The "Replaced mechanism" table had no row for the changed `file_test.exs` and plugin turn tests | Fixed: rows added |
| 2.3 | spec | The random test compares with the meaning of the old rule, not the old shift code | Kept, as in 1.2; the domain review (A4) compared with the old code over 20,000 transcripts |
| 2.4 | Codex | Approve, no material findings | None |
| 2.5 | failure path | No defect. Probes: a resumed file with a stray result and an open call, then turns across a model switch, compared the live labels and `resumable/3` with `Session.File.resume/2` after each step; two writers on one file with forks, 900 rounds. Not reached: a real short write (ENOSPC), a `{:resume_id, ...}` event in a program turn, two live Cores with labels of several providers. Noted outside this change: after a failed write the provider session keeps turns the file lacks, and a resume still continues it; the old rule answered the same | None |

No round reproduced a defect in the code after round 1, so the loop ends.

Gate r1 (Codex): 0 findings, approve

## Rebase r1 (reduced)

The branch was rebased on `origin/master` after #510 (merge `0f3442f`). The one code conflict was in `Records.resume_id/3`: the resolution keeps the #510 name, the `lost` flag from `conn.resumed` and its clear, and the `:resume_id` event, with the #511 count `Transcript.assistant_count/1`. `docs/reviews/escapes.md` keeps every row, #511 last. Tests run: `transcript_test`, `file_test`, `persistence_test`, `provider_process_test`, `stream_events_test` (224 tests, 0 failures), and the Claude Code and Codex turn tests (19 tests, 0 failures).

Bounds sensor, base `origin/master`:

```
bounds sensor: 7 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| R1.1 | spec, failure path | This record still named `Records.resume/3` (invariant, "Replaced mechanism" table) and a `resume` event (2.5) | Fixed: names `Records.resume_id/3` and `{:resume_id, ...}` |
| R1.2 | spec | Stale names of #510 on master, outside this diff: `docs/features/one-provider-path.md:45` says "the provider's last `resume` event"; the test name "a resume event passes" in `test/helyx/session/stream_test.exs:97` sends `{:resume_id, "a", 0}` | Not changed here: not part of #511; reported to the orchestrator |
| R1.3 | failure path | No defect. Probe: 15 seeds of 12 steps with random model switches across the conn and test models, and a stop and resume in about one step of four; after each turn the live labels, the assistant count, and `resumable/3` equalled those of `Session.File.resume/2` and `repair/1`: 0 mismatches. Not reached: a resume id event between a partial and an abort, a real short write (ENOSPC), forks with labels in a live run | None |

No defect was reproduced, so the round ends the loop.
