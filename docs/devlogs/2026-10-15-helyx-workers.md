# 2026-10-15 Helyx builds Helyx: the run of #576 to #578

The goal of this run was the first ticket built by a Helyx worker (#578). The tickets of 14 and 15 October gave print mode what a worker needs, and #592 was the probe: a real ticket, built by `helyx -p` in its own worktree, through `/implement`, `/ship`, the Codex gate, and the merge.

## Merged

| Ticket | PR | What |
| ------ | -- | ---- |
| #576 | #580 | a `workdir` argument for `bash` |
| #574 | #582 | print mode continues a session with `--session` or `--resume` |
| #581 | #583 | the newest-session resume skips a file whose name is not a session id |
| #585 | #586 | the newest-session resume skips a header that the list skips |
| #577 | #588 | background `bash` runs whose end wakes the session |
| #579 | #590 | one process at a time per session, a writer lock |
| #584 | #594 | a resumed tool call that was running says it may have run |
| #591 | #596 | print mode waits for its background runs (a Core count) |
| #592 | #599 | tests wait for messages of other senders; the probe of #578 |
| #578 | #600 | `/orchestrate` starts workers as Helyx print sessions |

No ticket was parked.

## Escapes

The rows of #576 to #592 are in `docs/reviews/escapes.md`. Codex confirmed a finding at the gate once in the run: #579, a FIFO at the lock path left one `perl` process per retry. The system change was a rule in `docs/agents/review-checklist.md`, "Boundaries": a path that is opened on disk is boundary input together with its file type. The class of #592 (an `assert_received` of a message from another sender) came a second time after #577; `AGENTS.md` now states the rule. A Credo check cannot see the sender of a message, so the rule stays prose.

## The probe (#592)

The worker ran as `helyx -p "<brief>" --model claude-code/opus` in `.claude/worktrees/helyx-592`, with the build `0.1.0+12e5cbc` from `mix helyx.install`. It needed one follow-up on its session. It committed a reviewed change, precommit passed with the slow tests, and the Codex gate approved it in round 1. `helyx: waiting for background runs: 1` on stderr showed the wait of #591 in a real run.

What broke in the Helyx path:

1. The worker started the four `/simplify` agents as Claude Code background agents and waited with `ScheduleWakeup`. The turn ended, print mode exited 0, and the session stop ended the agents. Print mode waits only for Helyx background runs; under #578 the background agents of a harness stay unsupported. Fix: the worker brief and `/ship` say to run every agent in the foreground. #598 makes print mode exit 1 in this case, so the caller sees it.
2. `mix test` in the `bash` tool failed at boot: `cannot get bootfile '~/.helyx/releases/12e5cbc/bin/start.boot'`. Measured cause: the release VM puts its own `erts/bin` and `bin` at the start of `PATH`, so a child `mix` runs the release `erl`. #597. Until then, the brief says `mise exec -- mix`.
3. The follow-up run waited before its first turn and never started the harness. Its stdin was the socket of the background command, which is not a terminal and never ends, so print mode read it as piped input. Fix: the orchestrate text gives `< /dev/null`. The first run had the same stdin and did not wait; the difference is not measured.
4. Not Helyx: `gh issue view 592 --comments` prints nothing with no comments and no terminal; the Codex review in `/ship` runs read-only and runs no tests; the precommit lines `erl_child_setup: failed with error 32` are older than this run.

The worker ran about 55 minutes, over the 45-minute limit of `/ship`; its last review round had ended before the commit.

## Tickets filed

- #587: holes of background runs (by the #577 worker).
- #589: the race of the session lock ownership.
- #593: aborted results of a dead harness.
- #595: a background start answer can come after `turn_end`.
- #597: a `mix` command in the `bash` tool of the release boots the release `erl`.
- #598: print mode exits 1 when a harness turn ends with background agents.

## Assumptions

The owner asked on 2026-10-15 to finish the batch with no questions and to take the recommendation everywhere. These decisions were taken without the owner:

1. #591, round 4: a start answer after `turn_end` (all three reviewers) is an accepted hole with ticket #595, not a fix in this ticket. Reason: no known provider ends a turn while a Helyx tool call is open, and the fix changes the order of `turn_end` and the cleanup in Core, a design change of its own. #595 recommends the cancel before `turn_end`.
2. #591: the worker added the `waiting` count, which the owner decision did not name. Kept: without it print mode exits 0 at `turn_end` and loses an end that waits for a turn.
3. #591: the merge used the worker's precommit run on the same base, with only a docs commit after it.
4. #592: the open review items 4.2 (one site checks the release and the death of `proc` after two waits) and 3.4 (no check of the interrupt at the return of the abort) stay open without a ticket: they make a check weaker, not a test that fails at random. The `refute_received` race is out of the ticket's scope and has no ticket.
5. #592: the worker's scope (the harness stop tests in `plugins/bundled`, the `Helyx.Test.Released` record, the rule in `AGENTS.md`) was accepted as it was.
6. #592: the worker ran on `claude-code/opus`, the model of the orchestrator, as the #578 decision says for a brief that names no model.
7. #578: the probe findings changed the skill text directly (foreground agents, `< /dev/null`, `mise exec -- mix`, an install before the first worker); #597 and #598 got `needs-triage`, not `ready-for-agent`.
8. The orchestrator stopped the stuck follow-up run with SIGTERM (status 143) and started it again with `< /dev/null`.
9. #578: the Codex review of the skill text found twice that an install deletes the build of a live Helyx process (a worker, then the orchestrator). After the second finding on one mechanism, workers got their own install prefix in the git common dir, installed once per run; round 3 approved. The install into that prefix was run once, from `aa41c48`, to check the commands.
10. This devlog and the `/orchestrate` text went in without a question to the owner, as the roll forward asked.

## Next

- Triage #587, #589, #593, #595, #597, #598, and the older #562, #563, #566, #571.
- The first `/orchestrate` run with Helyx workers, on the new skill text.
