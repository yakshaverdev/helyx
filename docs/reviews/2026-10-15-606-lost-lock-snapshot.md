# Review: #606, the lost lock in the snapshot

Branch `ticket/606-lost-lock-snapshot`, base `origin/master` at 5c90d7e3. One round: it reproduced no defect, so the loop ended.

Invariant: a client that subscribes after the session lost the writer lock that it held sees the loss. `Helyx.Session.Snapshot.lock_lost` is true only after the `{:EXIT, port, _}` clause of the lock port. It is false for an in-memory session and for a session that holds its lock. The TUI (`ViewModel.from_snapshot/1`) ends with the notice cell, and print mode writes the notice text to stderr. A client gets the live notice or the snapshot flag, never both.

## Decisions

- The triage decision (`locked`, false also for a session with no lock) gave a false notice for every in-memory session: 20 TUI tests failed with the notice cell at mount. The worker stopped. The owner chose `lock_lost` (option 2) on 2026-10-15.
- The flag is a field of the session state, not derived: a failed write can change `file`, so `file != nil and lock == nil` does not prove a loss.
- The flag is set in the `:EXIT` clause only, with the notice in the same callback. If the exit-status clause set it, a subscribe between the two messages would get the flag and then the notice.

## Bounds sensor

```
bounds sensor: 1 candidate functions, 1 flagged, 0 without an answer
  apps/coding_agent/lib/coding_agent/print.ex:162  SIZE  def run(session, prompt) do
```

The flag is a false alarm for this diff: `run/2` gets one boolean check and no new read or buffer (failure-path agent).

## Simplify

| Finding | Resolution |
| ------- | ---------- |
| `_ = snapshot.lock_lost && stderr(...)` in the `with` of `Print.run/2` | fixed: a bare `if` clause |
| `Process.sleep(10) && ...` in `Helyx.Test.LostLock` | fixed: `unless` with two lines |
| The old lock test repeats the kill of perl | fixed: it calls `LostLock.kill/1` |
| The TUI added the notice in `mount/1`, outside `ViewModel.from_snapshot/1` | fixed: `from_snapshot/1` adds it, so a rebuild from a snapshot keeps it |
| `LostLock` copies `SessionCase.await/3` | skipped: the plugin and app builds do not compile `SessionCase`, and a move to `Helyx.Test.Events` clashes with the import of both modules in 11 test files |
| The notice text belongs in `Snapshot`, not `Helyx.Reason` | skipped: the owner accepted `Helyx.Reason.text(:lock_lost)` |
| Drop `lock_lost` from `@enforce_keys` | skipped: the compiler then no longer makes every snapshot set it |
| The test helper polls `:sys.get_state/1` | skipped: a subscribe of the test process would put the notice in the mailbox that `Print.run/2` reads |

## Round 1 (full)

Codex adversarial review: approve, no findings.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| standards | ADR 0006 section 3 edited with no revision mark | fixed: "(revision of 2026-10-15)" and a Revision entry |
| standards, spec, failure path | `git diff origin/master` shows #615 (`.claude/skills/orchestrate/SKILL.md`) reversed: master moved after the branch base | not in the branch; the rebase of the merge removes it |
| standards | Reason holds a notice text; each client repeats the `lock_lost` check | judgement call; the owner decision names both |
| standards | the snapshot literal is repeated in 10 test sites | judgement call; older than this diff |
| standards | `if` in place of function clauses | judgement call; kept, it matches the code around it |
| standards, spec | no test of the notice after existing cells | fixed: test in `view_model_test.exs` |
| spec | ADR 0006 "Reconnect" still says every notice is gone after a reconnect | fixed: the lost lock is named as the exception |
| failure path | the comment above `Lock.held/2` says the notice reaches no client | fixed: it names the snapshot |

The failure-path agent probed three orders with `:erlang.suspend_process/1`: the port exit before a queued subscribe (`lock_lost: true`), the subscribe before the exit (`false` and one notice), and 20 runs of a kill and a subscribe at once (always exactly one of the two). Not reached: a loss during `Lock.hold/2` on a slow resume read, an end-to-end TUI render, and repeated runs of the print test.

### Guarantee table

| Guarantee | Proof |
| --------- | ----- |
| `lock_lost` true after a loss, also before the first subscribe | `test/helyx/session/lock_test.exs`, "the snapshot says whether the session lost its lock" |
| false while the session holds its lock, and with no file | the same test |
| the TUI shows the notice text at its mount | `plugins/bundled/test/helyx/tui_test.exs`, "a session that lost its lock before the mount shows the lost-lock notice" |
| a snapshot with `lock_lost` ends with its notice, after the transcript | `plugins/bundled/test/helyx/tui/view_model_test.exs`, "a snapshot with a lost lock ends with its notice, after the transcript" |
| print mode writes the text to stderr | `apps/coding_agent/test/coding_agent/print_test.exs`, "a session that lost its lock before the run writes the notice on stderr" |
| the notice event text equals `Helyx.Reason.text(:lock_lost)` | spec agent probe |
| live notice or snapshot flag, never both | failure-path agent probes above |
| a resumed instance starts with `lock_lost: false` | spec agent probe |
