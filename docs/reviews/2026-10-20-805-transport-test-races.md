# Review: two transport tests that failed under load (#805)

Scope: the working tree against the branch base `ad7e578b`. Files: `plugins/bundled/test/helyx/transport/web_socket_subscribe_test.exs`, `plugins/bundled/test/support/wire_client.ex`, `plugins/bundled/test/helyx/transport/web_socket_test.exs`. Test code only.

Invariant: every read of `Helyx.Test.WireClient` for bytes of its peer goes through `read/2`, with the one cap of a wait that must happen, `Helyx.Test.Events.wait_ms/0` (30,000 ms); and the test "an unsubscribe handled before the subscribe reply gets {} when the sub ends after it" monitors the sub right after `subscriber/1`, before every step of the test that can end it, so its `:DOWN` has the real reason.

## Evidence

- The logs of both failures are in the git common dir, `precommit-fails/20261019T124812Z-ticket-751-harness-env.log` (subscribe test) and `precommit-fails/20261019T162506Z-ticket-751-harness-env.log` (answer test).
- Subscribe test: `{:DOWN, ref, :process, #PID<0.9673.0>, :noproc}` after 30,000 ms, so the sub was gone at `Process.monitor/1`. The log has one line `GenServer #PID<0.9672.0> terminating ** (stop) ":killed"`. In a local run the hands are the pid just before the sub, and they write this line at the kill of the session. So the session lived until the test killed it, after the monitor. The code gives the sub no end while the session lives and the connection is suspended. The trigger of the early end is not found. The reading of the ticket ("the process ends before the monitor") holds for the effect only.
- Probe (copy of the test, deleted): the sub made to end between the poll for `Subscription.loop/1` and the monitor (the session killed, the end of the sub awaited). With the old place of the monitor: `{:DOWN, ..., :noproc}` after 30,000 ms, the text of the failed run. With the new place: 1 test, 0 failures, with the same `s` and `u` replies. Round 3 reproduced both results on its own.
- Answer test: `{:error, :timeout}` at the status-line read of `WireClient.upgrade/2`, which waited 5,000 ms. Probe: a suspend of the one Thousand Island acceptor for 6,000 ms made the old `Client.open/1` fail after 5,007 ms with the same `MatchError`; with the change it opened after 6,000 ms.
- One acceptor group (#793): before a serial connect, the one acceptor is `waiting` in `{:prim_inet, :accept0, 3}`, also after the first connection of the setup. Each test starts its own transport. So one acceptor group does not queue a serial connect. The answer test failed on a wait of 5,000 ms with no margin for load. `plugins/bundled/test/test_helper.exs` states the rule: "One cap for every wait that must happen, `assert_receive` and the support helpers alike".
- The two failures do not share a mechanism. Both are a stall under load past a fixed wait of 5,000 ms. Both are fixed here (see Assumptions).

## Simplify

One agent. No change. Rejected by the agent: a private read helper (later added in round 1 by a standards finding), the full module name of `Events`, shorter comments.

## Round 1 (full)

Bounds sensor (`--diff ad7e578b5e5b3601af80346830bd813c556cda57`):

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | approve, no material findings | none |
| Standards | the new header comment of `WireClient` claimed one cap for every wait, but `size/2` read with no timeout and callers passed 10,000 and 20,000 ms | fixed: one private `read/2` with the cap for every read of the peer; `recv/2` lost its timeout parameter; its two callers in `web_socket_test.exs` (the hello close at 5,000 ms, the ping at 15,000 ms; both must happen) use the cap |
| Standards | judgement: nine copies of `:gen_tcp.recv(socket, n, Events.wait_ms())` | fixed by `read/2` |
| Standards | out of the diff: `web_socket_test.exs:725` (1,000 ms) and `until_closed` (5,000 ms) | accepted hole below |
| Spec | the real cause is not found; the old monitor was already before the kill | stated under Evidence; accepted hole below |
| Spec | with the early monitor, a sub that ends early with `:normal` passes the test without its premise | fixed in round 2 with `assert Process.alive?(sub)`, removed in round 3 (see round 2) |
| Spec | the comment "never `:noproc`" claims too much | fixed (wording) |
| Spec | scope: every fixed wait of `WireClient` changed, not only the upgrade | kept: the same rule of `test_helper.exs`, one helper (Assumptions) |
| Failure path | `size/2` waits with no cap: a server that sends `<<0x81, 126>>` and stalls holds `recv/2` past its timeout | fixed by `read/2` |
| Failure path | `payload/2` ignored the timeout of the caller | fixed: no caller passes a timeout |
| Failure path | a stall of 5,500 ms between `subscriber/1` and the monitor gives `:noproc` (the 5,000 ms subscribe call times out) | fixed (wording); the stall is the accepted hole below |

## Round 2 (reduced: spec and failure path)

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Failure path | `read/2` holds: each stall case (header only, length 126 or 127 with no size, one size byte, no payload, part of a payload, one byte each 150 ms) returned `{:error, :timeout}` at the cap; no caller of the removed argument is left in any project | none |
| Failure path | a stall of 5,500 ms before `:sys.resume/1` makes the subscribe late; the sub replies `timeout` and ends `:normal` | the accepted hole below, stated before round 1 |
| Spec | `assert Process.alive?(sub)` makes an early end of the sub a hard failure, but the ticket accepts it ("accept `:noproc` as the same end") and its acceptance wants the test to pass after the fix | fixed: the line is removed |
| Spec | the answer on one acceptor group is not recorded | fixed: Evidence above and the commit message |
| Spec | `web_socket_test.exs:725` and `until_closed` | accepted hole below |

## Round 3 (reduced: spec and failure path)

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Spec and failure path | the acceptance holds: with the sub made to end before the kill, the old place of the monitor fails with `:noproc`, the new place passes | none |
| Spec and failure path | a sub that ends after the monitor and before the poll sees `Subscription.loop/1` makes the poll flunk after 30,000 ms with "the condition did not hold"; the `:DOWN` with the real reason stays unread. The trigger in both probes is a stall of 5,500 ms or an injected end | the accepted hole below: it was stated before round 1 with this result ("fails with a different text"). Not changed: a poll that also ends on a gone sub is a new behaviour for a hole with no observed run |
| Spec | a sub that ends between the two `Process.info/2` calls of `subscriber/1` gives a `MatchError`; no trigger found | the same accepted hole |

The round reproduced no defect outside the stated hole, so the loop ends.

## Assumptions

- Both tests are fixed here, though the comment of the ticket says "fix both tests in this ticket if they share the cause" and the mechanisms differ. The comment asks to check the margin of the upgrade wait; it had none against the rule of `test_helper.exs`, and the fix is in test support only. A second ticket for it would cost more than the change.
- The change covers every read of `WireClient`, not only the upgrade: the same rule, and one helper (`read/2`) makes it hold by construction.

## Accepted holes

- The trigger that ended the sub before the old monitor in the run of 2026-10-19 is not found. If it comes again, the `:DOWN` now has its real reason, or the replies of `s` and `u` show the difference.
- The test holds the session suspended over several steps. A stall of 5,000 ms or more of the test process there makes the subscribe late (`@call_timeout_ms` of `Helyx.Session`). The test then fails with "the condition did not hold" in the poll for `Subscription.loop/1`, or with a `MatchError` in `subscriber/1`. The test "a request with bad params answers while the encoder slot is held" has the same window.
- `web_socket_test.exs:725` reads with a cap of 1,000 ms and `until_closed/2` with 5,000 ms, both waits that must happen, on raw sockets outside the test client. They did not fail.
- `tui/wire_test.exs` passes 5,000 ms to `Helyx.TUI.Wire.connect/4`: a parameter of the product under test, not a wait of the test client.
