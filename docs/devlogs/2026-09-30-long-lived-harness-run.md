# 2026-09-30: long-lived harness run

An orchestrate run from 2026-09-27 to 2026-09-30. It built the long-lived harness of ADR 0007 for Claude Code and Codex: connected turns, idle close, steers, the shared tool path, program turns, and notices. On 2026-09-30 the owner asked the run to roll forward without questions. So the last tickets ran in parallel, the review loops were capped, and every decision taken without the owner is in "Assumptions" below.

## Merged

| Ticket | PR | Change |
|---|---|---|
| #196 | #212 | The watchdog caps the open input that the command has not read |
| #197 | #213 | A turn fails when the session mailbox has more than 10,000 messages |
| #189 | #214 | End signal for subscribers |
| #211 | #215 | The TUI ignores a new value inside a known event type |
| #204 | #217 | Session instance id in events and the snapshot |
| #191 | #218 | Second-client contract test with the local transport |
| #199 | #220 | Long-lived harness process for connected providers |
| #193 | #223 | Watchdog tests assert properties, not tight times |
| #200 | #225 | Claude Code connected provider: turn, interrupt, stop |
| #228 | #229 | Only the block test gets a 300 ms turn deadline |
| #194 | #231 | Claude background tasks outlive the turn and end with the program (doc) |
| #195 | #232 | Idle close of the harness program |
| #227 | #233 | Local and external turns check the context of the plugins |
| #221 | #235 | Credo check for wall-clock upper bounds in tests |
| #219 | #236 | The session stops its hands before it ends |
| #201 | #237 | Codex connected provider on one long-lived app-server program |
| #226 | #238 | Research: sub-agents at the end of a turn |
| #234 | #239 | Codex stops at an `item/started` of an item that has a tool call |
| #202 | #242 | Steer delivery into the running turn |
| #224 | #245 | Codex ends sync work inside the turn; background child threads belong to the program |
| #244 | #247 | Codex: a late `subAgentActivity` item never moves a child to an older turn |
| #203 | #251 | Helyx tools inside Claude Code on a shared tool path (loop-owned queue, start ask) |
| #246 | #252 | Claude Code counts a turn's lines only after the start of its line |
| #241 | #253 | Provider notice event `{:notice, text}` |
| #248 | #254 | Claude Code replays each line after a user line at its result |
| #240 | #255 | Claude Code shows a turn that the program starts by itself |
| #243 | #256 | Helyx tools inside Codex as `dynamicTools`, on the shared tool path |

Process PRs: #222 (limits for the ship loop), #230 (precommit on a remote host), #249 (research on program turns), #250 (precommit isolation and the kill fix).

No ticket was parked. #192, the tracking parent, closed when its last child merged.

## Owner decisions

- #203: the fix of the queue race stays inside #203; the loop asks the session before a tool starts; one last small review round.
- #240: a program turn is a live, visible turn (Claude only; Codex never starts a turn by itself, 120 s probe).
- Probe notes of program turns: a research doc and a ticket.
- #248: probe, then fix.
- #192: keep as the tracking parent.
- The remote precommit runs in its own PID namespace.
- The address of the precommit host never goes in the repository.

## Incident: a precommit run froze the precommit host

