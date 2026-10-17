# Review: #712, the context estimate of a snapshot and a resume after a compaction

Branch `ticket/712-snapshot-compaction`, base `2a67c1cc`.

The invariant: a snapshot (each subscribe, and the subscribe after a resume) gives the context estimate of the live path after a compaction. `Helyx.Session.Totals.of/2` applies the last compaction after the message that it names, with `Totals.compacted/2`: `tokens_after` with zero bytes after it, or nil tokens when `tokens_after` is nil. The session keeps only the anchor (the id of the last transcript message before the compaction, and `tokens_after`), and the entry in the file names the same id (`last_id`). The estimate is not stored.

## Round 1 (full)

Bounds sensor (base `2a67c1cc`'s working tree):

```
bounds sensor: 6 candidate functions, 0 flagged, 0 without an answer
```

Simplify (4 agents: reuse, simplification, efficiency, altitude): 2 findings applied (the anchor rule was written in `Records` and in the reader: one function; the test repeated the `compacted/1` helper: it takes `tokens_after`). Skipped: the doc reflow of `Helyx.Session.follow_up/3` stays, because `session.ex` must not grow and the resume adds one field; the reader reads a bad `tokens_after` as nil (see below).

| Axis | Findings | Reproduced defects | Resolution |
|---|---|---|---|
| Codex adversarial | 1 | 1 | fixed |
| Standards | 3 test gaps, 5 judgement calls | 0 | gaps closed; 2 calls applied |
| Spec | 3 | 0 | closed |
| Failure path | 0 | 0 | no defect in the probes |

1. **Codex: a compaction after an interrupted result moves at the next resume.** A resume adds an interrupted result that is not on disk. A compaction after it anchored on that result; the next resume took the anchor from the place of the entry, the message before the result, so the result's bytes counted after the compaction (bytes 0 live, 165 after the resume). Reproduced in `compaction_test.exs`, "a compaction after an interrupted result keeps its estimate at the next resume". Fix: the compaction and the summary entries name their anchor id (`last_id`), and the reader takes it from the entry, not from its place. The positional anchor and `Totals.compaction/2` are gone.
2. **Standards: no test for the reader bound, the summary path, or the last entry.** Added `file_test.exs`, "the last compaction or summary names its message and its tokens after" (10^9, 10^9 + 1, -1, no id, the last of a compaction and a summary), and in `summary_test.exs` the `last_id` of the written entry and the anchor after a resume.
3. **Standards (judgement): the reader reads a bad `tokens_after` as nil, while the reader's comment says damage is never dropped in silence.** Kept: the count changes only the estimate, so the smallest unit is the count, not the file (AGENTS.md, "Reject the smallest unit"). The comment at the clause says so.
4. **Standards (judgement): the anchor type was written four times.** `Totals.compaction/0` type. **`at/3` named nothing**: now `compacted_at/3`. Not applied: `of/1` stays for the test callers; the reflow in `session.ex` stays (line budget).
5. **Spec: stale bounds row** (`Totals.of/1` in `session-snapshot.md`): now `of/2`. **Resume test with nil only**: the new test resumes with 40.

Failure path probes (all three paths equal): a compaction while the reply is open, between a call and its result, at 10^9, two compactions; the summary path; damaged entries before any message. Not reached: a ring fallback to a snapshot, persistence off then a compaction, the TUI `from_snapshot` end to end, the stated ceiling.

## Round 2 (full)

The round-1 fix changes more than 15 lines in more than one code file and changes the arity of `append_compaction` and `append_summary`, so round 2 is a full round. Base `2a67c1cc`.

Bounds sensor:

```
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

Simplify (2 agents over the four angles): applied: `Records.persist_compaction/3` holds the record on disk and the anchor of both a compaction and a summary; the reader takes `tokens_after` from the entry. Altitude asked to derive the anchor after the repair instead of `last_id`. Not applied: after a crash between a call and its result, the place of the entry and the derived results do not tell which results came before the compaction, and the move needs lines in `session.ex`. Applied in its place: an entry with no `last_id` key (written before #712) anchors on the message before it, so old files get the fix too (`file_test.exs`).

| Axis | Findings | Reproduced defects | Resolution |
|---|---|---|---|
| Codex adversarial | 0 (approve, ten probes) | 0 | n/a |
| Standards | 3 rule-text notes, 4 smells, 2 doc notes | 0 | 2 wording fixes |
| Spec | 0 | 0 | guarantee table complete with probes |
| Failure path | 0 | 0 | n/a |

No round reproduced a defect, so the loop ends.

1. **Standards: "an entry whose `last_id` is not a string gives no estimate change" is not exact**: a later such entry drops an earlier anchor. Only a damaged file can do that: the writer writes null only with an empty transcript. The text in `harness-compaction.md` now says that.
2. **Standards: the reason in the `@doc` of `append_compaction/6`** belongs in the feature doc: the doc now links `session-snapshot.md`.
3. Not applied (judgement): the summary path has no snapshot test, because the summary test provider reports no `context_tokens`; `summary_test.exs` checks the written `last_id` and the anchor after a resume. The term `compacted` for the field, next to `Totals.compacted/2` and `Transcript.compacted/3`, follows the existing names. `of/1` stays for the test callers. The `if` in the test builder stays.

Spec probes (all green): no message before a compaction (no anchor, `"last_id": null`), two compactions, a `last_id` that is an integer, two resumes in a row, the stated ceiling (a stray result as the anchor gives the last usage, `800/0`), an auto compaction while a reply is open, then a stop and a resume (`40/0`). Failure-path probes: a compaction in the middle of a stream with a tool call (`40/23` on all three paths); an open call, a compaction, a stop, three resumes, and a second compaction (`7/6`). Not reached: a failed disk write at the compaction entry, a torn last line with a compaction entry, a model switch between a compaction and a resume.

The spec agent saw one failure of `summary_test.exs:153` ("an abort stops the summary call…") in one of three runs, with no error text; the diff does not touch that test.

## Round 3 (after precommit)

Precommit failed on two steps. Credo strict: "Struct has more than 31 fields (32 found). lib/helyx/session/server/state.ex:47:3", from the new `compacted` field. Test: `summary_test.exs:145`, "Assertion failed, no matching message after 30000ms" with a nil pid, the race that master fixed in `0c523271` (#724). The branch is rebased onto `e7a3d6f6` for that fix. For Credo, `prepare_ms` and `open_ms` are one map `deadline_ms: %{prepare:, open:}`, with the same bounds (10,000 ms and 25,000 ms) and the same test seams. The Credo config does not change: the repo has no precedent for a raised limit. Simplify r3: the first home, `provider_ms.prepare`, mixed the provider process deadlines with the session deadlines, so the map is its own field; the reader's compaction fold makes one map update.

Bounds sensor (base `e7a3d6f6`):

```
bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Reproduced defects | Resolution |
|---|---|---|---|
| Codex adversarial | 0 (approve) | 0 | n/a |
| Standards | 0 hard, 7 judgement calls | 0 | not applied |
| Spec | 2 test gaps | 0 | not applied, gaps from before #712 |
| Failure path | 1 | 0 new | the stated ceiling |

1. **Failure path: an entry from before #712 after an interrupted result gives 40/165 at a resume, 40/0 live.** This is the ceiling in `usage-and-limits.md`, "Known ceilings". New entries carry `last_id`; only old files with a compaction after a resume with an open call show it.
2. **Spec: the seam tests of the prepare and the open deadlines wait 30,000 ms**, more than the defaults, so a seam that the code ignores passes, only slower. Timed runs: 2,045 ms, 2,068 ms, 2,133 ms, so the seams reach the field. The gap was there before #712.
3. **Standards (judgement), not applied:** `start_held` in `lock_test.exs` repeats the prepare default (it could merge into `state.deadline_ms`); `deadline_ms` next to `provider_ms`; the term `compacted` (see round 2); the reader does not check `last_id` against the ids (an unknown id gives the last usage, the same as the stated ceiling); `of/1` stays for the test callers; no test of a summary entry from before #712.

The third round reproduced no new defect, and it is the last round, so the loop ends.
