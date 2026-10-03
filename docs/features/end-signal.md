# End signal

> Replaced in part by `session-subscribers.md` (#297): the session holds its subscribers, the end signal is a tagged monitor of the caller, `{{:helyx_session_end, id}, ref, :process, pid, reason}`, and the events Registry, `Helyx.Session.Watch`, and the lost signal are gone. The Watch and lost-signal design below is history.
>
> The ADR 0006 revision of 2026-10-03 (#404) replaces ADR 0006 section 5: `contract_version` and the TUI unsupported state go, and a client works with one Helyx version. The text below on these items is history.

## Goal

A subscriber learns from one message with data that the session ended, or that its subscription was lost while the session runs. Issue #189, from ADR 0006, section 2 and Consequences, ticket 2.

User story: I use the TUI, and the session behind it ends or crashes. The TUI exits and says why, and the reason is data: `:stopped` or `:crashed`. A remote client gets the same reason as a last event. When the events Registry restarts after a bug, the TUI does not freeze with a screen that no longer changes: it subscribes again and redraws from a new snapshot, and the session keeps its turn.

Today:

- The TUI monitors the session pid (`Session.pid/1`). A pid is not in the contract, and a remote client cannot use it.
- A restart of the events Registry leaves the sessions running, and their events reach no subscriber. A subscriber that does not trap exits ends with the Registry, through the link of `Registry.register/3`. One that traps exits gets an `{:EXIT, pid, reason}` of a Registry partition that it cannot tie to a session (item 1 of #116).

## Decision

A lost subscription gives the subscriber a signal. The client then subscribes again and rebuilds from a new snapshot, and the sessions keep running. This is the reconnect rule of ADR 0006, section 3 (owner decision on #189, 2026-09-26). Not `rest_for_one` (it would end every running session) and not a subscription that outlives a Registry restart (more state for a crash that only a bug can cause).

## Interface changes

### The two messages

A subscriber gets at most one of these for each subscription, and nothing for the subscription after it:

```elixir
{:helyx_session_end, session_id :: String.t(), reason :: :stopped | :crashed}
{:helyx_subscription_lost, session_id :: String.t()}
```

- `:stopped`: the session stopped with `:normal`, `:shutdown`, or `{:shutdown, term}`. A stop of the session, and a stop of its Core, give this.
- `:crashed`: any other exit reason, `:killed` too. The supervisor logs the crash with the full reason, so no reason is lost. The reason term is not in the message, because it can hold a pid, a module, or a stacktrace.
- `{:helyx_subscription_lost, id}`: the events Registry lost the registration, and the session can still run. The client subscribes again (ADR 0006, section 3). The lost signal is sent after the Registry is back (see "The watch"), so the next subscribe finds it. When the Core is gone too, the next subscribe returns `{:error, :session_not_found}`.

A remote transport sends the end signal as a last event and then closes its stream, and a closed stream with no end signal is its lost signal (ADR 0006, section 2). Its format is in its own feature doc.

A new reason value later is a new value within the version when a client that treats it as an end stays correct (ADR 0006, section 5). The TUI treats every value the same: the session ended.

### The watch

`subscribe/1` starts one watch process for each registration: `Helyx.Session.Watch`, internal, `@moduledoc false`. A caller holds at most one registration for a session (#188), and each subscribe replaces it with a new registration and a new watch, so the caller has at most one watch for the session, and it is the watch of its last snapshot. The watch:

1. traps exits and registers itself in the events Registry under the key `{Helyx.Session.Watch, id}`, so it is linked to the Registry partition that holds the subscriber's entry. The events Registry has one partition (the default of `Registry`, set explicitly in `Helyx.Core`), so the two entries are in one partition. Events go to the key `id` only, so the watch gets no event;
2. monitors the session pid that `subscribe/1` read, and the subscriber.

Then:

| The watch gets | It sends to the subscriber | Then |
| --- | --- | --- |
| `:DOWN` of the session | `{:helyx_session_end, id, reason}` | stops |
| `{:EXIT, partition, _}` | `{:helyx_subscription_lost, id}`, after the Registry is back | stops |
| `:DOWN` of the subscriber | nothing | stops |

`GenServer.start/2` starts the watch, with no link and no supervisor: it monitors the session and the subscriber, and it stops when either ends. The one exception is the wait before the lost signal (below): the watch handles the `:DOWN` of the session only after that wait, which ends when the Registry is back or does not come back, when the subscriber ends, or with a kill by the next subscribe of the caller. A Core that stops ends its sessions first (the session supervisor starts after the events Registry, so it stops before it), so every watch sends `:stopped` and stops.

"After the Registry is back": the events Registry supervisor lists a live partition that is not the dead one. The watch asks the supervisor for its children (`Supervisor.which_children/1`). While the answer has the dead pid, `:restarting`, or a new pid that is already dead, it waits 10 ms and asks again. A check of the pid, not the order of the signals: signals from two processes have no order, so the exit of the partition can reach the watch before it reaches the supervisor, and the supervisor then answers before it restarts the partition. A lost signal after that answer made the subscribe that followed return `{:error, :session_not_found}` for a running session (seen under the load of the parallel precommit, #295). Each call has no timeout, for the same reason, and it monitors the supervisor, so it ends with the answer or the exit of the supervisor. When the Registry supervisor is gone (it stopped, or it passed its restart limit), the call fails, and the watch finds the Registry in the children of the Core: while the Core lists a pid or `:restarting` for it, the watch waits and checks again. When the Registry does not come back (the child is `:undefined` or deleted, in the Registry or in the Core, or the Core call fails), the watch sends the lost signal at once, and a subscribe that follows returns `{:error, :session_not_found}`. The wait is bounded by the restart limits of the two supervisors. When the subscriber ends, the watch stops with no signal at its next pause. A call that blocks on a supervisor delays this until the answer; a lost signal sent then goes to a dead process and does nothing.

Cases that the watch does not make safe:

- A product that stops the Registry with `Supervisor.terminate_child/2` and starts it later: the lost signal can come before the start, so a subscribe in between returns `{:error, :session_not_found}` although the session runs. Only the product does this, and it knows.
- A kill of the Registry supervisor: its partitions stop after it, and the Core can start the new Registry before their named tables are gone. The start then fails, and after its restart limit the Core stops. Every session stops too, and each subscriber gets `:stopped`. This is how `Registry` restarts; this change does not alter it.
- A subscribe while the Registry restarts: the table of the dead partition raises, so the subscribe returns `{:error, :session_not_found}` although the session runs, and it removes the caller's old subscription with no lost signal. A client that mounts in this window ends. A second crash of the partition after the last check of the watch and before the subscribe is this case too. A partition that crashes is a bug, and a retry is more code than the window is worth.
- One id in two Cores: the flush of a subscribe matches the id only, and it runs whether or not the caller had an entry. So any subscribe to the id in one Core, also a failed one or the first one there, can remove a signal of the caller's subscription in the other Core. #204 put the instance id in events and snapshots, not in the signals: open, ticket #216, owner decision on the signal shape (`docs/features/session-instance.md`).
- A session that ends while the watch waits before the lost signal: the watch sends the lost signal, not the end signal, and the subscribe that follows returns `{:error, :session_not_found}`. The TUI then ends with `:session_not_found`, not with the reason of the session. The session is gone in both cases, so only the reason is wrong.
- A pid that the node reuses: the dictionary entry of a dead watch stays until the caller's next subscribe, which kills the pid it names. Only a node that uses all its pids in that time reuses one.

### Order

On one node, the end signal comes after every event of the session: the session sends its last event before it dies, and the watch sends the end signal after the `:DOWN` of the session. The same holds for the lost signal and the Registry restart. A client applies the events it has, and then acts on the signal.

### Subscribe

The steps of `subscribe/1`:

1. Read the session pid (`Session.pid/1`). None: remove the caller's registration and stop its watch, as for a failed subscribe (below), and return `{:error, :session_not_found}`, as before.
2. Remove the caller's registration for the id and stop its watch, as for a failed subscribe (below). Start a new watch with the pid of step 1, keep its pid in the caller's process dictionary under `{Helyx.Session.Watch, core, id}`, then register the caller with the pid of the watch as the value of the entry. The dictionary, not the Registry, tells a later subscribe which watch to stop: after a Registry restart the old entry is gone, but the old watch can still wait to send its lost signal. Only the caller subscribes itself, so no other process changes the dictionary entry. The watch registers first. When the Registry restarts between the two registers, the entry of the watch is in the old Registry, and the watch sends a lost signal. The events between the old and the new registration are in the snapshot of step 3.
3. Call the session pid of step 1 for the snapshot. It is the pid the watch monitors, so the snapshot and the end signal belong to one process.

When the snapshot call returns `{:error, :session_not_found}` or exits on its timeout, `subscribe/1` removes the caller's registration (#188) and also kills its watch and waits for its `:DOWN`, and then removes an end signal or a lost signal for the id from the caller's mailbox. The signals of one process arrive in order, so a signal of the watch is in the mailbox before the `:DOWN`, and the dead watch sends nothing more. A kill, not `GenServer.stop/1`: a stop waits while the watch waits before its lost signal. The watch holds no resource, and the Registry removes its entry. When a step raises, `subscribe/1` does the same. Step 2 does the same to the old watch, so a signal of the old subscription that the client has not read goes too: the client subscribes again, and the new subscription gives its own signal.

A subscriber that joins as the session ends gets one of two results:

- `{:ok, snapshot}`, and then the end signal. The watch monitored the session before the snapshot call, and the session answered, so the `:DOWN` comes after the snapshot.
- `{:error, :session_not_found}`, and no end signal.

A subscriber that registered before the session ended keeps its entry until it exits or subscribes again. The watch of a session that ended is gone. When a resume starts a new session with the same id while the old entry stays, that entry has no watch, so the subscriber gets the events of the new session with no end signal for it. A client that acts on the end signal does not keep the entry; a subscribe to the new session replaces it and gets a watch of the new session. The events of the two sessions have the same `seq` values but not the same `instance_id`, so the client drops the events of the new session by the instance rule (#204, `docs/features/session-instance.md`).

### A subscriber that does not trap exits

`Registry.register/3` links the caller to the partition, and this does not change. A subscriber that does not trap exits ends with the partition, as before. A subscriber that traps exits gets the lost signal. The TUI traps exits, because `ExRatatui.Server` does.

### The TUI

- `mount/1` subscribes and keeps no monitor and no pid. `Session.pid/1` is gone from `Helyx.TUI`.
- `{:helyx_session_end, id, reason}` for its session exits the TUI with `{:session_down, reason}`. The events before it are already applied.
- `{:helyx_subscription_lost, id}` for its session subscribes again. The new snapshot replaces the view model (`ViewModel.from_snapshot/1`), and the scroll follows the newest output. The composer keeps its text. `{:error, :session_not_found}` exits with `{:session_down, :session_not_found}`. The snapshot has the contract version of the same build, so a version that does not match crashes the TUI.
- The unsupported state (ADR 0006, section 5) keeps the session handle: the end signal ends it, and the lost signal subscribes again so that the end signal still comes. It renders nothing, so it drops the new snapshot.
- The `:DOWN` clause is gone. A `:DOWN` that plugin code leaves in the TUI process goes to the catch-all clause.

`Session.pid/1` stays in `Helyx.Session` for the product and for a Transport plugin inside the node (ADR 0006, section 2).

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| watches of one caller for one session | one: one for each registration | `Helyx.Session.subscribe/1` | a second subscribe stops the first watch before it starts one |
| process dictionary entries of a caller | one for each live watch of the caller, plus the entries of watches that died since its last subscribe: each subscribe removes the entries of dead watches | `Helyx.Session.subscribe/1` | n/a |
| life of a watch | until the session, the subscriber, or the Registry partition ends, or a later or a failed subscribe kills it | `Helyx.Session.Watch` | n/a |
| signals of one subscription | one: the watch stops after it sends | `Helyx.Session.Watch` | n/a |
| end reason | two atoms | `Helyx.Session.Watch` | every other exit reason is `:crashed` |
| stop of a watch in a subscribe | a kill and one `:DOWN`, no wait for a callback | `Helyx.Session` | n/a |
| the calls of the watch before the lost signal | unbounded, and accepted with no ticket: at most two calls, the events Registry supervisor, then the Core, and each wait ends with the answer or the exit of that supervisor. A wait blocks no other process: the next subscribe of the caller kills the watch, and the subscriber has its old snapshot and events meanwhile. During the wait the watch outlives a subscriber or a session that ends | `Helyx.Session.Watch` | n/a |

## Ownership

No external resource. The watch is a process of the BEAM with no link but its Registry entry. It is released when the session, the subscriber, or the partition ends, or by a failed subscribe; the table above has each case. A Core that stops ends every session, so no watch outlives its Core.

## Tests

- A normal stop and a crash (`:kill`, and a raise in the session) each give one end signal with `:stopped` or `:crashed`, after the last event.
- A Core that stops gives `:stopped`.
- A subscriber that joins just before the end: the session ends while the snapshot call waits, and the subscribe returns `{:error, :session_not_found}` with no end signal and no watch left; a subscribe that gets a snapshot gets the end signal after it.
- A crash of the partition, and a kill of the Registry supervisor while the Core is suspended, while a session runs: the lost signal waits while the supervisor that restarts the Registry is suspended. Then the subscriber, which traps exits, gets one lost signal, subscribes again, gets the events of the next turn each once, and gets the end signal.
- A second subscribe replaces the watch, also when the first watch is gone, and also when a Registry restart removed the first entry while the first watch waits before its lost signal: no lost signal of the first watch comes.
- A subscribe to a session that never ran starts no watch.
- A subscriber that exits stops its watch.
- The TUI: the end signal exits with the reason; the lost signal rebuilds the view model from a new snapshot; the unsupported state ends on the end signal.

## Out of scope

- Session instance identity: #204, `docs/features/session-instance.md`. See "Subscribe" for a subscriber that keeps its entry across a resume.
- A raise of `contract_version`. It stays 1: the end signal is in the contract of ADR 0006, section 2, which version 1 implements, and the only client of version 1 is the TUI, which this change moves to the signal.
- A remote transport and its last event.
