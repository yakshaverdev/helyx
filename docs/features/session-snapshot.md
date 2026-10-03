# Session snapshot

> Since #297 (`session-subscribers.md`), the session holds its subscribers: `subscribe/1` adds the caller and builds the snapshot in one call, and the events Registry named below is gone.
>
> The ADR 0006 revision of 2026-10-03 (#404) replaces these parts below: `contract_version` and `turn.running` leave the snapshot; the TUI makes its tool cells from the messages and folds the snapshot messages through the live fold, so the bulk construction of `from_snapshot/1` and its pairing by `running` go; the TUI drops the `instance_id` and `seq` guards, because it subscribes once and the registration and the snapshot happen in one server handler. The tickets after #404 build this. #405 built the tool cells from the messages and removed `turn.running`, the pairing by `running`, and the closed cell for a result with no open cell (every call now has an open cell from its message, so such a result has no call). #406 removed `contract_version` and the TUI `instance_id` and `seq` guards. #407 removed the bulk construction of `from_snapshot/1`: the snapshot messages go through the live fold (section "Replaced mechanism (#407)"). The rule of the snapshot stays.

## Goal

A client that subscribes to a session gets the state of the session at that moment, then every later event, with no gap and no duplicate. Issue #163, split from #105. Parent: #115.

User story: I run `mix helyx --resume`. Today the screen is empty, but the agent answers as if it remembers everything. With this feature I see the earlier messages and tool calls, then the live turn. A second client that attaches in the middle of a reply shows the reply so far, then streams the rest.

Today `Helyx.Session.subscribe/1` only registers the caller in the events Registry. No client API reads the transcript. The TUI mounts with an empty view model. v2 had `Agent.messages/1` for the same need (the v2 comparison of 2026-09-26); the snapshot covers it.

The server owns the state, and the client only renders it (`AGENTS.md`, Project). So the snapshot holds everything the TUI shows: the transcript, the running turn, the model, and the queue counts.

## Interface changes

`Helyx.Session.subscribe/1` returns the snapshot:

```elixir
@spec subscribe(t()) :: {:ok, Helyx.Session.Snapshot.t()}
```

`Helyx.Session.Snapshot`, a new struct in core (`lib/helyx/data/`):

```elixir
%Helyx.Session.Snapshot{
  contract_version: pos_integer(), # 2 now (#297); replaced by the ADR 0006 revision of 2026-10-03, which removes it
  instance_id: String.t(),         # the session instance; events of another instance are dropped (#204)
  seq: non_neg_integer(),          # the seq of the last event sent before the snapshot; 0 if none
  messages: [Helyx.Message.t()],   # the transcript, oldest first
  turn: nil | %{
    id: String.t(),
    partial: Helyx.Message.t() | nil    # the assistant message so far, as Turn.assistant_message/2 builds it
  },
  model: String.t(),
  queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
}
```

The order that makes it gap-free:

1. `subscribe/1` registers the caller in the events Registry, as today.
2. It then calls the session (`GenServer.call`, `:snapshot`) for the snapshot.
3. The client applies the snapshot, then drops each event of another `instance_id` (#204) and each event with `seq <= snapshot.seq`, and applies the rest. A client that reconnects keeps this step. The TUI subscribes once, so it skips the drops (ADR 0006 revision of 2026-10-03).

The session sends its events from its own process in `seq` order, and the snapshot reply is built in the same process. So each event after the snapshot has a larger `seq` and reaches the client, which registered before the call. An event sent between the registration and the snapshot is in the snapshot and has a `seq` at or below it.

`Helyx.TUI.ViewModel`:

- Replaced by the ADR 0006 revision of 2026-10-03, which folds the snapshot messages through the live fold: `ViewModel.from_snapshot(snapshot)` builds the cells from the messages with the same cell shapes as the live events: text, thinking, and each tool call with its result. The started calls are always the first calls with no result, in call order, so the view model gives open cells to the first `length(turn.running)` calls with no result, by position. A call that has not started and has no result gets no cell until it starts, also when it has the id of a running call (review of 2026-09-26). A live client adds a tool cell at `tool_execution_start`, and a local turn starts its calls one at a time (an external turn starts them all at once), so such a call has no cell in either client. It is still in the copied assistant message, and its cell comes with its start event, or as a closed cell with its result.
- The rule: the transcript cells from a snapshot at `seq` equal the transcript cells folded from every event up to `seq`, and so do the model, the queue counts, the streaming message, and the run state. The rule does not cover what is not in the transcript: notices and the partial reply of an aborted or failed turn (owner decision, 2026-09-26; ADR 0006). Notices ("aborted", "error: ...", the harness notices, "resumed session") are not in the transcript, so a snapshot does not rebuild them. The partial reply of a failed turn is display-only too: `fail_turn` emits `message_end` for it with `error`, but does not add it to the transcript, so a live client shows it and a late client does not (owner decision, 2026-09-26). An abort closes the partial reply with `message_end` and the stop reason `aborted`. That reply is also not in the transcript, so a late client does not show it. Since #385 these two rules hold only for a partial reply with text only: a partial reply with a tool call joins the transcript with stop `:tool_use`, its calls get `tool_execution_start`, and then their `aborted` results. A result goes to the oldest open call with its id in the session, in the snapshot, and in the live fold. A call that never started and got a result in the transcript shows a closed cell with that result in both paths. The session gives such `aborted` results after an abort, after a failed turn, and at the normal end of an external turn whose last message has calls (`end_turn/2` calls `abort_open_calls/1`, and no `tool_execution_start` comes for these calls; after an abort or a failure, the calls of a partial reply that holds a call get `tool_execution_start` first, #385). The live fold gives a result with no open cell to the next call with its id in the last assistant message, after the cells of that id: no message goes between a call and its result. This was an accepted limit until 2026-10-02 (#305, owner decision; ADR 0006). The ADR 0006 revision of 2026-10-03 replaces the TUI cell rules of this item: each call of the streaming message and each call with no result shows an open cell labelled "awaiting result", a result closes its cell, and the TUI does not read `tool_execution_start`. The session behaviour in this item stays.
- The notice "resumed session" follows the history only when the TUI started from a resume: `mix helyx --resume` passes `resumed: true` to `Helyx.TUI.run/1`, and the mount adds the notice. A live join shows no notice. The model comes from the snapshot.
- The view model keeps `seq`, and `apply/2` drops an event with `seq <= seq`. Replaced by the ADR 0006 revision of 2026-10-03: the TUI drops this guard.

Callers of `subscribe/1` change from `:ok = ` to `{:ok, _} = ` or use the snapshot: `Helyx.TUI`, `mix helyx.graph`, the moduledoc example, and the tests.

Changes that follow from the snapshot (accepted by the owner, 2026-09-26):

- `Helyx.TUI.run/1` has no `:model` option, and `CodingAgent.fetch_model/1` is gone: the model comes from the snapshot.
- The TUI mount checks that the session is alive before it subscribes, because the subscribe now calls the session. A session that dies in between ends the mount with `{:session_down, reason}`, as before. #188 replaces the check: `subscribe/1` returns `{:error, :session_not_found}` (`docs/features/session-not-found.md`).
- Tests that folded events with `seq` 0, or with one `seq` twice, use increasing values, because `apply/2` now drops an event at or below the view model's `seq`.

## Replaced mechanism (#405)

The ADR 0006 revision of 2026-10-03 replaces the TUI rule that a tool cell comes from `tool_execution_start`. Built from the code and the tests of master `4685a02`.

| Old part | Replacement or deletion |
| --- | --- |
| `fold` clause for `tool_execution_start` adds an open cell | Deleted. The event is ignored (only `seq` moves). The `message_end` of an assistant message adds an open cell for each of its calls, and a `message_update` with a call adds an open cell to `streaming` |
| `unstarted_cell/2`: a result with no open cell gives a closed cell to the next call with its id in the last assistant message | Deleted. Every call has an open cell from its message, and Core sends a result only for an open call of its transcript (`Transcript.open_calls/1`), so such a result makes no cell |
| `from_snapshot/1` opens the first `length(turn.running)` calls with no result, by position; a later call has no cell | Every call with no result gets an open cell. #407 replaced the pairing of results to calls (`results_in_call_order/1`) with the live fold |
| `Snapshot.turn.running` and `Turn.snapshot/2` | Deleted: no client reads it. `Turn.snapshot/1` gives `id` and `partial` |
| Label "… running" | "… awaiting result": the message proves that the call exists, not that it runs |
| A call of the streaming message renders nothing | An open cell after the streaming message, as after an ended one |

Tests of the old mechanism:

- "a result for a call that never started gets a closed cell": deleted, its case is gone.
- "a start, end, start, end order attaches each result": deleted; "a result goes to the oldest open cell and never replaces a result" covers one id in two messages.
- The case "two open cells with one id" of that test moved into "a result goes to the oldest open tool cell with its id".
- The tests that made open cells with `tool_execution_start` make them with an assistant `message_end`; their properties (oldest open cell first, any result order, no second result, a notice between) stay.
- The assertions on `snapshot.turn.running` (`stream_events_test.exs`, `view_model_snapshot_test.exs`) are deleted; the snapshot tests compare the joined client with the live client and check the three open cells.
- New: a scripted fold and a real session (`gated/harness`) show "awaiting result" for a call of the open message before its result.

## Replaced mechanism (#407)

The ADR 0006 revision of 2026-10-03 folds the snapshot messages through the live fold. Built from the code and the tests of master `277f346`.

| Old part | Replacement or deletion |
| --- | --- |
| `from_snapshot/1` bulk construction: `history/2`, `results_in_call_order/1`, and the zip of calls with results | Deleted. `from_snapshot/1` folds each message with `add_message/2`, the function of `apply/2` for `message_end` and `tool_execution_end` |
| `cells` as a list; a new cell appended with `++`; a result found with `Enum.find_index/2` and set with `List.update_at/3` | `cells` is an Erlang `:array` by position; the array size is the next free position. `open` maps a call id to a queue of the positions of its open cells, oldest first. Each new cell and each result costs O(log n) in the cell count, with no list scan |
| A result with no open cell makes no cell | It crashes (`Map.fetch!/2`): since #385 a call's message closes before its result, since #405 every call has a cell from the message, and the live session records a result only for an open call (`Transcript.open_calls/1`). Open hole, found in the review of #407: a resumed transcript can hold a result with no open call when the session file was edited by hand (a result whose id names no call, or a result after a later message). A crash cuts only the last line, and the read takes the entries under an assistant line that does not decode off the branch, so no case without an edit was found. The resume keeps such a result (`Transcript.abort_unanswered/2`), and the TUI then crashes at each mount of that session. The fix belongs at the resume boundary in Core and waits for an owner decision |
| `Helyx.TUI.Transcript` reads the cell list | It folds the array in position order, O(n) per frame as the list walk was, and adds the streaming message after it |

Tests of the old mechanism:

- "a result for an unknown call changes nothing" and the case "a second result for a closed cell changes nothing": replaced by "a result with no open cell crashes".
- "a result goes to the oldest open cell and never replaces a result": its case of one id in two messages stays, with the results after both messages as a second case.
- New: "a snapshot equals the live fold of the same messages", with a repeated id and results out of call order.
- The tests read the cells with `ViewModel.cells/1`. The comparisons of a joined client with a live client stay; `transcript/1` of `Helyx.Test.ViewModelRule` compares the cells as lists and leaves out the open positions, which a dropped notice moves.

`plugins/bundled/bench/view_model.exs` measures a long transcript. It is not a test and asserts nothing. Measured on 2026-10-03 on a shared development machine, one round is three cells:

| Cells | Live fold | Snapshot fold | One frame | Live fold before #407 |
| --- | --- | --- | --- | --- |
| 3,000 | 10 to 18 ms | 4 ms | 1 to 4 ms | 47 ms |
| 30,000 | 76 to 92 ms | 69 to 74 ms | 0.5 to 1 ms | 6,556 ms |
| 300,000 | 7.2 to 12.2 s | 3.0 to 6.5 s | 4 to 8 ms | not measured |

From 30,000 to 300,000 cells the live fold grows by about 80 to 160 times and the snapshot fold by about 40 to 95 times, where O(n log n) predicts about 12 times. A probe of `:array.set/3` alone grows by about ten times, and a profile shows no function whose cost per call grows with the cell count; the cause of the rest is not measured. Each frame time is of one frame, and it varies between runs more than between the sizes.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| transcript in the snapshot | no bound of its own. A resumed transcript comes from a session file of at most 64 MiB (row "Session file on resume" of `docs/features/coding-agent.md`). A live transcript grows by the turns of the human, as the TUI cell list does (row "TUI cell list") | the session file read; the human | n/a: the reply is one copy into the client's heap |
| snapshot call | `GenServer.call` with the default 5,000 ms timeout. The session never blocks on a call (#93), so the wait is the time to build and copy the reply | `Helyx.Session.subscribe/1` | the caller exits with a timeout, as for every other session call |
| TUI render of the history | the same as live cells: one cell for each message, tool call, and notice. The render bounds of the TUI (wrap, scrollback) apply unchanged | `Helyx.TUI.ViewModel` | n/a |
| TUI open positions (`open` of `Helyx.TUI.ViewModel`) | one queue entry for each open tool cell; a result removes its entry, and an empty queue removes its key. So the map holds the calls with no result, at most the calls of the transcript | `Helyx.TUI.ViewModel` | n/a |
| TUI mount: the snapshot fold | no bound of its own: one fold step for each snapshot message; each new cell and each result costs O(log n). Measured at 300,000 cells: 3.0 to 6.5 s (section "Replaced mechanism (#407)"). A 64 MiB session file bounds a resumed transcript | `Helyx.TUI.ViewModel.from_snapshot/1` | n/a: the mount waits |

Tests: for a local turn with three tool calls, a subscribe while the first call runs gives the same view model, without notices, as the fold of every event up to the snapshot, and each later call gets one cell when it starts (since the ADR 0006 revision of 2026-10-03, each call has its cell from the message); the same for an external turn; a subscribe during a running turn with events before and after the snapshot shows each event once; a subscribe after a resume shows the history cells, then the notice only with `resumed: true`; a subscribe after a failed turn with a partial reply, and after an abort during a partial reply with text only, gives the transcript cells of the live fold without notices and without the partial reply, and no event with `seq <= snapshot.seq` changes that view model; a subscribe after an external turn that ends with a tool call and `:done`, and after an abort of three local calls, gives the view model of the live fold, with a closed `aborted` cell for each call that never started; a subscribe to a session with no events has `seq` 0 and no notice.

## Ownership

No new resource. The Registry entry is the same as today.

## Out of scope

- Paging of a long transcript for a remote client: the transport work, #116.
- A resubscribe after a restart of the events Registry: #116.
- A compact render of old turns.
- A read of the transcript without a subscription. Add a function when a caller needs it.
