# 2026-10-15 Follow-ups of the orchestrate run

The follow-ups of `docs/devlogs/2026-10-15-orchestrate-helyx-workers.md`: the skill text fix, the triage of the five tickets that the run filed, and one more `/orchestrate` run on the ones that became ready. The workers ran on the worker install `0.1.0+d3ef5ff`, on `claude-code/opus`.

## Merged

| Ticket | PR | What |
| ------ | -- | ---- |
| none | #615 | the orchestrate skill: the worktree setup fetches the deps of every project, the brief names `run_in_background: false`, no probe sends a request to a real network service, and the `mise exec` rule goes |
| #612 | #616 | the lock test of #589 waits for the session init before the lock check |
| #606 | #617 | `Snapshot.lock_lost`: a client that subscribes after a lost lock sees the loss |
| #608 | #618 | a crash right after the TUI start gives its reason, not `noproc` |

No ticket was parked. Before the `mise exec` rule went, a print run on the new worker install ran a plain `mix run` in the `bash` tool with success (#597).

## Triage

- #612, #608, #606: ready for agent.
- #605: deferred until the Transport is designed. Only other session starts of one Core wait, and local mode has one user per node. The label stays `needs-triage`.
- #604: won't fix for now. An input sum that counts sub-agent calls next to an output sum that does not is harder to read than the documented ceiling. The ticket stays open.

## Escapes

The Codex gate approved every ticket in round 1. Two rows record a defect that came from the triage, not from `/ship`:

- #606: the triage rule "`locked` is false when the session has no lock" gave the lost-lock notice for every in-memory session. The worker implemented it, saw 20 TUI tests fail, and stopped. The field became `lock_lost`, true only after a loss.
- #608: the triage said that the `EXIT` message "is already in the mailbox". `Process.unlink/1` drops an exit signal that the caller has not handled yet, and the triage form still gave `noproc` in 50 of 20,000 runs. The worker added a status check before the unlink: 0 in 20,000.

Both workers did what the brief says: they checked the triage against the code and stopped or reported. A triage decision that names a mechanism is a recommendation that the worker checks, not a fact.

## What broke

1. Three workers (#595 of the run before, #612, #606) saw `origin/master` move during their work: the repository is shared, and a fetch by the orchestrator moves `origin/master` in every worktree. A Codex review with the base `origin/master` then shows a merged change as reversed. The workers used the merge base or `HEAD`.
2. The first Codex review of #615 ended with status 0 after two commands and gave no verdict. The cause is not known. The second run approved.
3. The orchestrator's worktree loop used `set -- $t`, which zsh does not split; three brief files had wrong names and were removed.

## Assumptions

The owner asked for step 1 with no questions. These decisions were taken without the owner:

1. The triage decisions above, including the won't-fix of #604 and the deferral of #605.
2. #606: after the worker stopped, the field became `lock_lost` (its option 2), and the triage comment was corrected on the ticket.
3. #608: the change of mechanism beyond the triage was accepted on the worker's measurement, and the ticket says so.
4. #606 and #608: no reduced round after the rebase. The merge before each changed only a test file of the change (`lock_test.exs`, `tui_test.exs`), no module.

## Next

- `/ship` and `/orchestrate`: run the Codex review with the base `$(git merge-base HEAD origin/master)`, not `origin/master`, so a moved master does not show as a reversal.
- `plugins/bundled/lib/helyx/tui.ex` is at the 400-line limit after #608.
- The next feature step: the triage of #551 (`/new` and `/resume` in the TUI) and #550 (an OpenAI-compatible provider) with the owner.