A test sent `kill -STOP -<group>` with no `--`. procps-ng `kill` 4.0.4 read the group, which started with 1, as options and called `kill(-1, SIGSTOP)`. Every process of the host user stopped, and a precommit run waited 4 hours. All processes were resumed with `SIGCONT`. Fixes (#250): the test helper `signal_group/2` puts `--` first and refuses a group below 2; `os_helpers_test.exs` finds a negative kill target with no `--`; the remote run is in its own PID namespace, as the host user, under a root first process that keeps the kill-child signal, so no signal from a test leaves the run.

## Escapes

Tickets with a confirmed Codex finding:

| Ticket | Codex | System change |
|---|---|---|
| #189 | r1: 1, r2: 0 | Checklist: a barrier wait has no timeout that falls through to the act |
| #199 | r1: 1, r2: 0 | Checklist: a plugin value that ends a deadline is checked before the cancel |
| #200 | r1: 1, r2: 0 | Checklist: a value from outside that confirms a safe state is matched on the exact safe value |
| #221 | r1: 1, r2: 0 | Orchestrate lesson: a heuristic check lists its holes in the brief |
| #219 | r1: 1, r2: 0 | The gate sentence after a rebase names the new behaviour on master |
| #201 | r1: 1, r2: 0, r3: 0 | One full-shape check per method before any state change; a new request id per request |
| precommit safety | r1: 1, r2: 1, r3: 0 | `signal_group/2`, a scan test, a PID namespace with a root first process |
| #203 | r1: 1, r2: 0 (1 rejected) | The used-id rule moved into the `Helyx.Provider` docs for every provider |
| #241 | r1: 0, r2: 1, r3: 0 | The orchestrate skill asks for a reduced round on a branch rebased on a change to the same module |

All other tickets had no Codex finding in round one. #197 had one finding, rejected (a documented overshoot).

## Assumptions

Decisions taken without the owner in roll-forward mode, for review:

- Parallel starts: #241 and #246 started on the unmerged #203 head, #240 on the unmerged #246 head, and #243 on the unmerged #241 head. Each rebased before its gate.
- Review caps: at most two rounds after the first. An open finding that needs a program behaviour the research did not see became an accepted hole with a reproduction in the feature doc.
- #203 gate round 2: the limit finding was rejected. The doc says one call runs and 16 wait (17 open); the gate sentence had said 16 open.
- #246: a Helyx `tools/call` inside a program turn gets "no Helyx turn is running". A `claude` without `msg_lifecycle_v1` now fails every turn. The interrupt waits for `started` only after a replay. An error `result` before any `init` loses its text (accepted hole).
- #240: Claude only; Codex keeps `:turn_not_asked`, because the probe showed that Codex never starts a turn by itself. The provider uses one new UUID as the turn id and the `uuid`. A Helyx tool call in a dropped program turn waits until the next turn or a close. Eight accepted holes in all.
- #248: the probe proved the wrong order in the real request, so the fix was built without asking. A missing `origin` on a replay `result` counts as null (inferred from the research note).
- #241: a notice passes from local and external turns. The 2,000-byte bound is repeated in Core. A held success gives no notice. A program `result` whose `origin` is not exactly `task-notification` counts as a Helyx `result` (accepted hole).
- #243: follows the #192 decision: `dynamicTools` behind the `experimentalApi` check, and a notice when the tools are off. Any `initialize` error counts as a rejection of `experimentalApi` (source only, not seen). The stored thread id carries a digest of the tool set. The thread-id limit of 1 to 239 bytes also holds for a thread with no tools. No real probe ran.
- Reduced rounds by the orchestrator: the #241 fix after gate round 2 (the arity rule asked for a full round) and the #248 fix after the rebase on #246 (the size rules asked for a full round). Both then passed a clean Codex round.
- Rebases: #248 renamed its field to `Turn.chunks` after it met the #241 `Turn.held`. I resolved the #240 rebase on #248 myself (comments and doc sections, both sides kept); the worker then ran a clean reduced round.
- Flaky tests were rerun, not ticketed (see Next).

## Next

- The accepted holes of #240, #241, #243 and #246 are in `docs/features/long-lived-harness.md`; each has a reproduction.
- Two tests failed once under load and passed on rerun: `Helyx.Provider.FakeTest` "a bad script item fails only its own turn" (5 s wait) and a Claude Code abort test with a 5,000 ms lower bound. No ticket yet.
- GitHub did not close #203, #246, #241, #248 or #240 from "Closes #n"; they were closed by hand. Check the repository setting.
