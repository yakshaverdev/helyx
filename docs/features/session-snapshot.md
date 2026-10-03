# Session snapshot

> Since #297 (`session-subscribers.md`), the session holds its subscribers: `subscribe/1` adds the caller and builds the snapshot in one call, and the events Registry named below is gone.

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
  contract_version: pos_integer(), # 2 now (#297); the rules are in ADR 0006, section 5 (#190)
  instance_id: String.t(),         # the session instance; events of another instance are dropped (#204)
  seq: non_neg_integer(),          # the seq of the last event sent before the snapshot; 0 if none
  messages: [Helyx.Message.t()],   # the transcript, oldest first
  turn: nil | %{
    id: String.t(),
    partial: Helyx.Message.t() | nil,   # the assistant message so far, as Turn.assistant_message/2 builds it
    running: [String.t()]               # ids of the tool calls that have started and have no result yet
  },
  model: String.t(),
  queue: %{steers: non_neg_integer(), follow_ups: non_neg_integer()}
}
```

The order that makes it gap-free:

1. `subscribe/1` registers the caller in the events Registry, as today.
2. It then calls the session (`GenServer.call`, `:snapshot`) for the snapshot.
3. The client applies the snapshot, then drops each event of another `instance_id` (#204) and each event with `seq <= snapshot.seq`, and applies the rest.

The session sends its events from its own process in `seq` order, and the snapshot reply is built in the same process. So each event after the snapshot has a larger `seq` and reaches the client, which registered before the call. An event sent between the registration and the snapshot is in the snapshot and has a `seq` at or below it.

`Helyx.TUI.ViewModel`:

- `ViewModel.from_snapshot(snapshot)` builds the cells from the messages with the same cell shapes as the live events: text, thinking, and each tool call with its result. The started calls are always the first calls with no result, in call order, so the view model gives open cells to the first `length(turn.running)` calls with no result, by position. A call that has not started and has no result gets no cell until it starts, also when it has the id of a running call (review of 2026-09-26). A live client adds a tool cell at `tool_execution_start`, and a local turn starts its calls one at a time (an external turn starts them all at once), so such a call has no cell in either client. It is still in the copied assistant message, and its cell comes with its start event, or as a closed cell with its result.
- The rule: the transcript cells from a snapshot at `seq` equal the transcript cells folded from every event up to `seq`, and so do the model, the queue counts, the streaming message, and the run state. The rule does not cover what is not in the transcript: notices and the partial reply of an aborted or failed turn (owner decision, 2026-09-26; ADR 0006). Notices ("aborted", "error: ...", the harness notices, "resumed session") are not in the transcript, so a snapshot does not rebuild them. The partial reply of a failed turn is display-only too: `fail_turn` emits `message_end` for it with `error`, but does not add it to the transcript, so a live client shows it and a late client does not (owner decision, 2026-09-26). An abort closes the partial reply with `message_end` and the stop reason `aborted`. That reply is also not in the transcript, so a late client does not show it. Since #385 these two rules hold only for a partial reply with text only: a partial reply with a tool call joins the transcript with stop `:tool_use`, its calls get `tool_execution_start`, and then their `aborted` results. A result goes to the oldest open call with its id in the session, in the snapshot, and in the live fold. A call that never started and got a result in the transcript shows a closed cell with that result in both paths. The session gives such `aborted` results after an abort, after a failed turn, and at the normal end of an external turn whose last message has calls (`end_turn/2` calls `abort_open_calls/1`, and no `tool_execution_start` comes for these calls; after an abort or a failure, the calls of a partial reply that holds a call get `tool_execution_start` first, #385). The live fold gives a result with no open cell to the next call with its id in the last assistant message, after the cells of that id: no message goes between a call and its result. This was an accepted limit until 2026-10-02 (#305, owner decision; ADR 0006).
- The notice "resumed session" follows the history only when the TUI started from a resume: `mix helyx --resume` passes `resumed: true` to `Helyx.TUI.run/1`, and the mount adds the notice. A live join shows no notice. The model comes from the snapshot.
- The view model keeps `seq`, and `apply/2` drops an event with `seq <= seq`.

Callers of `subscribe/1` change from `:ok = ` to `{:ok, _} = ` or use the snapshot: `Helyx.TUI`, `mix helyx.graph`, the moduledoc example, and the tests.

Changes that follow from the snapshot (accepted by the owner, 2026-09-26):

- `Helyx.TUI.run/1` has no `:model` option, and `CodingAgent.fetch_model/1` is gone: the model comes from the snapshot.
- The TUI mount checks that the session is alive before it subscribes, because the subscribe now calls the session. A session that dies in between ends the mount with `{:session_down, reason}`, as before. #188 replaces the check: `subscribe/1` returns `{:error, :session_not_found}` (`docs/features/session-not-found.md`).
- Tests that folded events with `seq` 0, or with one `seq` twice, use increasing values, because `apply/2` now drops an event at or below the view model's `seq`.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| transcript in the snapshot | no bound of its own. A resumed transcript comes from a session file of at most 64 MiB (row "Session file on resume" of `docs/features/coding-agent.md`). A live transcript grows by the turns of the human, as the TUI cell list does (row "TUI cell list") | the session file read; the human | n/a: the reply is one copy into the client's heap |
| snapshot call | `GenServer.call` with the default 5,000 ms timeout. The session never blocks on a call (#93), so the wait is the time to build and copy the reply | `Helyx.Session.subscribe/1` | the caller exits with a timeout, as for every other session call |
| TUI render of the history | the same as live cells: one cell for each message, tool call, and notice. The render bounds of the TUI (wrap, scrollback) apply unchanged | `Helyx.TUI.ViewModel` | n/a |

Tests: for a local turn with three tool calls, a subscribe while the first call runs gives the same view model, without notices, as the fold of every event up to the snapshot, and each later call gets one cell when it starts; the same for an external turn; a subscribe during a running turn with events before and after the snapshot shows each event once; a subscribe after a resume shows the history cells, then the notice only with `resumed: true`; a subscribe after a failed turn with a partial reply, and after an abort during a partial reply with text only, gives the transcript cells of the live fold without notices and without the partial reply, and no event with `seq <= snapshot.seq` changes that view model; a subscribe after an external turn that ends with a tool call and `:done`, and after an abort of three local calls, gives the view model of the live fold, with a closed `aborted` cell for each call that never started; a subscribe to a session with no events has `seq` 0 and no notice.

## Ownership

No new resource. The Registry entry is the same as today.

## Out of scope

- Paging of a long transcript for a remote client: the transport work, #116.
- A resubscribe after a restart of the events Registry: #116.
- A compact render of old turns.
- A read of the transcript without a subscription. Add a function when a caller needs it.
