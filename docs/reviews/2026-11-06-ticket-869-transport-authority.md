# Review: #869, slice C1 (the authority of the transport)

Ticket #869, `docs/features/hub.md`, decision 5. The transport side only: `Helyx.Transport.WebSocket.Authority` (the behaviour), the `:authority` option, `hello`, `check`, `run`, `result`, `release`, `close/2`, and the close codes 4401, 4403, and 4503. `Helyx.Hub`'s implementation of the behaviour, the `hub.*` operations, records, protocol 4 and the `token` field in the schema, and the wiring of `helyx serve` are later slices. Base: `a7ad93ca`.

## Round 1 (full)

Bounds sensor: `3 candidate functions, 0 flagged, 0 without an answer`.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Codex (high), reproduced | A `subscribe` dropped the params that `check` gave and subscribed to the original session | Fixed: the subscription builds its session and options from the params of `check`; test |
| 2 | Codex, spec, failure path, reproduced | The deadline of the operation also covered `result`: a `result` of 6,500 ms after a fast `sessions.live` answered `timeout` | Fixed: the deadline ends with the Core call; slow test |
| 3 | Codex, reproduced | An exit of the Core call of a `start` or `resume` skipped `release` | Fixed: the exit is caught, `release` runs, the exit goes on; covered by the probes of round 2, no test in the suite |
| 4 | Standards | `assert_received` of messages of a worker (#592) | Fixed: `assert_receive`, and the `refute_received` comes after the messages of the same workers |
| 5 | Standards | The comment of the bound of the `token` and `proof` fields; the 15,000 ms as a bare number | Fixed |
| 6 | Spec | The transport puts no bound of its own on a callback; a `hello` callback that blocks holds the connection, and the auth wait of 5,000 ms does not end it | Kept: the callbacks run in the process of the transport (decision 5; the reserved place of decision 14 monitors that process), so a Task with a timeout would break the monitor. The bound is the Hub call of the authority, 5,000 ms. The Bounds row "the `hello` callback, where enforced: transport" needs the owner's wording |
| 7 | Spec | The transport checks the params of `check` again (`Ops.check`); a bad one crashes the worker, `failed` | Kept: the generic answer to a contract break of trusted code; the comment says so |
| 8 | Spec | Untested: a start on an address that is not loopback with an authority, the slot and the 15,000 ms of `sessions.saved` under `run` | Open (probes of round 1 covered them: P3, P5) |

## Round 2 (reduced: spec, failure path)

Both agents re-ran the three reproductions; each holds. No new path broke the invariants (what `check` returns is what runs; the deadline is the Core call only; `release` follows every failed or exited Core call of a `start` or `resume` that `check` passed). No reproduced defect ends the loop.

Wording fixed after round 2: the moduledoc of `Authority` says that `hub.*` and `sessions.saved` go to `run` with no `check`, and that an exit of `release` leaves the answer of the Core call.

Open: a connection that closes during the Core call of a `start` kills the worker, so neither `release` nor `result` runs; decision 14 frees the place at the `:DOWN` of the caller, and the session has no record (Accepted holes, "Hub crash between a start and its record", covers the same state).
