# 2026-10-15 The first orchestrate run with Helyx workers

This was the first `/orchestrate` run on the skill text of #578: every worker was a `helyx -p` session from the worker install, `0.1.0+ad87a11`, in its own worktree, on `claude-code/opus`. The queue was the seven tickets that the triage of the same day made ready.

## Merged

| Ticket | PR | What |
| ------ | -- | ---- |
| #597 | #602 | a `mix` command in the `bash` tool of the release boots the right `erl` |
| #571 | #603 | each plugin checks the keyword shape of its own Req options |
| #587 | #607 | waiting background ends are bounded by the 16 places; no stale hold |
| #566 | #609 | the usage of a background sub-agent is probed; both gaps are ceilings |
| #562 | #610 | three flaky tests: the bash limit test, the prepare Task monitor, the watchdog group |
| #589 | #611 | the session server takes its own writer lock |
| #595 | #613 | `turn_end` waits for the cleanup while a Helyx call runs |

No ticket was parked.

## Escapes

The rows of the run are in `docs/reviews/escapes.md`. The Codex gate approved every ticket in round 1, so no row needed a system change. The `/ship` loops found these defects before the gate:

- #571: two findings on one name check against `Req.new().registered_options`; round 3 removed the check and kept the keyword shape.
- #562: the new bash limit test queued its output before the deadline, so it passed with no deadline check.
- #595: a client that subscribed while `turn_end` was held got a snapshot with no turn, then a `turn_end`.

## The Helyx worker path

What worked: the separate worker install (`.git/orchestrate/helyx`), `< /dev/null` on every run, follow-ups through `--session`, and the gate as a background bash run. No worker run hung at its start, and no worker lost its build.

What broke:

1. The workers started the `/simplify` agents as background agents, the Agent default, although the brief said "in the foreground". Each worker found it and ran them again in the foreground. The common brief now names `run_in_background: false` on each Agent call.
2. The worktree setup of the skill fetches the deps of the root and of `plugins/bundled`, not of `apps/coding_agent`. The orchestrator fetched them by hand for #566 and #595.
3. The #571 worker probed the Req options with a fake key and sent two real requests to opencode.ai before it used a Req plug. The rule against network requests is in the review briefs only.
4. Not Helyx: `mise exec` in `/tmp` fails, because no tool-versions file is there; Codex runs read-only and runs no tests; the `flock` wait on the precommit host was up to 256 s; `erl_child_setup: failed with error 32` is harmless (#562 shows it).

## Tickets filed

- #604: token sums from the `modelUsage` difference, to count sub-agent calls (the option for gap 2 of #566).
- #605: a session start waits for another session's init (#589).
- #606: a lock lost before the first subscribe reaches no client (#589).
- #608: a crash right after the TUI start shows noproc, not its reason (#562).
- #612: the lock test of #589 resumes before the session init takes the lock. It failed once in the #595 precommit; `Session.pid/1` is set before `init/1` takes the lock.

The flake "the provider_down in the wait after an abort ends its open steer requests" (`provider_process_test.exs`) is a comment on #562.

## Assumptions

The owner started `/orchestrate` after the triage and asked for no questions. These decisions were taken without the owner:

1. Triage: #597, #589 (the lock in `init/1`), #587 (a place is held until a turn takes the end; the crash folder is a hole; `give_back` holds only when no turn is open), #595 (the cancel before `turn_end`, blocked by #587), #562, #566 (ceilings), and #571 (each plugin checks its own key) became ready-for-agent. #593 and #598 are needs-info. #563 stays a proposal.
2. #571: the check runs at each model call, not at the app start, the same as #560.
3. #566: the option for gap 2 became ticket #604, not a park.
4. #589: the supervisor waits for each init (accepted, #605); the lost lock before the first subscribe is #606; the `already_started` hard-link mapping and the removal of `hibernate_after: 0` were accepted.
5. #562: no reduced round ran after the rebase: the master changes in the shared modules `turn_loop.ex` and `wait.ex` were comments only. The TUI noproc race became #608.
6. #571: the precommit after the rebase failed once on the known flake `provider_process_tools_test.exs:122`; one rerun passed.
7. #589: the precommit after the rebase failed once on `bash_test.exs:320`, the test that #562 fixes. The orchestrator merged #562 first and ran the #589 precommit again on top of it, instead of a plain rerun.
8. The orchestrator fetched the deps of `apps/coding_agent` in the worktree setup, which the skill text does not say.
9. #595: the worker implemented the cancel before `turn_end` (option 1). Its accepted hole stays: when the hands handle the start answer first, the background run lives although the model got `aborted` for that call, and print mode waits for it. Option 2 of the ticket, or a kill of such a run, is the next step if the owner does not accept the hole.
10. #595: after the rebase on #562 and #589, the worker ran a reduced round, because both merges changed modules of its change (`wait.ex`, `session.ex`).
11. #612 got `needs-triage`, not `ready-for-agent`, so this run ends without one more worker.

## Next

- The skill text: the worktree setup fetches `apps/coding_agent`, and the brief names `run_in_background: false`. The `mise exec -- mix` line can go after the next worker install, which has #597.
- Triage #604, #605, #606, #608.
