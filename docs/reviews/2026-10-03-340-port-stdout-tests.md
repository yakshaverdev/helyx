# Review: two bundled tests that depended on how the port cuts stdout (#340)

Date: 2026-10-03. Base: `origin/master` at `3bf9aaa`. Scope: `plugins/bundled/lib/helyx/watchdog.ex`, `harness_io.ex`, `tool/bash.ex`, `provider/claude_code.ex` (a comment), `test/helyx/provider/codex/commands_test.exs`, and two rows of `docs/features/coding-agent.md`.

## Cause, measured on both machines

One `syswrite` of 855 bytes into a pipe, read by a perl `sysread` of 65,536 bytes after a 0.2 s wait, three runs each:

| Machine | Reads |
|----|----|
| macOS (local) | 512, 343 (also through `sed` and `cat`) |
| Linux (precommit host) | 855 |

The port reads the same kind of pipe. A probe in `HarnessIO.port_message/3` showed the Codex turn lines (5 lines, 867 bytes) as chunks of 512 and 355 bytes on macOS.

- `claude_code/turn_test.exs:25` got 493 bytes: 512 minus the 19-byte marker line. `Helyx.Watchdog.start/4` returned only the rest of the marker's chunk as the reason, and `HarnessIO.start/5` used it as is. The bash tool read the rest itself. Fix: `Helyx.Watchdog.start/4` reads the reason up to the exit status, for both callers.
- `codex/commands_test.exs:148`: the provider drops the events of the chunk that holds the stop. On macOS the start and the completion of the command are in two chunks, so the tool call went out. Fix: the test accepts exactly `[stop]` or `[tool_call exec-1, stop]`. The provider behaviour does not change (see "Open").

Each fixed test passed 20 of 20 local runs.

## Invariant

`Helyx.Watchdog.start/4` returns `{:not_started, port, reason}` with `reason` read up to the watchdog's exit status, so the not-started text of `HarnessIO.start/5` (first 2,000 bytes) and of the bash tool (tail) does not depend on where the port cuts stdout. The read has no timeout and no byte cap, accepted: the watchdog writes one error text, bounded by the length of `cwd` (a port argument), and exits right after it.

Codex was unavailable (usage limit until 2026-10-04). A fresh general-purpose agent ran the same adversarial review with the same invariant sentence and base, and counts as the Codex reviewer.

## Round 1 (full)

Bounds sensor: `bounds sensor: 2 candidate functions, 1 flagged, 0 without an answer` / `plugins/bundled/lib/helyx/watchdog.ex:206  SIZE  defp read_to_exit(port, acc) do`.

Simplify (4 agents): reuse, simplification, and altitude found the same thing: the first form, a read in `HarnessIO.start/5`, repeated the read of `Bash.collect/3`. Fixed: the read moved to `Helyx.Watchdog.start/4`, and the bash tool no longer reads. Efficiency: no change.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 1 checklist gap, 5 judgement calls | 0 | The bound of the new read is now in row "bash working directory at command start" of `coding-agent.md`. The `claude_code.ex` comment names `Helyx.Watchdog.start/4`. The test assertion is exact. Not changed: drop the closed port from the tuple (a return shape change outside the ticket); the measurement in the code comment explains the bound at its line. |
| Spec | 1 stale doc row, 2 judgement calls | 0 | Row "Harness exit wait" now names the read and says that the port is closed when `HarnessIO.start/5` returns. The test assertion is exact. |
| Failure path | 0 | 0 | Probed cwd lengths 28 B, 500 B, 2,020 B, 2,420 B of "é", and 800 KB: the whole reason arrived each time, and the port was closed. A stray `{:DOWN, _, :port, _, :noproc}` stays in the mailbox of a caller that stops at once; before, the exit status stayed. Not reached: a chdir that hangs (before the marker, not changed). |
| Codex adversarial (agent stand-in) | 0 defects, 2 weaknesses | 0 | The weak test assertion is fixed. The stray `:DOWN` is the same as in the failure-path row. |

No round reproduced a defect, so the loop ends after round 1.

## Open

The Codex provider drops all events of the chunk that holds a stop, so whether a tool call goes out before a malformed stop depends on the cut. A line-by-line drop would make it exact. This is a behaviour decision, outside #340: ticket #351.
