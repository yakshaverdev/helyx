# Session snapshot

## Goal

A client that subscribes to a session gets the state of the session at that moment, then every later event, with no gap and no duplicate. Issue #163.

User story: I run `mix helyx --resume`. I see the earlier messages and tool calls, then the live turn. A second client that attaches in the middle of a reply shows the reply so far, then streams the rest.

## Interface

`Helyx.Session.subscribe/2` returns `{:ok, snapshot, ref}` (`end-signal.md`). `Helyx.Session.Snapshot` lists its fields.

The order that makes it gap-free:

1. `subscribe/2` makes one call to the session. The session adds the caller to its subscribers and builds the snapshot in the same handler (`session-subscribers.md`, S1).
2. The session sends its events from its own process in `seq` order, so each event after the snapshot has a larger `seq` and reaches the client.
3. A client that reconnects drops the events that the snapshot already holds (`session-instance.md`).

`Helyx.TUI.ViewModel.from_snapshot/1` folds the snapshot messages through the live fold, so the live and snapshot paths share one pairing rule.

- The rule of a snapshot and its exclusions are in ADR 0006, section 3, as revised on 2026-10-17 (ADR 0008): a snapshot equals the loaded suffix of the transcript plus the full current state.
- **Tail.** `subscribe(session, tail: n)`, with `n` from 1 to 1,000, gives a tail snapshot (ADR 0008 §4, #658). `subscribe(session)` gives the whole transcript; the TUI subscribes over the wire from #809 (`docs/features/wire-protocol.md`, Replaced mechanism 1). Any other option list is `{:error, :invalid_limit}`, checked before the session is called. The wire default of 200 is the transport's: Core has no default tail.
- **Cut.** The session takes the newest messages while the count stays at most `n` and the sum of `:erlang.external_size/1` of the messages at most 16 MiB. Then it drops the oldest messages of that run while the first one is a tool result, so an assistant message and its tool results stay in one page: the TUI fold crashes on a result with no call (`Helyx.TUI.ViewModel`). When that leaves no message, the tail is the newest group alone: the last user or assistant message and the messages after it, whatever their count and size. So a cut never fails and never drops content of a message it holds. `more` is true when older messages exist. A full snapshot has `more: false`.
- **State fields.** The snapshot carries `usage` (`Helyx.Session.Totals`: the four token sums, the known cost, `unknown`, `list`) and `context` (the estimate: the `context_tokens`, window, and model of the last usage whose `context_tokens` is an integer, and the bytes of the text, the thinking, and the tool calls after it, or nil before such a usage). A usage with nil `context_tokens` does not start a new estimate: its message adds its bytes. A tool call counts the bytes of its name and of its JSON arguments. This is the rule of the estimate of `Helyx.Compaction.Summary` with no summary (`summary-compaction.md`, "The estimate of the bundled plugin"), so the footer and the compaction trigger read the same tokens for one transcript (#698). The two are separate short functions, not one shared helper: Core does not call a plugin. The fold applies the last compaction of the session after the message before it, as the `:compaction` event changes the live estimate (`usage-and-limits.md`, "The footer", #697, #712). The session keeps that compaction, the id of the last transcript message before it and its `tokens_after`, from the compaction or the summary. Its entry in the file names that id (`last_id`), and a resume reads it from the last compaction or summary entry: the interrupted result of a resume is not on disk, so the place of the entry does not tell the message. The estimate itself is not stored. With no message before it, a compaction changes no estimate, so none is kept. The session folds every message of its transcript into them at each subscribe, also when the tail leaves the last usage out. So they are fields, not derived by the client from the messages. `Helyx.TUI.ViewModel.from_snapshot/1` takes them from the snapshot and folds the snapshot messages into cells only; each later `message_end` and `tool_execution_end` adds its message with `Helyx.Session.Totals.add/2` and `context/2`, the rule that the session uses. A fold at each subscribe derives the values from the transcript, so no stored sum can go out of step with it.
- **History.** `Helyx.Session.history(session, instance_id, before, limit: n)` returns `{:ok, %{messages: messages, more: more, next: next}}`: the messages of the live transcript before the message with id `before`, oldest first, with the cut of the tail, `limit` (1 to 1,000, default 200) in place of `tail`. The live transcript holds the unsaved messages and the interrupted results of a resume (`Helyx.Session.Transcript.repair/1`). Another `instance_id` than the session's gives `{:error, :instance_changed}`, an id that no message of the transcript has `{:error, :unknown_message}`, and a bad option list `{:error, :invalid_limit}`. `next` is the explicit cursor of the page before it: the id of its first message while `more` is true, else nil. The cursor of a tail snapshot is the id of its first message. A page reads the transcript only: it changes no total, no context state, no `seq`, and no subscription. A page ends right before `before`. With a cursor that Core gave (`next`, or the first id of a tail), that is a user or an assistant message, so the group stays whole. With the id of a tool result, the page ends inside that group: its call shows as open in the page, and the rest of the group is in the messages that the client holds. No result is ever in a page without its call.
- **Replay** (#659, `replay-ring.md`): a client that reconnects subscribes with `after: {instance_id, seq}` of the last event it applied and gets the later events from the replay ring of the session; it gets a new snapshot only when the ring cannot serve them. Step 3 above is for that snapshot.
- The `turn` of a snapshot has `elapsed_ms`: the time since the turn started, by the monotonic clock of the session, also while its `turn_end` waits for the hands. A client that joins a running turn starts its busy clock at that age by its own clock, so it needs no clock of the server. The age does not count the transport delay after the snapshot.
- The information cell "resumed session" follows the history only when the TUI started from a resume: `mix helyx --resume` passes `resumed: true` to `Helyx.TUI.run/1`, and the mount adds the cell. A live join shows no such cell.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| tail snapshot and page, count | 1 to 1,000 messages; or the newest group alone | `Helyx.Session.History` | another value, or another option: `{:error, :invalid_limit}`; a cut over the count ends the tail |
| tail snapshot and page, bytes | 16,777,216 bytes of message content by `:erlang.external_size/1`; or the newest group alone (one assistant message of at most 8 MiB and 1,024 blocks and its results, `docs/features/wire-protocol.md`, "Bounds") | `Helyx.Session.History` | the tail ends before the message that passes the bound |
| usage fold at a subscribe | one step for each transcript message, the same transcript the full snapshot copies | `Helyx.Session.Totals.of/2` in the session process | n/a: the subscribe waits; the call timeout below applies |
| page lookup of `before` | one scan of the transcript | `Helyx.Session.History` | n/a |
| transcript in the full snapshot | no bound of its own. A resumed transcript comes from a session file of at most 64 MiB (row "Session file on resume" of `docs/features/coding-agent.md`). A live transcript grows by the turns of the human, as the TUI cell list does (row "TUI cell list") | the session file read; the human | n/a: the reply is one copy into the client's heap |
| snapshot call and page call | `GenServer.call` with the default 5,000 ms timeout. The session never blocks on a call (#93), so the wait is the time to fold the totals, cut the transcript, and copy the reply | `Helyx.Session.subscribe/2`, `Helyx.Session.history/4` (`Helyx.Session.Call`) | the caller exits with a timeout, as for every other session call |
| TUI render of the history | the same as live cells: one cell for each message, tool call, and notice. The render bounds of the TUI (wrap, scrollback) apply unchanged | `Helyx.TUI.ViewModel` | n/a |
| TUI open positions (`open` of `Helyx.TUI.ViewModel`) | one queue entry for each open tool cell; a result removes its entry, and an empty queue removes its key. So the map holds the calls with no result, at most the calls of the transcript | `Helyx.TUI.ViewModel` | n/a |
| TUI mount: the snapshot fold | no bound of its own: one fold step for each snapshot message; each new cell and each result costs O(log n). Measured on 2026-10-03 at 300,000 cells: 3.0 to 6.5 s (`plugins/bundled/bench/view_model.exs`). A 64 MiB session file bounds a resumed transcript | `Helyx.TUI.ViewModel.from_snapshot/1` | n/a: the mount waits |

## Replaced mechanism

1. **The usage fold of the TUI.** `Helyx.TUI.SessionUsage` folded every snapshot message and every live message. Now `Helyx.Session.Totals` holds the same rule in Core. The session folds its transcript at each subscribe into `usage` and `context`, and the view model folds only the live messages with `Totals.add/2` and `context/2`. `context_percent/2` moved to `Helyx.TUI.Footer`, its one caller. The values do not change: `footer_usage_test.exs` checks the live path against the snapshot path for each case.
2. **The subscribe request.** `{:subscribe, pid}` is now `{:subscribe, pid, tail}`, with nil for the full snapshot. The rule of S1 stays: one handler adds the subscriber and builds the snapshot.
3. **The call helpers** of `Helyx.Session` (`call/3`, `call_pid/3`, the deadline) moved to `Helyx.Session.Call` with no change: the module owns the call decision (the deadline, the timeout exit, the not-found answer) for the subscribe, the page, and the other calls.
4. Users see no change: the TUI subscribes with no tail, and its footer shows the same values. A product in the node sees the new snapshot fields `more`, `usage`, and `context`; a tolerant reader ignores them.
5. No new state: the totals are derived at each subscribe, and a page stores nothing.

## Ownership

No external resource.

## Out of scope

- The wire codec of the tail, the page, and the totals: #660.
- Paging inside one message body: parts carry any size (ADR 0008 §2).
- Pages in the TUI: it subscribes over the wire with the default tail of 200 (#809), and asks for no older page.
- A compact render of old turns.
