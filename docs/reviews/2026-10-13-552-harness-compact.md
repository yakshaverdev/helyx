# Review: #552 `/compact` and the compaction line for the harness providers

Invariant: `Helyx.Session.compact/2`, and `/compact` in the TUI, start one compaction turn: at once when idle, after an abort with no retry during a turn, and at the end of a wait in a wait. A second request while one runs or waits gets `{:error, :turn_running}`, and an abort drops a waiting one. The provider gets `{:compact, turn_id, instructions}`. A provider that keeps no history of its own (`Helyx.Provider.Loop`) answers `:unsupported`, and the session shows a notice and ends the turn `done`. Claude Code writes the user line `/compact` with its own `uuid`, drops every model line of the compaction turn, and fails on a `compact_error`. Codex sends `thread/compact/start` and takes the turn id of the next `turn/started`. A fresh program or thread fails at once and writes nothing. Each compaction event has counts from 0 to 10^9 or nil, is written to the session file as a `compaction` entry that a resume skips, and is emitted with the trigger `manual` in a compaction turn and `auto` in any other turn. A compaction turn that ends `done` with no compaction event fails. No `/compact` user message enters the transcript: a message event that a provider sends in a compaction turn is recorded as in any turn, and both bundled providers send none. A steer in a compaction turn waits in the steer queue for the next turn.

Accepted (feature doc): an interrupt of a compaction turn is not verified on either program, and the reply kill of 2 s bounds it. Codex takes no instructions. A resumed session shows no compaction line. `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is not set (#558). The cost of a compaction is #557. The Helyx summary is #490.

## Round 1 (full)

Simplify (4 agents):

- Fixed: the two copies of `no_history/0` are one, `Helyx.HarnessIO.no_history/0`.
- Fixed: Claude Code no longer fails a compaction turn with no boundary by itself. Core does it for every provider (`Compaction.outcome/2`), so one failure has one text.
- Fixed: the field of a waiting compaction in `State` is `pending_compact`, so it does not read as the plugin field `compaction`.
- Rejected: narrow the `close_last` guard to `:reported`. The notice path of a provider with no history ends the turn `done` with the instructions still in the field; the narrow guard added an empty assistant message (the test `a provider that keeps no history answers with a notice` failed). The comment now says so.
- Skipped: a `request` field on `Turn` in place of `compact`, and a `compacted?` boolean (altitude 1 and 2). A redesign of the turn for one more kind; `turn_loop.ex` is at the line limit. Judgement call, kept.
- Skipped: one `translate` clause per `system` subtype in `claude_code.ex` (altitude 5, efficiency 1). `Turn.compaction/2` matches the subtypes; the other `system` clauses sit above it. `claude_code.ex` is at its allowed count.
- Skipped: remove `min(n, 10^9)` in the view model. A bound that the docs state also holds in the render path.
- Skipped: build the compaction turn through `begin_turn/2`. It takes texts and appends user messages; the compaction turn has none.

Bounds sensor (after simplify):

```
bounds sensor: 15 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | standards | The Claude Code paragraph of the feature doc said that a `result` with no boundary ends the turn with `{:compaction_failed, text}`; after simplify the provider ends it `done` and Core fails it | Fixed: the paragraph says both cases |
| 1.2 | standards | The trimmed `steer/2` @doc dropped "unless the turn aborts or fails first" | Fixed: the qualifier is back, at the same line count |
| 1.3 | standards, spec | Guarantees with no test: the compaction in the wait before a queued follow-up, the `manual` file entry, and the provider process that stays after `:unsupported` | Fixed: `test/helyx/session/compaction_test.exs:115` (order and the `manual` entry) and `:140` (the same provider pid). The steer that opens the next turn is in `:35` |
| 1.4 | standards | Judgement: eight `compact != nil` checks in five Core modules; one field holds instructions and a state (`Turn.compact`, the Claude Code `Turn.compact`, the Codex `State.turn`) | Kept: the same as simplify, altitude 1 and 2. Each check is one rule of the turn that every provider needs |
| 1.5 | standards | Judgement: `{:error, :turn_running}` comes only from a compaction that runs or waits | Kept: the name the ticket gives; the TUI text says what it means |
| 1.6 | standards | Judgement: the session file entry has no reader yet (Speculative Generality) | Kept: an owner decision of the feature doc, the record of the fact |
| 1.7 | standards | Judgement: the 10^9 bound in `Stream` and in the Claude Code `tokens/1`; `before, after_` travel together | Kept: a plugin cannot use the private guard of Core; the wire check gives nil, the Core check fails the turn |
| 1.8 | standards | Judgement: `turn_id` renamed `id` in the `need_context` clause | Kept: it keeps `turn_loop.ex` at 400 lines |
| 1.9 | spec | The protocol docs did not name `{:compact, ...}` and `:unsupported` (`one-provider-path.md`, `session-lifecycle.md`) | Fixed: the request list, the replies, the stops, the turn-state row, the stop rule, and the deadline row |
| 1.10 | spec | The research note said that the summary `user` line of `/compact` has list content; the manual runs have string content | Fixed: string content, list content in the automatic run. No effect on code: the provider drops every `user` line of a compaction turn |
| 1.11 | spec | The bounds row "Claude Code took 2.9 s and 8.9 s": 8.9 s was the automatic compaction | Fixed: 2.9 s and 2.3 s (the second manual run) |
| 1.12 | spec | The decision "the Helyx summary never runs on a session whose provider compacts its own history" has no mechanism | Fixed in the doc: no code checks it yet, because the only compaction plugin is the no-op `none`; #490 adds the check |
| 1.13 | spec | No test for the 2,000 ms reply bound of `{:compact, ...}`, for the Core side of an error answer, and for the TUI `:turn_running` notice | Accepted: the bound and the stop are the generic path of every request (`ProviderRequest`), tested for `{:turn, ...}`; the notice is one text clause |
| 1.14 | failure path | No defect reproduced. Probes: 50,000 generated inputs to `Command.parse/1`; a compaction in the wait before a follow-up; a steer in a failed compaction turn comes back in `:queue_dropped`; a tool request in a compaction turn. Duplicate check: `min(n, 10^9)` in the view model | Kept: a bound that the docs state also holds in the render path. Not reached: an interrupt of a real `/compact` on either program, a Codex `turn/interrupt` with no `turn/started`, instructions with new lines to the real program, a compaction with `set_model` in the wait |
| 1.15 | Codex | [high] A message event in a compaction turn is recorded, so a summary can enter the transcript | Rejected: the feature doc states the rule ("a provider that sends message events in it gets them recorded as in any turn"). The owner decision is about the `/compact` user message. Both bundled providers drop the model lines of a compaction turn, and the probes show no message item in a Codex compaction turn. The output is allowed by the contract, so it is not a contract break. The invariant sentence of the brief said more than the doc; the record above has the corrected sentence |

