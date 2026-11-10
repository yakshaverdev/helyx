# Hooks: before settle and the continue turn

Ticket #880, follow-up 2 of ADR 0013 (`docs/adr/0013-hooks.md`, §2, §3, §5, §6). The ADR holds the decisions and their reasons; this doc states the shape that the build adds. The interface and the tool chain are in `docs/features/hooks.md` (#879).

## Goal

A product checks the work at the end of each turn, and when the check fails the session goes on with one more turn that tells the model what failed: a `before_settle` hook answers `{:continue, text}`. The session never waits for a hook in its own process, a broken hook does not stop the session (fail open, ADR 0013 §5), and hooks cannot keep a session busy forever: the turns that hooks start in a row are bounded.

## Interface changes

### `Helyx.Hook`

```elixir
@type settle :: %{session_id: String.t(), turn_id: String.t(), stop_reason: Helyx.Message.stop_reason(), cwd: String.t()}
@callback before_settle(settle()) :: :settle | {:continue, String.t()}
@optional_callbacks before_tool: 1, after_tool: 1, before_settle: 1, release: 3
```

- `Helyx.Hook.points/0` gives `:before_settle` too, so Core start checks its limit as for the other points (`{:invalid_hook_limit, module}`).
- The text of a continue is a string of valid UTF-8 of at most `Helyx.Session.Input.max_text_bytes/0` bytes (4 MiB, the bound of a client text). Any other return is a failed hook.
- **Core start.** A hook plugin that exports `before_settle/1` and whose name, `inspect(module)`, is over 256 bytes stops the start with `{:invalid_hook_name, module}`: the name is the id of the origin of its continue message, and an origin id is at most 256 bytes (`Helyx.Message.origin?/1`). An Elixir alias is at most 248 bytes; only an Erlang module name can pass the bound. The name `{:invalid_hook_name, module}` is set here.

### The origin kind `:hook`

`Helyx.Message.origin()` gets the kind `:hook`, with the name of the hook module as its id (1 to 256 bytes of valid UTF-8, as `:background` and `:product`). `Helyx.Message.origin?/1` takes it, so the session file reader reads it back. The session API still admits only `:product` from product code (`Helyx.Session.Input.origin/1`).

### The wire

The wire `origin` gets the kind `"hook"`, so the protocol number goes from 3 to 4 (ADR 0008 §7, ADR 0013 "Consequences"). The schema in `docs/features/wire-protocol.md`, its SHA-256 in `Helyx.Transport.WebSocket`, and the conformance fixtures follow. The TUI decodes the kind and shows the message as any user message, as it shows a background end.

## The chain

### When it runs

