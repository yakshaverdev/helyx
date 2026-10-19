# Review: a failed watchdog start drops its watchdog hold (#802)

Scope: the working tree against the branch base `934c973d`. Files: `plugins/bundled/lib/helyx/watchdog.ex`, `plugins/bundled/test/helyx/tool/bash_test.exs`, `plugins/bundled/test/helyx/harness_io/path_test.exs`, `docs/features/tool-resource-release.md`, `docs/features/coding-agent.md`.

Invariant: a `Helyx.Watchdog.start/4` that returns `{:error, reason}`, because the watchdog could not start the command or gave no marker, closes the port and drops its `{:watchdog, os_pid}` hold with `Helyx.Tool.unhold/1` only when `Helyx.Watchdog.Group.release/4`, with a deadline of 100 ms, confirms the watchdog group gone. The success path does not change.

## Decision

- The ticket decides: the error paths release the hold after the port is closed and the watchdog is gone, by rule 9 of `docs/features/tool-resource-release.md` (unhold only what the release confirmed).
- The release is in `Helyx.Watchdog.start/4`, which both callers (the bash tool and `Helyx.HarnessIO`) share, so one change covers both.
- The deadline is 100 ms, not the 500 ms of the release at a harness launch: the wait is part of the bound of a launch (the 2,000 ms reply bound in a turn), after the 1,000 ms exit wait and the 500 ms release of the program before. A watchdog that read to its exit status is gone at the first probe; one that gave no marker ends at the end of its stdin (`watchdog.pl`, the read of the go-ahead).
- Found while testing: the PATH of `path_test.exs` has no kill(1), so `System.cmd/3` raised `:enoent` in the start, and a failed start crashed instead of returning its reason. PATH is config, a boundary. The release in the start rescues `ErlangError` and returns every handle as still held, as a raise in the release of the hands counts as unconfirmed (rule 3).

## Simplify

One agent. No change: a shared helper with `Helyx.HarnessIO.let_go/1` would save about two lines in each place and edit a file outside the ticket.

## Round 1 (full)

Bounds sensor (`--diff 934c973db60b5888f36c629b0c8b7fa599e2deaf`):

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | needs-attention, 1 medium: the 100 ms is not enforced while a kill(1) run is running; a kill shim that sleeps 250 ms made the failed start take 286 ms | the deadline holds as `Group.release/4` states it: no kill(1) run starts at or after it. The release at a harness launch (`Helyx.HarnessIO.let_go/1`) runs inline in the same way, and `Helyx.Tool.Bash` states that a kill(1) run has no timeout of its own. Fixed (wording): the bullet and the Bounds row say "a deadline of 100 ms" and that a run that started before it is waited for; accepted hole below. The reproduction needs a kill(1) on PATH that stalls |
| Failure path | the same as Codex, as a doc finding (a kill shim that sleeps 1 s: 1,028 ms). Cells that held: a preamble over the limit with a live watchdog (hold dropped in about 33 ms, three runs), an argv of 1.1 MB and 3 MB (no marker, no held handle), a missing working directory, a fake perl that stays (hold kept), no KILL within the deadline | fixed (wording), as above |
| Standards | judgement: `let_go/2` repeats the shape of `Helyx.HarnessIO.let_go/1`; the name | kept: a shared helper edits `harness_io.ex` outside the ticket; the name is the same because the job is the same (release, then unhold the confirmed handles) |
| Standards | the `rescue ErlangError` is a case-specific handler with no evidence of a real case, and it covers `close/1` and `unhold/1` too | narrowed: the rescue is on the release call only and returns every handle as still held. Kept: the state is reachable through PATH (config), and a failed start must keep its reason; the existing `path_test.exs` reached it |
| Standards | the new bash test repeats the setup of the test above it; `kill` computed in `setup` for every test | kept: the test name states the guarantee of #802 |
| Standards | the repeated-step rule of the checklist (run the step three times) | not applicable: a failed start ends its owner. The provider process stops on a failed launch (`Codex.init/3`, the Claude relaunch), and a bash Task runs one start |
| Standards, Spec | guarantees with no test: a watchdog not gone by the deadline keeps the hold; the release never KILLs it; the start still returns its reason | fixed: test "a watchdog that is not gone by the deadline keeps its hold and is not signalled" (`path_test.exs`) |
| Spec | the Bounds row said the wait is part of the 2,000 ms reply bound; a Codex `init/3` is bounded by the 30,000 ms connect kill | fixed (wording): the row names both bounds and `docs/features/session-lifecycle.md` |
| Spec | the ownership tables did not name the failed-start release | fixed: the watchdog rows of `tool-resource-release.md` and `coding-agent.md` |
| Spec | the comment of the rescue says kill(1) not on PATH, the rescue takes any `ErlangError` | fixed (wording): "a kill(1) that cannot run, such as one not on PATH" |