Guarantee table (spec review, with 1.3):

| Guarantee | Proof |
| --------- | ----- |
| `:ok`: a compaction turn, `turn_start` with `origin: :compaction` | `test/helyx/session/compaction_test.exs:35` |
| `:unsupported`: notice, turn `done`, the provider process stays | `compaction_test.exs:140` |
| `Helyx.Provider.Loop` answers `:unsupported` | `compaction_test.exs:140` |
| Count 0 to 10^9 or nil; another value is a bad stream event | `compaction_test.exs:171` |
| `auto` in any other turn, and the turn goes on | `compaction_test.exs:160`; `claude_code/compact_test.exs:128`; `codex/compact_test.exs:106` |
| Message events in a compaction turn are recorded | spec probe P9 |
| Idle: starts at once | `compaction_test.exs:35` |
| In a turn: abort, queues back, no retry | `compaction_test.exs:80`; spec probe P6 |
| In the wait: starts before the queued follow-ups | `compaction_test.exs:115` |
| A second compaction gets `:turn_running` | `compaction_test.exs:35`, `:80` |
| Invalid UTF-8 gets `:invalid_utf8` | `compaction_test.exs:187` |
| An abort drops a compaction that waits | `compaction_test.exs:96` |
| A steer is not sent, and opens the next turn | `compaction_test.exs:35` |
| The `:compaction` event has `manual` and the turn id | `compaction_test.exs:35`; spec probe P8 |
| `done` adds no assistant message | `compaction_test.exs:35`, `:140` |
| No compaction event: "the provider reported no compaction" | `compaction_test.exs:61` |
| A context request in a compaction turn is a bad action | `compaction_test.exs:72` |
| File entry (`manual` and `auto`), and a resume skips it | `compaction_test.exs:115`, `:194` |
| Claude Code: `/compact <instructions>` with its own `uuid` | `claude_code/compact_test.exs:53` |
| Claude Code: the boundary gives the counts | `claude_code/compact_test.exs:53`, `:128` |
| Claude Code: summary, `Compacted`, and assistant lines dropped | `claude_code/compact_test.exs:53`, `:77` |
| Claude Code: `compact_error` gives `compaction_failed`, cut by the cap | `claude_code/compact_test.exs:77`; spec cap probe (200,000 bytes to 2,000) |
| Claude Code: no boundary and no error ends `done` | `claude_code/compact_test.exs:96` |
| Claude Code: a lost session fails the compaction | `claude_code/compact_test.exs:115` |
| Fresh program or thread: fails, nothing written | `claude_code/compact_test.exs:105`; `codex/compact_test.exs:55` |
| Claude Code: a count outside the bound is nil | `claude_code/compact_test.exs:147` |
| Codex: `thread/compact/start`, instructions dropped, `:ok` at its result | `codex/compact_test.exs:33` |
| Codex: the turn id comes from `turn/started`; an interrupt waits for it | `codex/compact_test.exs:66` |
| Codex: an error answer fails the request | `codex/compact_test.exs:89` |
| TUI: `/compact` calls the session, the composer clears | `plugins/bundled/test/helyx/tui_test.exs:1253` |
| TUI: `/compactly` shows usage and sends nothing | `tui_test.exs:1266` |
| TUI: the line text, at most about 40 bytes | `plugins/bundled/test/helyx/tui/view_model_test.exs:570` |
| Research: the Codex and Claude Code facts | the probe logs of 2026-10-13: match after 1.10 and 1.11 |