After a turn that ended `done`, not a compaction turn, when at least one hook plugin exports `before_settle/1`. A done turn has a stop reason that the provider gave: `Helyx.Session.Stream.check/1` refuses the stop reasons `:aborted` and `:error` in a provider terminal, so only an abort or a failure ends a turn with them, and neither runs the chain. A turn that the provider started by itself (#240) runs it too: it ended with a stop reason that the provider gave.

The chain is the last part of the wait after the turn (`docs/features/session-lifecycle.md`, "The wait"): it starts when the hands answered the cleanup request, the provider answered, no provider process ends, and no summary call runs, and the wait lasts until its answer. So the chain runs only once the Tasks of the turn are released, and the rules of the wait hold while it runs: a prompt and a follow-up queue as follow-ups, a steer queues as a steer, a compaction waits, and the snapshot shows no turn (its `turn_end` went out) while `sessions.live` gives `running`.

### Where it runs

The session asks the hands with a cast (`Helyx.Session.Hands.Settle.request/4`) and a ref of its own. The hands start one chain Task under the turn id of the ended turn; it runs no plugin code. For each hook in plugin order it asks the hands for a hook Task, as the call Task of a tool call does (`docs/features/hooks.md`, "Hook Tasks of the hands"), with the same limit, kill, hold, release, and refusal after an unconfirmed release. The first `{:continue, text}` ends the chain; a `:settle` and a failed hook go on to the next hook. When the chain Task ends, the hands send the session `{:settle_answer, ref, answer}`: `:settle`, or `{:continue, module, text}`.

- The hook gets `%{session_id, turn_id, stop_reason, cwd}`, where `cwd` is the session's folder, the folder of its tool calls (decision of 2026-11-08 for #883: a check such as a test command runs in the project; prior art cited with the decision: Claude Code passes `cwd` in every hook input, `Stop` included). Its context (`Helyx.Tool.context/0`) is the one of a call of the ended turn with `tool` and `call_id` nil: the Core, the session id, the tool names, the model of the turn, the provider options, and the ModelContext plugin.
- `Helyx.Hook.ask/1` from a `before_settle` hook gets `{:error, :not_running}` (ADR 0013 §3, "a `before_settle` hook too in the first version"): the session runs no turn, and keeps no record of the Task.
- One chain at a time: the session asks for it once per wait, and a new turn starts only after its answer or after the cancel that ends it.

### The answer

- `:settle`: the wait ends, and the session takes its queues as before.
- `{:continue, module, text}`: the session makes a user message with `text` and the origin `%{kind: :hook, id: inspect(module)}`, and the wait ends. The message starts the next turn, ahead of the queued follow-ups (ADR 0013 §2). A compaction that waits starts first: the order of the end of a wait stays (a waiting compaction, then the queue), and the continue goes between them. The steers that queued in the wait join the continue turn at its send, as they join every turn that prepares. A provider process of another model closes first, as before every turn (`close_switched/1`).
- **The count.** At most 8 turns in a row are started by a continue. The count goes up by one when a continue starts a turn, and goes to 0 when a turn starts with a client message: a prompt of an idle session, or the queued steers or follow-up that start a turn (each has the origin `:user` or `:product`). A compaction turn, a turn that background ends wake, and a provider turn leave it as it is. A resume starts it at 0, as it starts the queue empty: the count bounds a run of turns with no client input in one session instance. A continue past it does not start a turn: the session emits the notice `the hook <Module> asked for one more turn past the limit of 8 turns in a row that hooks start; the session settled`, and takes its queues. Reason for 8: each turn is bounded by the deadlines of its provider and its tools, so the count bounds the work that hooks can start with no client input to eight turns; a product whose check needs more turns is not known, and the count is a constant (`Helyx.Session.Server.Settle`); the queue keeps it (`Helyx.Session.Queue.count/2`).

### Failure, abort, and stop

- **A failed hook** (ADR 0013 §5, `docs/features/hooks.md`): the chain goes on with the next hook, and the session emits the notice `the hook <Module> failed before the session settled: <how>`, with `<how>` cut at 4,096 bytes, while that chain is the current one. The notices have no turn id: the turn has ended, as the notice of a failed cleanup. A failure that reaches the session after an abort cancelled its chain is written and gets no notice, as an `after_tool` answer after its turn ends (`docs/features/hooks.md`): the abort ended the chain, and the client saw the abort.
- **An abort before the chain starts**, while another part of the wait still holds it (the cleanup of the hands, a provider process that ends), drops the due chain: it does not start. Because the chain is due, the abort revokes the Tasks and background runs of the ended turn (`Hands.request_revoke/2`, ADR 0014 invariant 4). With a hands request of the wait pending, the wait sets `:revoke` for the chain, and the revoke goes after that request answers.
- **An abort while the chain runs** asks the hands to revoke the Tasks and background runs of the ended turn (`Hands.request_revoke/2`, ADR 0014 invariant 4): the chain Task and its hook Task are killed, and the hook's handles are released with `:cancel`. The background runs of the turn are killed too, their handles are released with `:cancel`, and their later results are not delivered. The wait then lasts until the revoke answers, and the abort caller gets `:ok` at its end. The answer of the chain, if it was sent before the revoke, finds no chain of that ref and is dropped. No turn starts for a continue.
- **An abort while a continue waits** (behind a compaction turn or the close of a switched provider process), and a compaction turn that fails or is aborted, drop it: an abort or a failure empties the queues (`Queue.abort/1`), and a continue that waits behind them is dropped with them. It is no client text, so it does not go back in `queue_dropped`.
- **A stop of the session** ends the chain as it ends every Task of the hands.

### The record

The `hook` entry of `docs/features/hooks.md` gets the point `before_settle` and the answer `continue`. Each continue and each failure is written when the hands send it, with `call_id` null and no call fields; a `settle` is not written (ADR 0013 §6). A continue has no `reason`: its text is the user message of the turn it starts, as a replace has none. A continue past the count is written too: the entries are a log of answers, not of outcomes. A resume reads no `hook` entry, and the user message of a continue is a user message of the transcript with its origin.

## Replaced mechanism

1. The end of a wait (`TurnLoop.progress/1`): with no part left, it replied to the abort callers and took the queues. Now a wait after a done turn that is not a compaction gets one more part, the chain, when a hook exports `before_settle/1`; with none, nothing changes. The answer comes as a message of the hands, `{:settle_answer, ref, answer}`, matched by its ref, so a late answer after an abort cannot end another wait.
2. The next turn (`TurnLoop.start_queued/1`): a waiting compaction, else the queue. Now a waiting compaction, then the queue, where a waiting continue comes first (`Helyx.Session.Queue.drain/1`). The queue holds the continue and the count of turns in a row (`continue`, `hook_turns`): it is the state that a turn start and an abort already change, and the session state has no room for a field more (Credo's struct field bound).
3. The abort in a wait (`Wait.abort/2`) and the end of a turn at an abort or a failure (`Queue.abort/1`): they gave the queued texts back. They now also drop a waiting continue, and while the chain is due or runs, an abort revokes the Tasks and background runs of the ended turn (`Hands.request_revoke/2`, ADR 0014 invariant 4), which holds the wait as at the abort of a turn. With a hands request of the wait pending, the wait sets `:revoke` for the chain, and the revoke goes after that request answers. A wait with no chain keeps the done turn's background runs.
4. The origin kinds: `:user`, `:background`, `:product`, and `:unknown`; now also `:hook`. A session file with a `hook` origin does not read on an older Helyx: its reader refuses the origin.
5. The wire protocol 3 becomes 4. A client of protocol 3 gets `refused` and the close `4426`.
6. Tests: the hook tests of #879 keep their hooks on the tool points; the tests of this doc use hooks on `before_settle` only (`test/support/hooks.ex`).

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| the text of a continue | `Helyx.Session.Input.max_text_bytes/0`, 4,194,304 bytes of valid UTF-8 | a failed hook: the chain goes on, with a notice |
| turns that a continue starts in a row | 8, reset by a turn that a client message starts | the session settles, with a notice |
| `before_settle` chains of a session at once | one, a part of the wait | not reachable: a wait asks once, and the next turn starts after the answer |
| hook Tasks of the chain at once | one: the chain runs one hook at a time | not reachable |
| one hook's run | its limit, then the release deadline of ADR 0004 (`docs/features/hooks.md`) | a failed hook |
| the chain | the sum of the limits and release deadlines of its hooks | the abort ends it |
| the origin id of a continue message | 256 bytes, the name of the hook module | the Core start stops with `{:invalid_hook_name, module}` |
| the reason of a failed hook in its entry and its notice | 4,096 bytes | cut at a character boundary |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| a resource that a `before_settle` hook holds with `Helyx.Tool.hold/1` | the hook in its Task | the hands | `release/3` of the hook, `:deliver`, before the chain goes on | the same, at the Task's `:DOWN`; `:cancel` at its limit and when the chain Task dies | `release/3`, `:cancel`, in the revoke of the ended turn |
| the chain Task | the hands | the hands | it ends with the answer | its hook Task is killed and released with `:cancel` (`Hooks.orphans/3`) | killed in the revoke of the ended turn |

## Out of scope

Harness approvals (#881), the approval gate (#882), the command hook (#883), whose `before_settle` part comes with it. An ask of a `before_settle` hook (ADR 0013 §3, first version). A label for a hook message in the TUI: it shows as any user message, as a background end does today.

A client that ends at the first `turn_end` of `done` misses a continue turn: print mode (`CodingAgent.Print`) prints its answer there and the caller stops Core. No event tells a client that the session settled after the chain; the ADR names none. The coding agent registers no hook plugin today (`CodingAgent.plugins/0`), so print mode cannot meet a continue yet. Open, no ticket yet: reported with #880 for the owner, before a bundled hook on `before_settle` (#883) joins the coding agent.
