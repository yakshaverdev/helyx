# The session holds its subscribers

Status: built in #297 on 2026-10-02. Design decided on 2026-10-02. Built from the code at `58471ac`. The design went through five review rounds in one proposal with the one-provider design (`one-provider-path.md`). The last round found no blocking issue.

## Goal

The session process keeps the list of its subscribers and sends each event to them. The events Registry, `Helyx.Session.Watch`, the lost signal, and its supervisor barrier are deleted.

Today `Session.subscribe/1` registers the caller in the events Registry first and asks the session for a snapshot second (`session.ex`, `subscribe/1`). The Registry is a separate process that can restart while the session runs. Most of the subscription code exists only to handle that:

- `Helyx.Session.Watch`, one process per subscription (125 lines), which sends the end signal and the lost signal.
- The lost signal `{:helyx_subscription_lost, id}` and its barrier, so that the signal comes only after the Registry supervisor restarted the partition (`end-signal.md`, review #189).
- `join/4`, `leave/2`, and `stop_watch/1` in `session.ex`, with the process dictionary entries, the flush of old signals, and the rescue clauses for a Registry that is gone.
- The TUI resubscribe path after a lost signal (`tui.ex`, `{:helyx_subscription_lost, id}`).

The session already sends every event: `Registry.dispatch` in `server.ex` runs in the session process. When the session holds the list, no separate process can lose a subscription.

Users see no change. A client sees two changes: the lost signal is gone, and the end signal has a new shape (Decision Q2).

## Interface changes

### Design rules

**S1 Subscribe.** `subscribe/1` is one call to the session, `{:subscribe, pid}`. In one step, the session adds the caller to its subscriber map and returns the snapshot. It monitors the caller only when the caller has no entry yet (S2). Every event after the snapshot reaches the caller, because both happen in one message of the session.

**S2 One entry and one monitor per caller.** The map is keyed by pid. Its value is the session's monitor reference for that pid. A repeated subscribe from the same pid reuses the entry and its reference, and makes no new monitor. So each event comes once, and the session holds at most one monitor per subscriber. `{:unsubscribe, pid}` removes the entry and calls `Process.demonitor(ref, [:flush])`. For a pid with no entry, it changes nothing. An event of an earlier subscription that is still in the caller's mailbox has a `seq` at or below the new snapshot, and the client drops it by the rule of ADR 0006 §3, which stays.

**S3 Events.** The session sends each event to each pid in the map, in place of `Registry.dispatch`.

**S4 A subscriber ends.** At a `:DOWN`, the session removes the entry of that pid only when the entry holds the same monitor reference. A `:DOWN` with another reference does not touch the map and goes to the other clauses of the session. No subscriber can make one: the `:DOWN` of an entry removes the entry, and an unsubscribe removes its monitor with `[:flush]`. So it is a bug, and the session crashes on it as on any unknown message (Codex round 1 of #297).

**S5 The end signal.** `subscribe/1` reads the session pid once (`pid/1`), monitors that exact pid with the tag `{:helyx_session_end, id}`, and then sends the subscribe call to the same pid. The monitor comes before the call, so the real exit reason of the session is never lost. The tag holds no `instance_id`, because the caller learns it only from the snapshot. The caller keeps one monitor reference for each `{core, id}` in its process dictionary, as it keeps the Watch today. A new subscribe for the same id first removes the old monitor with `Process.demonitor(ref, [:flush])`. This also removes its signal from the mailbox, and no signal of a removed monitor can come later. So the caller holds at most one monitor for a session, and every end signal that it gets is of its current subscription. Each subscribe also removes the entries whose session the caller no longer monitors, as `leave/2` removed the entries of dead watches. A monitor leaves the caller's monitor list (`Process.info(self(), :monitors)`) only when its end signal is in the mailbox, where it stays for the client. A dead pid is not enough: a process is dead before its `:DOWN` arrives (failure-path round 2 of #297). While the caller holds another monitor of the same pid, the entry stays until that monitor ends too. Then it removes every end signal for the id from the mailbox, as `leave/2` removed the signals for the id, because such a signal is of an earlier process of the id whose entry is gone (found in the build of #297: without the pruning, the dictionary grew by one entry for each session that ended). Accepted hole, as before: the flush matches the id only, so a subscribe to an id in one Core removes an unread end signal of an ended session with the same id in another Core. `Session.end_reason/1` maps the reason to `:stopped` or `:crashed` by today's rule (`watch.ex`, `end_reason/1`).

**S6 Errors.** The subscribe call keeps the distinction of `call_pid/3` in `session.ex`:

- No process has the id: `{:error, :session_not_found}`, and no monitor is made.
- The session ends during the call: `{:error, :session_not_found}`, as today.
- The call times out and the session still lives: the exit goes on to the caller, as today.

On both failure paths, before the return or the exit, `subscribe/1` removes its monitor with `[:flush]` and sends `{:unsubscribe, self()}` to the same session pid. A dead session ignores it. A live one handles it after the subscribe, because both messages come from one caller to one process, so it removes a late entry. Events that the session sent between the two can stay in the mailbox, as today. A later subscribe of this caller reaches the session after the unsubscribe, so its snapshot `seq` is above those events, and the client drops them by `seq`.

**S7 The instance filter stays.** A resume starts a new session process, and events of the old process can still be in the client's mailbox. The `instance_id` rule of ADR 0006 §3 stays for events. So does `seq`, which a remote transport needs for its reconnect. The end signal needs no `instance_id`, because S5 removes the monitor of the old pid before the subscribe to the new one.

**S8 What `subscribe/1` keeps.** About 50 lines of lifecycle code: the monitor reference per session, the demonitor with flush, the ordered unsubscribe on failure, and the removal of the entries and signals of ended sessions (S5).

### The end signal message

The caller's monitor uses the `:tag` option of `Process.monitor/2`. On OTP 28 the message is:

```elixir
{{:helyx_session_end, id}, ref, :process, pid, reason}
```

A client matches on the tag and calls `Session.end_reason/1` to get `:stopped` or `:crashed`. The reference and the pid in this one message are not contract values: `subscribe/1` owns the monitor lifecycle (S5, S6). A remote transport still sends the end signal as its last event.

### Contract changes

- `contract_version` goes from 1 to 2, because the end signal changes shape (ADR 0006 §5). If the one-provider change (`one-provider-path.md`) lands in the same release, the two share one increase.
- ADR 0006 changes in the same PR: §2 states the new end signal and that its reference and pid are not contract values; the text that names the Registry goes; §2 "leaves no registration" becomes "leaves no subscriber entry and no monitor".
- `end-signal.md` gets a note at its top that this doc replaces its Watch and lost-signal design.

## Replaced mechanism

1. Every part of the old mechanism:

| Today | Fate | Replacement or reason |
|---|---|---|
| The events Registry: duplicate keys, 1 partition, a child of Core (`core.ex`, `events_registry/1`) | deleted | The subscriber map in the session (S1, S3) |
| Register first, snapshot second | deleted | Both in one call (S1). The race that the order solved does not exist. |
| At most one registration per caller: leave before join, the process dictionary, the flush of an old signal | changed | In the session: a map from pid to its monitor reference, one monitor per pid (S2, S4). In the caller: one monitor reference per session in the process dictionary, removed with `demonitor(ref, [:flush])` before a new subscribe (S5). |
| `Helyx.Session.Watch`: monitors the session and the subscriber, sends the end signal | deleted | The caller's own tagged monitor of the snapshot pid (S5). The session's monitor of the caller (S4). |
| The lost signal and its supervisor barrier (the Registry supervisor lists a live new partition) | deleted | No separate process can lose the subscription. If the session ends, the end signal comes. |
| The end reasons `:stopped` and `:crashed` | kept | The same mapping, in `Session.end_reason/1` (S5) |
| `{:error, :session_not_found}` with no registration left, also when the session ends during the call | kept | S6 |
| A snapshot call timeout removes the registration, then exits | kept | The ordered `{:unsubscribe, pid}` and the demonitor with flush (S6) |
| The `instance_id` and `seq` rules for the client | kept | S2, S7. The end signal is covered by the monitor lifecycle (S5). |
| A Core stop ends each subscriber that does not trap exits, through the Registry link | changed | No link. A Core stop ends its sessions, and each subscriber gets the end signal `:stopped`. This is the documented signal, so a client is no longer killed. The TUI traps exits today, so it sees no change. The trap for this link goes from `stop/1` in `apps/coding_agent/lib/mix/tasks/helyx.graph.ex` and from the bash test "stopping Core normally ends a running command". |
| The rescue clauses for a Registry that is gone (`ArgumentError`, `ErlangError`) | deleted | No events Registry. The sessions Registry for `pid/1` stays, with its own rescue. |
| The TUI resubscribe on `{:helyx_subscription_lost, id}` | deleted | No lost signal. The TUI matches the tagged end signal. |

2. Removed replies and their guarantees:

- The order "registered before the snapshot" guaranteed that no event between the snapshot and the registration is lost. After the change, the session process sees both the subscribe and every event, and it adds the entry and builds the snapshot in one message (S1).
- The Watch guaranteed one end signal per subscription with the real reason. After the change, the caller's monitor of the exact pid gives the real reason, and the caller holds at most one monitor per session (S5).

3. Tests of the old mechanism, in `test/helyx/session/end_signal_test.exs` unless named:

| Test | Fate |
|---|---|
| "every operation on an id that never existed", "every operation on a session that ended", "every operation on a dead session that is still registered", "every operation after the Core stopped", "input errors win over session_not_found", "a session that stops with the reason :timeout during a call" | kept |
| "a session that ends during the snapshot call" | kept, checks no monitor in place of no registration |
| "a second subscribe keeps one entry, and a failed one removes it" | kept, checks the subscriber map |
| "a subscribe that times out leaves no entry" | kept, checks the subscriber map and the monitors of the session (S6) |
| "a normal stop gives :stopped, after the last event", "a kill and a raise give :crashed", "a Core that stops gives :stopped", "a subscribe that gets a snapshot gets the end signal after it" | kept, with the new message shape |
| "a subscribe that fails as the session ends leaves no signal and no watch" | kept, checks no signal and no monitor |
| "a subscribe to a session that never ran starts no watch" | kept, checks no monitor |
| "a restart of the events Registry (…) gives a lost signal, and the session runs", "a subscribe after a restart stops the old watch that has not signalled", "the lost signal waits for a new partition, not for an answer of the supervisor", "a stopped events Registry gives the lost signal at once" | deleted: no events Registry |
| "a second subscribe replaces the watch", "a subscribe removes the entries of dead watches and keeps their signals", "a subscriber that exits stops its watch" | replaced by the new tests below that prove the same properties for the monitors |
| `plugins/bundled/test/helyx/tui_test.exs`, the test that asserts `{:helyx_subscription_lost, id}` | deleted |
| `test/support/shared/late_client.ex` (`Helyx.Test.LateClient`) | kept: it matches no end signal |
| "a subscribe while the Core stops" | kept: the window is now a stopped sessions Registry, where `pid/1` gives nil |
| `test/helyx/session/instance_test.exs`, "a subscriber that keeps its entry across a resume can tell the new instance" | changed (found in the build): the entry of a subscriber ends with the session process, so the test checks that the resumed process has no subscriber, subscribes again, and checks the new instance and `seq` |
| `plugins/bundled/test/helyx/tui_test.exs`, "an event of a resumed instance does not change the screen of the old one (#204)" | changed (found in the build): the old screen gets the events of the new instance only through a later subscribe of its process, so the test subscribes again before it applies them to the old screen |

New tests:

- Subscribe and events in one step under load: no event is lost or doubled.
- A second subscribe gives each event once and one end signal.
- Repeated subscribe and unsubscribe calls from one caller leave at most one monitor in the session (`Process.info(session_pid, :monitors)`), and none after the last unsubscribe.
- A subscribe that times out leaves no entry and no monitor, and a later subscribe drops the events in between by `seq`.
- A subscribe after a resume of the same id gets no end signal of the old process.
- A subscriber that dies is removed from the map.
- A subscribe to another session keeps the end signal of the first.
- The entries of ended sessions go at the next subscribe.
- A subscribe after a resume drops the signal of a forgotten entry (one that an earlier subscribe removed).

4. What clients see: the lost signal is gone; the end signal has the shape above; `contract_version` is 2. Users see no change.

5. States with no bound: the number of subscribers of one session, as today.

## Bounds

| What | Bound | Over the bound |
|---|---|---|
| Subscribers of one session | unbounded, as today, ticket #116 (flow control) | — |
| Monitors held by the session | one per subscriber pid (S2) | a repeated subscribe reuses the monitor |
| Monitors held by a caller | one per `{core, id}` (S5) | a new subscribe removes the old one with flush |
| Dictionary entries of a caller | one per `{core, id}` whose session the caller monitored at its last subscribe (S5) | the next subscribe removes the entries whose monitor has fired |
| The flush of end signals at a subscribe | one scan of the caller's mailbox, with no wait (`after 0`) | — |
| The prune at a subscribe | one read of the caller's monitor list and one pass over its dictionary | — |
| The subscribe call | the timeout of `call_pid/3`, as today | the exit goes on after cleanup (S6) |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
|---|---|---|---|---|---|
| The session's monitor of a subscriber | `{:subscribe, pid}` | the session | `{:unsubscribe, pid}`, demonitor with flush | the session ends, so its monitors end | — |
| The caller's monitor of the session | `subscribe/1` | the caller | the end signal, or the next subscribe | the caller ends, so its monitors end | a failed subscribe (S6) |

## Out of scope

- Flow control for slow subscribers: #116 keeps that part. Its Registry-restart part is done by this feature.
- A server buffer that replays events after a `seq` (ADR 0006 §3).

## Decisions

- **Q2, the end signal (2026-10-02):** A, a tagged monitor. Option B kept `{:helyx_session_end, id, reason}` exactly, with no contract change, but a process must translate the `:DOWN` into that message, so a small Watch stays and only the lost signal, the barrier, and the Registry go.
