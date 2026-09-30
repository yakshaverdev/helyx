# Review: #260, shared harness adapter code

Scope: `git diff 0266508` on `ticket/260-harness-adapters-shared`. The Claude Code and Codex providers share one launch (`HarnessIO.launch/4`: the `sh` wrapper with stderr dropped, open input, the 5,000 ms TERM grace, the keeper), one release (`HarnessIO.release/3`: a delivery gets the `:cancel` sequence, same grace), one sort of port messages (`HarnessIO.port_message/3`, the entry of `harness_info/2` in both providers and of the Codex handshake), and one wire id for replayed tool calls (`HarnessIO.wire_id/1`). The grace has one home, `@term_grace_ms` in `HarnessIO`.

Invariant: any port exit during a close (an exit status, or a `:DOWN` such as `:epipe`) answers the close with `:ok`, and any other port exit stops the harness process. A replayed call and its result get the same wire id, and two ids join only through a SHA-256 collision or when a valid id already equals the digest form of another id.

## Deviations from the ticket

- The ticket names three results of the port function. There is a fourth, `{:closed, from}`: the close-on-exit rule lives in `HarnessIO`, so a third adapter cannot bring back 4.1. For this, the Codex state field `close` is renamed `closing`, the name Claude Code uses.
- `hex_digest/2` is public in `HarnessIO`: `wire_id/1` and the Codex tool digest both use it.
- The Claude replay change alters the wire id of a tool call id outside `[a-zA-Z0-9_-]{1,64}`: `a.b` was `a_b`, now it is `h_` and 62 hex digits. The replay runs only for a fresh harness session (`write_turn/1` replays only when neither `resume` nor `sent?` is set), so a resumed session file is not affected. A valid id, such as `toolu_...`, is unchanged.

## Simplify

- Reuse: clean. Efficiency: clean.
- Simplification: `term_grace_ms/0` exists only for the moduledoc. Kept: a number written in the doc would drift from the code.
- Simplification: `start/5` keeps its `opts` and stays public for `go_ahead_test.exs`. Skipped: the test is outside the ticket.
- Simplification: inline `read/2`. Done, then restored as clauses in round 1 (standards).
- Altitude: the close-on-exit rule was still in each adapter. Fixed: `port_message/3` returns `{:closed, from}`.
- Altitude: the diff seemed to remove #262 notices. False positive: `origin/master` moved to include #262 during the work; the base is `0266508`.

## Round 1 (full)

Bounds sensor (base `0266508`):

```
bounds sensor: 10 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/claude_code.ex:331  SIZE  def harness_info(message, state) do
```

The flag is the line cap of `HarnessIO.lines/3`, unchanged; the failure-path agent checked the function.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | `harness_info/2` nests a `case` in a `case` (judgement call) | fixed: `read/2` with one clause per terminal |
| Standards | the 4.2 test takes its expected ids from `wire_id/1` (judgement call) | fixed: the test checks the `h_` form, that the two ids differ, and the pairing |
| Standards | a moduledoc line over the width | fixed |
| Standards | `launch/4` next to `start/5`; the state contract grows; `hex_digest/2` in `HarnessIO` (judgement calls) | kept: the module comment states the contract; `wire_id/1` needs the digest |
| Spec | `long-lived-harness.md` and two `coding-agent.md` rows say a Codex `:DOWN` always stops with `{:codex_exit, reason}` | fixed: each states the close exception |
| Spec | the fourth result `{:closed, from}` | kept, see deviations |
| Failure path | none reproduced (probes: `wire_id/1` at 63, 64, 65 characters, empty, multibyte, invalid bytes, `a.b` against `a:b`; exits during and outside a close; stale port messages; `keep_port/1` after a failed start). Not reached: a real `kill -9` of the watchdog during a close | none |
| Codex | approve, no findings | none |

No defect reproduced, so the loop ends after round 1. One run of `claude_code_test.exs` during the review had 2 failures (an abort grace test and a replay cap test) that passed on the next run; the review probes loaded the machine then.