Spec guarantee table (round 1, with the round 1 fixes):

| Guarantee | Proof |
| --------- | ----- |
| a start that did not start the command (marker `0`) drops the hold | `plugins/bundled/test/helyx/tool/bash_test.exs:131` |
| a start with no marker, the watchdog exited, drops the hold | `plugins/bundled/test/helyx/harness_io/path_test.exs:45` |
| a watchdog not gone by the deadline keeps the hold, is not signalled, and the start returns its reason | `plugins/bundled/test/helyx/harness_io/path_test.exs:57` |
| a kill(1) that cannot run keeps the hold, and the start returns its reason | `plugins/bundled/test/helyx/harness_io/path_test.exs:74` |
| a no-marker watchdog that still runs ends at the end of its stdin | `plugins/bundled/test/helyx/tool/bash_preamble_test.exs:55`; failure-path probe: hold dropped in about 33 ms |
| no kill(1) run starts at or after the deadline | `plugins/bundled/test/helyx/watchdog/group_test.exs:150`, `:159` |
| the port is closed | spec probe: the port count did not grow |
| the success path does not change | the `{group, pre}` clause is not in the diff; `watchdog_test.exs` passes |

## Round 2 (reduced: spec and failure path)

No snapshot of round 1 was taken, so both agents read the whole change against the branch base, with the round 1 fixes named.

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Failure path | no reproduced defect. Cells: the round 1 reproduction passes; the not-started branch with no kill(1) returns its reason and keeps the hold; an argv of 3 MB and a working directory that is multibyte, has a newline, or is 100 KB give valid UTF-8 and drop the hold; three failed starts in one Task leave `held() == []`; a fake perl that ends 0, 60, or 400 ms after the close drops, drops, and keeps the hold; a group whose leader exits while a child stays keeps the hold; the real watchdog with a 6,000-byte locale drops the hold and never holds `{:command, _}`; a kill(1) with a bad shebang returns status 2 and keeps the hold; no boundary check duplicates the rescue | none |
| Spec | the Ownership rows said the start "releases it and drops the hold", with no condition; a kill(1) that prints "Operation not permitted" kept the hold | fixed (wording): "when the release confirms it gone", in both rows |
| Spec | the comment of `start/4` said "within `@gone_ms`"; a kill(1) run of 300 ms that started before the deadline confirmed at 324 ms | fixed (wording): "a release with the deadline `@gone_ms`" |
| Spec | "no kill(1) run starts after it" says less than `Group`, "at or after" | fixed (wording) |
| Spec | a real watchdog that gave no marker and still runs drops the hold: probe only (30 ms), `bash_preamble_test.exs:55` checks the process | kept as a probe: an assertion of the drop there depends on the watchdog ending within 100 ms, a wall-clock upper bound with no margin |

The round reproduced no defect, so the loop ends.

## Accepted holes

- A kill(1) run that started before the 100 ms deadline is waited for: it has no timeout of its own. A kill(1) on PATH that stalls holds the failed start as long (Codex round 1: 286 ms with a 250 ms shim). The release at a harness launch has the same property.
- A watchdog that is not gone by the deadline keeps its hold until the end of the Task or of the provider process, as before #802.
- The tests `bash_test.exs:131` and `path_test.exs:45` assert `held() == []`, so they need the first probe to start within 100 ms of the deadline computation. Only BEAM code runs between the two, so the margin is 100 ms over microseconds of work; no window was found that holds it open (the failure-path agent of round 2).
- The drop of the hold of a no-marker watchdog that still runs has a probe only, no test (see round 2).
- `Helyx.Tool.unhold/1` waits behind a release of the hands, as `hold/1` does; the Bounds table of `docs/features/coding-agent.md` names only `hold/1`. Older than #802 (#651).
