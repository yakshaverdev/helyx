# Review: one bound for the stop of the transport (#793)

Scope: the working tree against the branch base `6e44680c`. Files: `plugins/bundled/lib/helyx/transport/web_socket.ex`, `plugins/bundled/lib/helyx/transport/web_socket/drain.ex` (new), `plugins/bundled/lib/helyx/transport/web_socket/gate.ex`, `plugins/bundled/test/helyx/transport/web_socket_test.exs`, `docs/features/wire-protocol.md`, `docs/features/serve.md`.

Invariant: the stop of `Helyx.Transport.WebSocket` takes at most 20,000 ms in all. Its first step (`Drain`, within its shutdown of 5,000 ms) closes the listener and the gate and kills at once each connection that is not inside the gate; then the WebSocket connections stop together in one acceptor group, each with close `1000` or killed by Thousand Island past 15,000 ms. After a crash of the gate or of the listener, the first step does nothing, and every connection stops within 15,000 ms.

## Decision

- The triage comment of the ticket decides: one total bound, and a connection that has not finished its headers closes at once.
- `num_acceptors: 1`: Thousand Island stops its acceptor groups one after another, each within the shutdown of its connections; one group gives one wait. `shutdown_timeout: 15_000` is the default, set so that a dependency change cannot move the stated bound.
- The first step is a process of its own, started after Bandit in the transport supervisor, so the supervisor stops it first. It uses the public API of Thousand Island (`suspend/1`, `connection_pids/1`). A connection in the header read of Bandit traps exits and blocks in `recv`, so only a kill ends it at once.
- Measured before the fix (the new test, two connections inside their headers): the stop took 30,005 ms.

## Simplify

One agent. Applied: `init/1` passes its argument; `pids -- Gate.inside(gate)` in place of a filter; one comment sentence removed. Reverted by the author: the agent replaced the wait on the header read with "accepted and outside the gate", which does not prove the stalled state, so the test could pass without the fix. Rejected by the agent: removing `shutdown_timeout`, a gate call in place of `Process.info/2`, dropping the `Process.alive?` guard, a helper for the child lookup.

## Round 1 (full)

Bounds sensor (`--diff 6e44680ca02d9857b53ff60a8c295c8a15750ffb`):

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | needs-attention, 1 medium: the drain read the gate members while the gate stayed open, so a connection that entered after the read was killed without close `1000` (from the code; its sandbox could not open a socket) | fixed: `Gate.close/1` closes the gate (a later `enter` gets `:full`) and gives its members in one call; test "a closed gate gives the connections inside and admits no other". The failure-path agent of round 2 reproduced the window with a suspended gate: 20 of 20 rounds kept close `1000` |
| Standards | guarantees with no test: the 20,000 ms sum, the 15,000 ms of a stuck WebSocket connection, the 5,000 ms kill of the first step, the kill of a refused upgrade, the crash branch | the one-group bound got the slow test "connections that do not stop hold the stop 15,000 ms once, in one acceptor group"; the rest are accepted holes below |
| Standards | the Ownership row of the listen socket did not name the new child | fixed |
| Standards | the 5,000 ms of the first step was the implicit default; the drain did not state its cap | fixed: `use GenServer, shutdown: 5_000`, "one for each transport" |
| Standards | judgement: the name `Drain`; the test helper `in_headers?/1` matches a private Bandit function; `num_acceptors: 1` not stated as a connection cap | kept the name (the step lets the WebSocket connections finish); the helper is kept, its comment names Bandit 1.12, and a rename fails the wait loudly; the cap row added |
| Spec | the docs said "closed at once" for a stop of any cause; after a crash of the gate the first step does nothing (probe: 15,001 ms) | fixed: the exception in both Bounds rows |
| Spec | `num_acceptors: 1` had no test: the drain alone makes the header test pass | fixed: the slow test above |
| Failure path | no reproduced defect. Probes: 3,000 stalled plus 64 WebSocket connections stopped in 11 ms; a suspended WebSocket connection held the stop 15,001 ms; a gate crash 15,004 ms with the guard quiet; stops racing connects, 20 repeats, no log | none |

## Round 2 (reduced: spec and failure path)

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Failure path | no reproduced defect. The fixed race held 20 of 20 rounds; requests that enter the gate but are no upgrade get 400 and close at once; kills of the gate, the drain, or Bandit end the transport with close `1000` and no log | none |
| Spec | no path breaks the invariant (16 rounds of 12 clients during the stop, partial gates hit) | none |
| Spec | the moduledoc and serve.md decision 2 had no crash exception | fixed (wording) |
| Spec | with a suspended gate, the stop took 20,006 ms: the bound is the sum of two shutdowns plus the process exits | fixed (wording): the row states the sum and the measurement |
| Spec | the cap row counted only connections before the upgrade; `num_connections` counts all | fixed (wording) |
| Spec | the Ownership row of the socket said "the upgrade" | fixed (wording): created at the accept, and the kill at a stop |

The round reproduced no defect, so the loop ends.

## Accepted holes

- No test of the 5,000 ms kill of a stuck first step: it needs a suspended gate, and the probe measured 20,006 ms.
- No test at 16,384 TCP connections: the loopback ports ran out (`:eaddrnotavail`) before it in the probe.
- No test of a WebSocket client that does not read: the slow test suspends the connection process instead.
- The 503 of a closed gate is tested at the gate, not over HTTP: the listener is closed by then.
- The slow group test was not run against `num_acceptors` 100 by the author; round 1 spec named that the header test alone passes with 100 groups.
