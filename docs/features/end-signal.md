# End signal

Status: the current contract since #434.

## Goal

A subscriber learns from one message with data that the session ended. ADR 0006, section 2.

User story: I use the TUI, and the session behind it ends or crashes. The TUI exits and says why, and the reason is data: `:stopped` or `:crashed`. A remote client gets the same reason in a `session_end` frame (ADR 0008).

## Interface

`Helyx.Session.subscribe/1` returns `{:ok, snapshot, ref}` or `{:error, :session_not_found}`.

- `ref` is the caller's monitor of the session process. `subscribe/1` makes it before the subscribe call, so the real exit reason of the pid of the snapshot is never lost.
- The end signal is the `:DOWN` of that monitor: `{:DOWN, ref, :process, pid, reason}`. `Session.end_reason/1` maps `reason` to `:stopped` (`:normal`, `:shutdown`, `{:shutdown, term}`) or `:crashed` (any other reason). The crash report of the session shows the kind of the reason only; with the SASL reports on, the supervisor report shows the full reason (`docs/features/session-lifecycle.md`, "Log and crash reports").
- The caller owns the ref. The session holds one subscription for each caller pid (`session-subscribers.md`, S2), so a second subscribe gives each live event once, and a second ref. The caller removes a ref that it no longer wants with `Process.demonitor(ref, [:flush])`.
- On `{:error, :session_not_found}`, and on an exit of the snapshot call at its timeout, `subscribe/1` removes its monitor with `[:flush]` and sends `{:unsubscribe, self()}` to the same pid. A live session handles it after the subscribe, because both messages come from one caller to one process. A failed subscribe also ends an earlier subscription of the caller to that session; the ref of the earlier one stays with the caller.

**The slow end.** Past 16,384 unacked events the session ends the subscription, not the session: it sends `{:helyx_end, ref, :slow}`, with the `ref` of the caller's last subscribe, after every event that it sent to the caller, and no event after it. The caller's monitor stays; the caller demonitors `ref` with `[:flush]`. The TUI exits with `{:session_down, :slow}`, and print mode fails with it (`replay-ring.md`).

On the wire (planned, #660), the subscription process turns the `:DOWN` into one `session_end` frame with the reason, after every event of the session. It ends that subscription; the connection stays open. A client that subscribes after the end gets `session_not_found`, and the reason is not kept (ADR 0008, `docs/features/wire-protocol.md`).

### Order

On one node, the end signal comes after every event of the session: the session sends its last event before it dies. A subscriber that joins as the session ends gets one of two results:

- `{:ok, snapshot, ref}`, and then the end signal. The monitor came before the call, and the session answered, so the `:DOWN` comes after the snapshot.
- `{:error, :session_not_found}`, and no end signal and no monitor.

### The TUI

`mount/1` keeps the ref in its state as `session_ref`. The `:DOWN` with that ref exits the TUI with `{:session_down, reason}`. Every other `:DOWN` goes to the catch-all clause.

## Bounds

| What | Bound | Where enforced |
| --- | --- | --- |
| monitors of a caller for a session | one for each successful subscribe, until the caller demonitors it or the session ends | the caller |
| end signals of one ref | one | the BEAM monitor |
| end reason | two atoms | `Helyx.Session.end_reason/1` |

## Ownership

No external resource. The monitor is released by its `:DOWN`, by the caller's demonitor, by a failed subscribe, or when the caller ends.

## Tests

`test/helyx/session/end_signal_test.exs`: a normal stop, a kill, a raise, and a stop of the Core each give one `:DOWN` with the ref, after the last event. A subscribe that fails as the session ends leaves no signal and no monitor. A subscribe that times out leaves no subscription and no monitor.

## Out of scope

- The wire form of the end signal: `docs/features/wire-protocol.md`.
- A helper that pairs a second subscribe with the demonitor of the first: no client subscribes twice today.
