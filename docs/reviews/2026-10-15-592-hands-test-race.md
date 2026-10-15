# Review: #592 Hands tests wait for the release message, not its order

Invariant: in the root, plugin, and app test suites, an `assert_received` names only a message that the test process sent itself, or one that came before a message of the same sender that the test process already received. Every other message is awaited with `assert_receive`. Every property that an old `assert_received` proved at the moment a call returned is still checked at that moment: a process that the old code saw as down right after `GenServer.stop/1` or `stop_supervised/1` gets `refute Process.alive?/1` there, and a release that the old code saw right after a call gets `Helyx.Test.Released.take/0` there. The test releases of `Helyx.Test.Tool.Hold` and `Helyx.Test.Connected` write the row of `Helyx.Test.Released` before they send `{:release, mode, handles}`.

Files: `AGENTS.md` (one rule line), `test/test_helper.exs`, `test/support/released.ex`, `test/support/interfaces.ex`, `test/helyx/session/hands_test.exs`, `test/helyx/session/provider_process_test.exs`, `plugins/bundled/test/helyx/watchdog/harness_stop_test.exs`. No `lib/` code changes.

Sites kept as `assert_received`, each checked by the author and by two agents: `provider_process_test.exs` `{:conn, :init, ^old, _}` (after the `:turn` of the same sender), `boundary_test.exs:126` (`Helyx.Tool.specs/1` runs in the caller), `openai_test.exs` (the Req plug runs in the stream consumer), `selection_test.exs:97`, `bash_preamble_test.exs:72` (sent before the reply to the test's call), `cli_test.exs`, `print_test.exs` (self-sent, or before the `:DOWN` of the same run process).

Bounds sensor, every round: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

## Round 1 (full)

Base `origin/master` (`12e5cbc`). Reviewed state kept as commit object `0069e574`.

Simplify, four agents (the altitude agent was lost when the print run ended, and ran again in the foreground). Applied: the AGENTS.md rule line (altitude: the second race of this class after #577). Applied, then reverted in round 1: the simplification agent asked to drop `refute Process.alive?(hands)` from the switch-close Core stop test; the failure-path agent showed that this lost a check (1.1).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | failure path | Four Core-stop tests no longer checked that the hands were dead when the stop returned. Reproduced: a mutant with no wait for the hands' `:DOWN` in `Stop.stop_hands/1` and a 60 ms sleep in `Hands.terminate/2` failed the old tests and passed the new ones | Fixed: `refute Process.alive?` of `proc` and `hands` right after each stop where the old code had an `assert_received {:DOWN, ...}` of that process (`Stop.run/1` waits for both `:DOWN`s before the session ends) |
| 1.2 | spec | The test "closes it, releases it, and stops the hands first" lost the check that `proc` was down at the return | Fixed with 1.1 |
| 1.3 | Codex | Approve, no findings | n/a |
| 1.4 | standards | Rule wording: "the test already received" reads wrong for `print_test.exs:393`, where `Print.main` receives the `:DOWN` | Fixed: "the test process already received" |
| 1.5 | standards, spec | No devlog for the run | Fixed: `docs/devlogs/2026-10-15-592-hands-test-race.md` |
| 1.6 | standards | `refute_received` of a message from another sender has the opposite race (it can pass when it should fail); 57 sites | Out of scope of #592 (open, see the end) |
| 1.7 | standards | After `:ok = Session.abort(session)`, the converted `{:conn, :interrupt, ...}` checks no longer prove that the interrupt came before the return | Judgement at round 1; see 3.4 |
| 1.8 | spec | `provider_process_test.exs` checks a stale `refute_received` before the wait for the fresh context | Out of scope (a `refute_received`) |

### Fix size

0 code lines without tests and Markdown: 8 test lines and 1 Markdown line. Round 2 is a reduced round.

## Round 2 (reduced)

Base `0069e574`. Reviewed state kept as commit object `83bd2ecd`. The briefs named the invariant of the fix: every property that an old `assert_received` proved at a return is still checked at that moment.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | failure path, spec | The release is no longer checked at the return: `{:release, ...}` comes from a release Task, so `refute Process.alive?(hands)` does not prove it. Reproduced: a mutant that runs the `:deliver` release unlinked and returns at once passed every new test and failed 10 of 10 old ones (test names: "the abort returns after the provider process is stopped and released") | Fixed in round 3 |

The second finding on one mechanism (the checks at a return), so round 3 changes the mechanism: a message cannot prove "before the return", a record written before the release ends can. `Helyx.Test.Released` keeps one ETS row per release of a `{:report, pid}` handle, keyed by the pid; the eight sites read it with `take/0`. hands_test 85 and 116 use `take/0`, which is stricter than the `assert_receive` that the ticket names.

### Fix size

A new test-support module and table; a module added, so round 3 is a full round.

## Round 3 (full)

Base `83bd2ecd`. Reviewed state kept as commit object `2c5b5391`.

Simplify, four agents: clean. Skipped: the argument order of `report(handles, mode)` against `{:release, mode, handles}` (standards, judgement); `{pid, {mode, handles}}` rows (cosmetic); a cleanup of rows that no test takes (the efficiency agent: small rows, bounded by the suite; the comment now states the bound).

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | Codex | At four stop sites, `Released.take/0` ran after `assert_receive` waits, so a release after the return could write its row during the wait | Confirmed by reading. Fixed in the small-fix round: each `take/0` comes right after the `refute Process.alive?/1` lines |
| 3.2 | failure path | No defect. The round-2 mutant does not break the order at the return; a mutant that releases 60 ms after the return fails all 9 take sites, and one that keeps the handles fails hands_test 69 and 99 at `take/0`. 5 clean runs | n/a |
| 3.3 | failure path | `assert_receive {:DOWN, ^ref, :process, _, _}` after `refute Process.alive?(proc)` checks nothing more | Fixed in the small-fix round: line and its monitor removed |
| 3.4 | spec | "while submitting sends the interrupt after the turn": no check at the return of `Session.abort/1` that the interrupt was sent; a mutant that answers the abort at once in `:submitting` is argued, not run | Not reproduced. Open (see the end): a check needs a record of the interrupt, as `Released` does for releases |
| 3.5 | standards | The rule does not name `Helyx.Test.Released`; the table grows in a run | Bound stated in the comment of `released.ex`. The rule stays generic: it names the order fact, not one helper |
| 3.6 | spec, altitude | `hands_test.exs` `refute_received {:release, _mode, _handles}` has the opposite race | Out of scope (a `refute_received`); the failure-path agent notes that `take/0` cannot see a late release either |

## Small-fix round (reduced)

Base `2c5b5391`. The fix of 3.1 and 3.3: 13 test lines, no code file, no function added. The briefs named the invariant: every check at the return comes before any wait of the test.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 4.1 | failure path | No defect. A mutant that releases 20 ms after the hands end fails the current tests 5 of 5; it also fails the round-3 tests, since their first `assert_receive` finds its message at once. No delay separated the two versions on one node | n/a |
| 4.2 | spec | `provider_process_test.exs`, the `error_turn`, `bad_action`, `bad_event` loop: `refute Process.alive?(proc)` and `Released.take/0` come after two `assert_receive` waits, so the round-3 gap stays at this site | Not reproduced, and no round is left. Open: move `take/0` above the waits; `proc` comes only from the `:init` message |

## Open

- 4.2: one site checks the release and the death of `proc` after two waits.
- 3.4: no check at the return of `Session.abort/1` in `:submitting` that the interrupt was sent.
- 1.6, 1.8, 3.6: `refute_received` of a message from another sender can pass when it should fail. #592 covers only `assert_received`.