Round 1 reproduced no defect, so the loop ends. The fixes after the round are doc text, one @doc qualifier, and tests.

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh` passed after the round. The first run failed on two Credo alias orders (`stop.ex`, `compaction.ex`); the fix moved one alias line in each file.

## Gate fix: resume after a compaction

The Codex gate of round 1 on `32ec8e9` found that an abort, then `/compact`, then a reconnect started a fresh program and lost the native summary. The owner decided that a successful native compaction after the last assistant message makes the program's history safe to resume. The rule is derived on read from the transcript and the compaction records. The accepted limit is in the feature doc: the reply that the abort cut may not be in the summary.

Invariant: after a successful native compaction, a reconnect resumes the program's compacted history, and with no compaction since an abort or failure, it still starts fresh.

## Round 2 (full)

The fix against `32ec8e9`: 89 code lines in 5 files, with new functions (`Transcript.compacted/3`, a new `resume_entry/2` clause). A full round.

Simplify (4 agents): fixed, the label has one shape, `{id, before, at | nil}`, in place of a 2-tuple and a 3-tuple.

Bounds sensor (base `32ec8e9`):

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | Codex | [medium] The compaction branch of `resumable/3` skipped the check that the last assistant message came from that provider: a provider switch, a compaction, and an abort before any output resumed the new provider | Reproduced. Fixed: the provider check is in both branches, and a compaction lifts only the abort and failure check (`transcript_test.exs`, "resumes after a compaction with no assistant message after it") |
| 2.2 | spec | Test (b) also passes before the fix | Kept: (b) is the check of the path with no abort that the owner asked for. A new resume id in a compaction turn is not reachable: a fresh program answers a compaction with `no_history` |
| 2.3 | standards | `File.append_compaction/5` @doc and a test title said "a resume skips it" | Fixed: a resume adds no message for it, and reads it for the resume id |
| 2.4 | standards | A long feature doc sentence; an unclear "it" in `records.ex`; a wide comment line in `branch.ex` | Fixed |
| 2.5 | standards | Judgement: the rule is applied in two places, the file reader and the memory records | Kept: both call `Transcript.compacted/3`; the `before` count follows the same pattern |
| 2.6 | standards | Judgement: `Records.compaction` uses `turn.model.provider`, `resume_id` uses `conn.model.provider` | Kept: both name the provider of the current turn |
| 2.7 | failure path | Not a finding: Core gives a compaction to the provider's last label without a check that the current provider process runs under it | Not reachable with the bundled providers: a fresh program answers a compaction with `no_history`, and a model turn sends the resume id before any other event. No real provider does it, so no special handler |

Guarantee table (spec review):

| Guarantee | Proof |
| --------- | ----- |
| An abort, then a compaction: the resume id is used (memory and file) | `test/helyx/session/compaction_test.exs:247` |
| An idle compaction: the resume id is used | `compaction_test.exs:258` |
| An abort with no compaction: start fresh | `compaction_test.exs:267`, `test/helyx/session/transcript_test.exs:144` |
| A reply after the compaction that an abort cuts: start fresh | `compaction_test.exs:276`, `transcript_test.exs:153` |
| A compaction does not lift the check of the provider that answered last | `transcript_test.exs:153` |
| A compaction of a provider with no label changes nothing | `transcript_test.exs:153` |
| `Branch.resume_ids/2` reads compaction entries | `compaction_test.exs:247` (through the reconnect) |
| A fork drops the labels, also after a compaction | `test/helyx/session/file_test.exs:462`; a compaction with no label changes nothing (`transcript_test.exs:153`) |

Round 2 reproduced a defect (2.1), so round 3 runs.

## Round 3 (full)

The fix against round 2 (2.1 and the wording of 2.3 and 2.4): 32 code lines in 4 files. It removes the helper `answered?/3`. A full round.

Simplify (4 agents): no finding. Reuse noted that `[:aborted, :error]` is also in `stream.ex`; kept, two uses.

Bounds sensor (base: the round 2 tree):

```
bounds sensor: 2 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | Codex | Approve, no finding | None |
| 3.2 | failure path | No defect reproduced. Probes: a changed model of the last message on disk, odd and multibyte model strings, a provider switch with a failed turn between the compaction and the restart. Not reached: a fork entry after a compaction entry, an auto compaction while a message is open, a failed file write | None |
| 3.3 | spec | The feature doc and the `resumable/3` comment said that a compaction lifts only the abort and failure check. It also makes the check of a message under the id unnecessary (probe: a fresh program, a turn aborted before its first message, a compaction) | Fixed in both texts. The behaviour is the owner decision: the compaction shows that the program has the history |
| 3.4 | spec | The "Init" text of `one-provider-path.md` did not say that the last assistant message must come from this provider after a compaction | Fixed |
| 3.5 | spec | No test that a new resume id in memory drops the compaction count | Fixed: `compaction_test.exs:292`. It fails when the label keeps the count |
| 3.6 | standards | Judgement: "lift" is a metaphor | Fixed in the texts of 3.3 |
| 3.7 | standards | Judgement: the label is a 3-tuple that `put_elem/3` changes | Kept: one writer, `Transcript.compacted/3`; small enough |

