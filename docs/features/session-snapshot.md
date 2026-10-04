# Session snapshot

## Goal

A client that subscribes to a session gets the state of the session at that moment, then every later event, with no gap and no duplicate. Issue #163.

User story: I run `mix helyx --resume`. I see the earlier messages and tool calls, then the live turn. A second client that attaches in the middle of a reply shows the reply so far, then streams the rest.

## Interface

`Helyx.Session.subscribe/1` returns `{:ok, snapshot, ref}` (`end-signal.md`). `Helyx.Session.Snapshot` lists its fields.

The order that makes it gap-free:

1. `subscribe/1` makes one call to the session. The session adds the caller to its subscribers and builds the snapshot in the same handler (`session-subscribers.md`, S1).
2. The session sends its events from its own process in `seq` order, so each event after the snapshot has a larger `seq` and reaches the client.
3. A client that reconnects drops the events that the snapshot already holds (`session-instance.md`).

`Helyx.TUI.ViewModel.from_snapshot/1` folds the snapshot messages through the live fold, so the live and snapshot paths share one pairing rule.

- The rule of a snapshot and its exclusions are in ADR 0006, section 3.
- The information cell "resumed session" follows the history only when the TUI started from a resume: `mix helyx --resume` passes `resumed: true` to `Helyx.TUI.run/1`, and the mount adds the cell. A live join shows no such cell.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| transcript in the snapshot | no bound of its own. A resumed transcript comes from a session file of at most 64 MiB (row "Session file on resume" of `docs/features/coding-agent.md`). A live transcript grows by the turns of the human, as the TUI cell list does (row "TUI cell list") | the session file read; the human | n/a: the reply is one copy into the client's heap |
| snapshot call | `GenServer.call` with the default 5,000 ms timeout. The session never blocks on a call (#93), so the wait is the time to build and copy the reply | `Helyx.Session.subscribe/1` | the caller exits with a timeout, as for every other session call |
| TUI render of the history | the same as live cells: one cell for each message, tool call, and notice. The render bounds of the TUI (wrap, scrollback) apply unchanged | `Helyx.TUI.ViewModel` | n/a |
| TUI open positions (`open` of `Helyx.TUI.ViewModel`) | one queue entry for each open tool cell; a result removes its entry, and an empty queue removes its key. So the map holds the calls with no result, at most the calls of the transcript | `Helyx.TUI.ViewModel` | n/a |
| TUI mount: the snapshot fold | no bound of its own: one fold step for each snapshot message; each new cell and each result costs O(log n). Measured on 2026-10-03 at 300,000 cells: 3.0 to 6.5 s (`plugins/bundled/bench/view_model.exs`). A 64 MiB session file bounds a resumed transcript | `Helyx.TUI.ViewModel.from_snapshot/1` | n/a: the mount waits |

## Ownership

No external resource.

## Out of scope

- Paging of a long transcript for a remote client: the transport work, #116.
- A compact render of old turns.
- A read of the transcript without a subscription. Add a function when a caller needs it.
