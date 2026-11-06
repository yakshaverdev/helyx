# Review: the log hold with no `:default` handler (#862)

Change: `CodingAgent.LogFile.run/2` no longer raises `MatchError` with no `:default` logger handler. With no `:default` the hold runs with no terminal handler to filter or drain, and the file handler writes with `Logger.default_formatter/0`. The state of the hold (the holder and the result of the open) moved from the drop filter on `:default` to `:persistent_term`, and a `filesync` whose handler process ends during the call no longer ends the run. Files: `apps/coding_agent/lib/coding_agent/log_file.ex`, its test, and `docs/features/coding-agent.md`.

Invariant: `run/2` never raises from a state of the logger handlers that a config or OTP can make, and keeps the state of the hold in one place that no logger call rewrites.

Bounds sensor, every round: `bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full: simplify, standards, spec, failure-path, Codex)

Design under review: the state stayed in the drop filter on `:default`, and with no `:default` it moved to a primary filter that keeps every event.

| Finding | Source | Resolution |
|---|---|---|
| A killed holder with no `:default` leaves its primary filter; `:default` comes back, then goes between the read and the add of the drop filter: the fallback adds the primary filter again, `MatchError {:error, {:already_exist, :helyx_tui_log}}` | failure-path (reproduced), Codex (reproduced) | Mechanism replaced in round 2: the state in one place in every case |
| The drain of `:default` exits when the handler process ends during the `filesync` call (an overload kill); the run ends and the TUI does not start | failure-path (reproduced) | Fixed: the gen_server call exit is caught |
| The state in two places, with five functions that branch on `:none` or a config | standards (judgement) | Gone with the mechanism change |
| The fallback for a `:default` that goes between read and add has no test | standards, spec | Gone with the mechanism change; a `:default` that has the drop filter already has a test |
| `pass/2` should be `keep/2` | standards (judgement) | Gone: no primary filter |
| A `:default` that a restart brings back with no drop filter writes to the terminal during the hold; the doc did not say | spec | Doc: accepted hole, needs the overload kill, off in the default config |

## Round 2 (full: simplify, spec, failure-path, Codex)

The mechanism changed, so the round was full. Design under review: the state always in a primary filter `:helyx_tui_log`.

| Finding | Source | Resolution |
|---|---|---|
| `:logger.remove_handler/1` writes back the primary config that it read at its start: a hold that starts or ends during it loses its primary filter, or gets a stale one back; a later run skips the hold, or raises `already_exist` at the add | failure-path (reproduced) | Second finding on the place of the state: the state moved out of the logger config, to `:persistent_term` |
| The `filesync` of the file handler at the close exits when its process ended (a file that fails, which the logger removes); the run raises, and each later run too | spec (reproduced), Codex (reproduced) | Second finding on `filesync`: one `sync/1` that catches the call exit, for the drain and the close; slow test in a VM of its own |
| The end order of the filters has no test | spec (minor) | Accepted: the order is read in the code |

## Round 3 (full: simplify, spec, failure-path, Codex)

| Finding | Source | Resolution |
|---|---|---|
| The doc said a call inside a hold "finds the filter" | spec | Fixed: "finds the state" |
| With `overload_kill_enable` on `:helyx_tui_log`, an OTP restart between the read of `open` and the add gives `already_exist`, `CaseClauseError` | Codex | Rejected: the hold builds the `config` map of `:helyx_tui_log` itself (`file`, `max_no_bytes`, `max_no_files`) and copies only the level, the formatter, and the filters of `:default`, so no config turns its overload kill on; the probe set it by hand |
| `:ok = :logger.remove_handler(@handler)` in `open` can raise when the logger removes a failing file handler between the read and the removal | spec (read, not probed) | Not reproduced; needs a hold on another path while the file handler fails |

The failure-path agent reproduced the three fixes of round 2 and found no other path. The round reproduced no reachable defect, so the loop ended.
