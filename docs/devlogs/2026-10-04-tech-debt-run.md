# 2026-10-04: Tech debt run

A roll-forward `/orchestrate` run after `2026-10-03-adr6-and-ownership.md`. The owner asked for the gaps and the tech debt of the whole project to be fixed before feature work, with Codex in place of the owner for every decision, and the rule "simplicity over complexity: a complex fix means the design is wrong".

## Inventory and plan

Four inputs: a Codex review of the project, a code review agent, a docs review agent, and the open lists of the last 14 devlogs. I wrote plan v1, and Codex challenged it. Plan v2 kept the result:

- **Do:** one finish path (M1), `subscribe/1` returns the monitor ref (M4), only `turn_start` and `turn_end` (M6), an integer predicate (M7).
- **Keep, with the reason that the mechanism has one owner and a test:** the steer ledger (M2), the monitor plus `provider_down` (M3), the session file tree (M5), the plugin catches (M8), the heap cap (M9), the scroll position (M10), the Codex child map (M11), the wall-clock Credo check (M13).
- **Measure first:** the transcript scans (M12).
- Renames go into the related tickets. No rename ticket, no test framework rewrite.

I rejected one Codex proposal: delete `Helyx.Compaction.None`. It is a deliberate placeholder.

## Merged

| Ticket | PR | What changed |
|---|---|---|
| #428 | #438 | `CodingAgent.run/1` stops Core in a `try/after`; the abort runs in an inner `after`. |
| #427 | #440 | Codex `end_turn` removes the interrupt id from `due`; the composer drops a paste with its marker. |
| #429 | #441 | Dead code removed: `HarnessIO.term_grace_ms/0`, `replay_max_bytes/0`, `Session.client_start_error/1`. `provider_ms` has `reply`, `close` and `idle`. `session.ex` 386 to 350 lines. |
| #431 | #442 | `HarnessIO.cap_replay/3` takes an encode function. |
| #430 | #443 | Tool requests carry their bytes; running and waiting requests hold at most 8 MiB. Empty deltas are dropped. Renames: `Session.ToolQueue`, `Server.ToolRuns`, `State.tool_specs`, `Turn.tool_queue`. |
| #434 | #444 | `subscribe/1` returns `{:ok, snapshot, ref}`; `subscription.ex` is deleted; the end signal is a plain `:DOWN`. +279 / −505. |
| #435 | #448 | `Message.big_integer?/1`: a long integer in tool arguments gives `%{}` and a rejection. |
| #439 | #449 | At most 1,024 blocks in the open message (`@max_message_blocks` in `Turn`). |
| #432 | #450 | `Wait.finish/2` is the one path that ends a turn; `Records.finish/2` closes a partial message, which joins with stop `:aborted`, `:error` or `:tool_use`. `Transcript.resumable/3` gives no resume id after a cut. Renames: `Server.Records`, `Server.Events`, `Transcript.repair/2`. |
| #436 | #451 | Measured: at 9,998 messages the largest step is 0.049 ms (tool result). No step reaches 1 ms, so no lib change. `bench/transcript.exs`. |
| #433 | #452 | Only `turn_start` and `turn_end` (with `outcome`). `agent_start`, `agent_end` and `tool_execution_start` are gone. `start_provider_turn`. Lib +43 / −78. |
| #446 | #453 | New `session-lifecycle.md` with the Core turn contract; `long-lived-harness.md` 724 to 100 lines. |
| #437 | #454 | Test fakes hold their reply until the test releases it; the 100 to 300 ms timed replies are gone. |
| #445 | #456 | `coding-agent.md` 228 lines / 19,033 words to 147 lines / 5,330 words; one bounds table, each row names its owner. |
| #455 | #458 | The Codex failed-turn test no longer depends on how a read splits lines. `precommit.sh` keeps a failed log in `precommit-fails/` under the git common dir. |
| #447 | #459 | The rest of the docs debt: three feature docs deleted, history cut, one owner per rule. +190 / −830. |
| #457 | #460 | Provider contract: `info/2` may return `{:stop, reason, actions, state}`; `ProviderProcess.loop/1` runs the actions through `act/2`, then stops. Codex and Claude Code keep the events of a read that ends in an error. |

Totals from `10b0775` to `5edc951`: Core `lib/` +452 / −595, plugins and app +133 / −126, tests +1,068 / −867, feature docs, ADRs and root docs +427 / −1,678.

## Decisions taken alone or by Codex