Round 3 reproduced no defect, so the loop ends. The fixes after the round are doc text and one test.

## Orchestrator gate

| Round | Finding | Resolution |
| ----- | ------- | ---------- |
| gate r1 (on `32ec8e9`) | Abort a reply, compact, reconnect: `Transcript.resumable/3` saw the aborted last message and started fresh, so the native summary was lost | Confirmed by a read of the code. Owner decision: a successful native compaction makes the history safe to resume. Fixed in `f8788c0` (rounds 2 and 3 above) |
| gate r2 (on `f8788c0`) | Abort, compact, then a second turn aborted before any reply text: the count equals the compaction point, so the id resumes | Rejected. An abort before the first reply text stores no assistant message. On master the same shape without a compaction resumes too (the last assistant message is clean and `count > before` holds), so the change adds no new path. The abort rule is about a stored partial reply. The gate sentence said "an abort" too broadly |

## Rebase on #557 (reduced round)

The branch was rebased on `origin/master` after #557 (the usage meter, PR #565). The conflicts were in `claude_code.ex`, `claude_code/turn.ex`, `codex/items.ex`, `transcript.ex`, the two research notes, and `escapes.md`.

- Claude Code `Turn.terminal/3` takes the turn and the meter. A `compact_error` gives `{:compaction_failed, text}` and keeps the meter. A compaction turn that ends `success` gives `done` with no usage and keeps the meter. Core still fails a compaction turn with no compaction event.
- The cost of a compaction: a probe of 2026-10-13 (research note, "The cost of `/compact`") showed that the `result` of `/compact` has every `usage` count 0, and that its `total_cost_usd` includes the compaction call. No message holds the usage of a compaction turn. So `Meter.done` does not run at the compaction: the mark stays at the last `done`, and the next `done` covers the compaction call once. Codex keeps the token sum of a compaction turn the same way (`Items.compact?`). The rule is in the feature doc and in `usage-and-limits.md`.
- `Transcript.resume/3` reads the label with three fields.
- Both research notes keep both sections.

The invariants of the brief: the #552 invariant above, and the #557 invariant that the cost of each done covers only the model calls since the previous done of the same Claude session.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| R.1 | spec, failure path | The rebase committed conflict markers in `harness-compaction.md` | Fixed in the commit that had them; no marker is in the history of the branch |
| R.2 | spec | `usage-and-limits.md` said that each `done` starts a new sum and moves the mark; a compaction `done` does neither | Fixed: one sentence that names the compaction `done` |
| R.3 | spec | The accepted limit was wrong for Codex: its sum lives in the provider process | Fixed in the feature doc |
| R.4 | spec | No test for a failed turn, a compaction, and a reconnect | Fixed: `plugins/bundled/test/helyx/provider/claude_code/compact_test.exs`, "after a failed turn, a compaction, and a reconnect, the first done has both costs" |
| R.5 | failure path | A program turn queued behind `/compact` (`queued_turn_count` above 0 at its `result`) is dropped with the compaction turn's lines, and a reconnect then resumes a program with a reply that no message holds | Accepted, not fixed: no run has shown a positive count at a `/compact` result, so it gets no special handler. It is the class of the accepted ceiling of #240, where a program turn that the busy session drops is in no message |

Tests of the cost rule: `compact_test.exs` (Claude Code), "the cost of the compaction call goes into the next done" and the two reconnect tests; `plugins/bundled/test/helyx/provider/codex/compact_test.exs`, "the token counts of the compaction turn go into the next done". Each fails when the meter or the sum is reset at the compaction.
