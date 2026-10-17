# Replay ring and subscriber credits

## Goal

A client reconnects without loss, and a slow subscriber has a bound, both in the session process (#659, ADR 0008 §4 and §5).

User stories:

- The phone sleeps for two minutes during a turn and wakes up. It shows the missing text with no gap and no repeat.
- A client on a bad network falls behind. The agent goes on at full speed; that client reconnects and gets a tail snapshot.

Decisions:

1. **Replay ring.** The session keeps a ring of its own events, the newest 1,024 events and at most 4 MiB. It records each event, also when no client is subscribed. An event over 4 MiB empties the ring and marks a gap: no replay crosses it. Reason: the phone of the first story needs the events of the minutes it slept, and a dead session cannot serve them, so the ring lives and ends with the session process.
2. **Atomic resubscribe.** `subscribe/2` takes `after: {instance_id, seq}`. One call registers the subscriber and returns the events after `seq` up to the session's `seq` B, or a snapshot at B. Live delivery starts after B. Another instance id, an interval that the ring does not hold, or a `seq` above B gives the snapshot. Reason: one message of the session does both, so no event falls between the replay and the live events (S1 of `session-subscribers.md`).
3. **Credits.** The session counts, for each subscriber, the events that it sent and that the subscriber did not ack. `ack/2` is cumulative by `seq`. Past 16,384 unacked events, the session ends that subscription with the fixed reason `:slow` and never waits. There is no unbounded mode. Reason: a subscriber that does not read grew its mailbox with no bound (#116); the session must not wait for a client, so it drops the client.
4. **Every subscriber acks.** The TUI, print mode, and the test subscribers that read many events pass each event to `ack/2`, which acks each `seq` that is a multiple of 1,024. Core owns the cadence, so no client holds the number. The cadence needs no state: the client passes every event that it receives, also one that it drops, so at most 1,023 events that it read are unacked.

## Interface changes

- `Helyx.Session.subscribe(session, opts)`: `opts` takes `tail: n`, `after: {instance_id, seq}`, both, or neither, each at most once. `after` is a binary and an integer >= 0; any other `after` is `{:error, :invalid_after}`. The result is `{:ok, %Snapshot{}, ref}` or `{:ok, {:replay, events}, ref}`. `events` is the list of the events after `seq`, oldest first, contiguous, and can be empty. The snapshot of a resubscribe that the ring cannot serve is the one that `tail` gives; with no `tail` it is the full snapshot, as without `after` (Core has no default tail; the wire passes its default of 200).
- `Helyx.Session.ack(session, event)`: `:ok`. It acks `event.seq` when that is a multiple of 1,024, else it does nothing. A client in the node calls it for each event that it receives, also one that it drops.
- `Helyx.Session.ack(session, seq)`: `:ok`. A message to the session, no call: an ack never waits. `seq` is an integer >= 0. The session takes `max(acked, seq)`. It ignores an ack from a pid with no subscription, and an ack above its `seq`: such an ack is of an earlier instance or a bug of the client, and it acks nothing that the session sent. A session that is not running ignores it too.
- The slow end: the session removes the entry of the subscriber, removes its own monitor of it, and sends `{:helyx_end, ref, :slow}`, where `ref` is the ref of the subscriber's last subscribe. It comes after every event that the session sent to that subscriber, and no event follows it. The caller's monitor of the session stays; the caller removes it with `Process.demonitor(ref, [:flush])`. On the wire the subscription process closes the connection with `4408` (#660).
- `Helyx.Session.Ring`: the ring, a pure value. The session process owns it in `Helyx.Session.Server.State`. `Helyx.Session.Server.Events` owns the credits, with the subscribers.
- The subscribe request is `{:subscribe, pid, ref, tail, after}`. The entry of a subscriber is `{monitor, ref, acked}`. A repeated subscribe of a pid keeps its monitor (S2), takes the new `ref`, and keeps the lower of its acked `seq` and the new base: the events that the session sent before are still in its mailbox.
- The TUI exits with `{:session_down, :slow}` at the slow end, and print mode fails with it. Each acks.

### The ring

- `from` is the lowest `after` that the ring can serve: 0 for a new instance, the `seq` of the newest event that the ring dropped, or the `seq` of an event over 4 MiB.
- A replay serves `after` when the instance id is the session's and `from <= after <= B`. It returns the events of the ring with a larger `seq`.
- A resume starts a new instance with an empty ring, so `after` of the earlier instance gives a snapshot.

### The credits

- The base of a subscription is the `seq` up to which the session counts it as acked: B after a snapshot, `after` after a replay, so a replayed event counts. A repeated subscribe of a pid never raises its base, so a client that resubscribes and does not read still reaches the bound.
- At each event with `seq` S, a subscriber with `S - acked > 16,384` gets the slow end in place of the event. So a subscriber holds at most 16,384 unacked events.

## Replaced mechanism

1. **`send/2` with no bound** (`Events.emit/4`). Each event still goes with `send/2`, after a credit check per subscriber; the slow end replaces the send past the bound. The order of the events of one subscriber is the send order of the session, as before.
2. **The subscriber entry** `pid => monitor` becomes `pid => {monitor, ref, acked}`. The `:DOWN` clause of the session matches the monitor in the tuple. S2 and S4 keep their rules.
3. **Reconnect with a new snapshot** (ADR 0006 §3). A client that has `after` gets the events from the ring; a snapshot comes only when the ring cannot serve them. A subscribe without `after` is unchanged.
4. **Tests.** The tests of `Helyx.Session.subscribe/2` keep their properties: they receive fewer than 16,384 events, so they need no ack. `Helyx.Test.LateClient` acks, as a model client.
5. Users see no change while their client reads its events. A client in the node that stops reading for 16,384 events loses its subscription: the TUI exits with "the client fell behind the session events", and print mode fails with the same text.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| replay ring per session, count | 1,024 events | `Helyx.Session.Ring` | the oldest event goes, and `from` moves to its `seq` |
| replay ring per session, bytes | 4,194,304 bytes, each event by `:erlang.external_size/1` | `Helyx.Session.Ring` | the oldest events go until the sum fits; an event over the bound empties the ring, and `from` is its `seq` |
| replay rings of the server | 268,435,456 bytes: 64 live sessions of 4 MiB | the live-session cap (#657) | as above |
| replay list of one subscribe | the ring: 1,024 events and 4 MiB | `Helyx.Session.Ring` | n/a |
| credits per subscriber | 16,384 unacked events, a replayed event too | `Helyx.Session.Server.Events` | the slow end, in place of the event |
| ack | an integer from 0 to the session's `seq` | `Helyx.Session.ack/2` (type), the session (range) | a non-integer or a negative value crashes the caller (guard); a value above the `seq` is ignored |
| `after` | a binary and an integer >= 0 | `Helyx.Session.History.subscribe/1` | `{:error, :invalid_after}` |
| client ack cadence | one ack each 1,024 events | `Helyx.Session.ack/2` with an event; a wire client chooses its own | n/a: a client that acks less often reaches the bound sooner |

The ring holds terms that the transcript holds too, so a message is in the heap once; the byte bound counts it once for each event that holds it.

## Ownership

No external resource. The ring and the credits end with the session process (`wire-protocol.md`, "Ownership").

## Tests

- `test/helyx/session/ring_test.exs`: the count bound at 1,024 and 1,025, the byte bound at the limit and over, an event over 4 MiB, and `from`.
- `test/helyx/session/replay_test.exs`: a resubscribe with `after` gets the missed events, then the live ones with no gap and no duplicate; an empty replay; another instance, a future `seq`, and an interval out of the ring give a snapshot; a bad `after`. A subscriber that never acks gets the slow end after 16,384 events and no event after it; one that acks by the cadence gets a burst of 20,000 deltas with no slow end; an ack above the `seq` acks nothing; a repeated subscribe keeps the lower base.
- `test/helyx/session/end_signal_test.exs`: a kill of the sessions Registry stops the session, and the subscriber gets its end signal (#116).

## Out of scope

- The wire encoding and the `4408` close: #660.
- A ring that outlives the session process: a dead session cannot serve its ring, so the end is the end signal.
- A reconnect of the TUI with `after`: #662.