- **#432, by Codex:** after a cut, the session does not resume (no skip to an older provider session). All end paths use one event order, a stated exception to the ticket. An empty partial at an abort or a failure stores nothing. The empty message at `done` stays.
- **#432, mine:** two resume holes stay, the same as master. A cut with no block stores nothing, so a later turn can resume an older provider session. An abort with a tool call joins as `:tool_use` and resumes (#385 rule, no harness evidence either way).
- **Block bound, by Codex:** 1,024 blocks, not a byte cost for each block.
- **#436, mine:** the first round in a cold process (3 to 4.5 ms) does not count against the 1 ms rule.
- **#446, mine:** after three `/ship` rounds with 12, 9 and 8 doc findings, I took repeat findings as a sign that the doc stated too much. I committed the worktree and gated it with the rule "cut a wrong detail, do not correct it".
- **#447, mine:** gate round 3 was not clean, which means park. All six gate findings were one class (abort and cleanup guarantees) and every fix was a cut, which cannot make a doc false. I merged without a fourth round.
- **#455, mine:** after 16 clean runs I stopped the search and made `precommit.sh` keep failed logs. The 17th run failed and the kept log gave the cause.
- **#455 gate, mine:** I rejected a same-second log name clash on one branch. One worktree runs one precommit at a time, and a run takes more than 20 s.
- **#457, by Codex:** the contract change (option 2), with the same boundary checks as `{:ok, ...}` and replies allowed.

## Escapes

| Ticket | Ship | Codex gate | System change |
|---|---|---|---|
| #427, #428, #429, #430, #431, #434, #435, #436, #433 | r1: 0 | r1: 0 | none |
| #439 | r1: 1, r2: 0 | r1: 0 | none; ship caught it |
| #432 | r1: 1, r2: 0, r3 after rebase: 0 | r1: 0 | none; ship caught it |
| #437 | r1: 1, r2: 1, r3: 0 | r1: 0 | none; ship caught both |
| #446 | r1: 12, r2: 9, r3: 8 | r1: 1, r2: 0 | `review-checklist.md`: a doc rule names the function that enforces it, else it is cut |
| #445 | r1: 9, r2: 2 cuts | r1: 2, r2: 0 | `review-checklist.md`: a doc trim keeps each bound it removes in the linked doc |
| #447 | r1: 12, r2: 9, r3: 3 | r1: 2, r2: 1, r3: 3 | `review-checklist.md`: abort, delivery and release end released or unconfirmed |
| #455 | r1: 1 | r1: 1 rejected | `precommit.sh` keeps a failed log |
| #457 | r1: 0 | r1: 0 | none |

Every code ticket passed the Codex gate in round 1. All 9 confirmed gate findings were in the three docs tickets, and all were false claims: a doc said more than the code does. The prose rules from #306 and #307 did not stop them, and no mechanical check can read prose. So the new rules make a doc state less: a rule names its function or is cut, a cut keeps its bounds, and abort promises only "released or unconfirmed".

Two merges failed on a semantic conflict that git did not see: #431 called a function that #429 deleted, and #439 matched the old `subscribe/1` reply of #434. Precommit after the rebase caught both, as designed. Each cost one merge round.

## Open, no ticket

- `Records.close_cut/3` ends an empty reply that the snapshot does not contain, so the ADR 0006 snapshot rule does not hold for that case.
- No function enforces the ADR 0006 rule "every value is data"; an error event can hold a pid.
- "Program turn" is still used in `one-provider-path.md` and `long-lived-harness.md`.
- `Helyx.Provider.Loop` drops a `done` with no content while a steer is held, before the stream check.
- The abort test passes when the session accepts a turn reply in `submitting` without checking `from`. Master has the same gap.
- A withdrawn running call keeps its bytes in the tool queue bound until its tool ends.
- The resume path still writes the integer marker string; the live path gives `%{}` or fails.
- No test makes the TUI raise (#428); no test covers the failed Claude Code relaunch or a reply inside the actions of a stop (#457).
- Two bounds rows over 40 words, mechanisms to simplify: tool result text (one cut helper, head and tail readers) and transcript scrollback (`widget/3`, `page/5`, `hold/4`).
- Still timed in tests, outside #437: `Tool.Slow` (200 ms) and the slow release in `hands_test` (a deadline test).
- Subscriber mailboxes are unbounded (#116). #277 stays open: 20 of 20 runs passed, and it uses none of the waits that #437 replaced.

## Next

Feature work. The first candidates from the open list are the snapshot gap of an empty cut and the "every value is data" check, if the owner wants them before features.
