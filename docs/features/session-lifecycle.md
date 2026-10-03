# Session lifecycle

## Goal

The Core turn contract: how a session starts, runs, and ends a turn with its provider process, and the wait before the next turn. The provider protocol (requests, actions, replies) is in `docs/features/one-provider-path.md`. The harness programs are in `docs/features/long-lived-harness.md`.

## Owners

- `Helyx.Session.Server.TurnLoop` owns the lifecycle. It matches each input (a client call or a message) to the current activity: `:idle`, a `%Turn{}`, or a `%Wait{}`. A lifecycle message of a turn, a wait, or a provider process that is no longer current is dropped there. Any other message crashes the session. `Helyx.Session.Server` drops a stream event or a tool result of a turn that is not current, and a withdrawal when no turn runs. A tool request of a turn that is not current gets the answer `aborted`.
- `Helyx.Session.Server.Wait` owns the turn end (`Wait.finish/2`) and the wait after it.
- `Helyx.Session.Server.Records` is the only writer of the transcript and the session file. `Records.finish/2` closes the records of a turn.
- `Helyx.Session.Server.Steering` is the only writer of the steer state (`Helyx.Session.Queue`).
- `Helyx.Session.Server.Events` is the only writer of `seq` and the subscribers.
- The provider process (`Helyx.Session.ProviderProcess`) is a Task of the hands. `init/3`, `request/3`, and `info/2` run only there. Core calls `id/0` when it registers the plugin, and the hands run `release/3` in their own Tasks under the release deadline. The provider process keeps no turn state.

## Turn states

A turn has a `phase` (`Helyx.Session.Turn`). The line between `preparing` and `submitting` is the send of `{:turn, ...}`, not its answer.

| Phase | From | To | A steer |
| --- | --- | --- | --- |
| `preparing` | the turn starts: `turn_start`, the connect, and the prepare Task | `submitting`, when the provider process is ready and the context is prepared | stays in the local queue. At the send it joins the transcript and the end of the context as a user message: it is part of the prompt |
| `submitting` | `{:turn, ...}` sent | `submitted` at the answer `:ok` | stays in the local queue. At `:ok` the session sends the local steers, in order |
| `submitted` | the answer `:ok` | the end of the turn | goes to the provider process with a new `steer_id` |
| `context` | `submitted`, with a context request (`{:need_context, turn_id}`) open | `submitted`, when the session answers the request | as `submitted` |

- A turn that the provider starts by itself (`{:event, id, :turn_start}`) opens a `submitted` turn with no user message, and `turn_start` has `%{origin: :provider}`. It opens only with no turn, no wait, and a ready provider process. At any other time the session drops it and its events.
- An answer other than `:ok` to `{:turn, ...}` stops the provider process (`ProviderRequest.stop_after/2`). Its `provider_down` fails the turn.

## Message close

The session owns the boundary of the assistant message. It closes the open message at a `message_end` event, at the first `tool_result` of one of its calls (stop `:tool_use`, usage `%{}`), at a taken steer, and at the turn end. A Helyx tool request does not close it: more calls of the same message can still arrive. A result for no open call is dropped.

## Turn end

Every end of a turn runs one path, `Wait.finish/2`, with an outcome: `{:done, stop_reason, usage}` (the terminal of the provider), `:aborted` (`Session.abort/1`), or `{:error, reason}` (a failure). In order:

1. The session kills the prepare Task of the turn, if one runs.
2. `Records.finish/2` closes the records.
   - At `done` an assistant message always joins with the provider's stop reason and usage: the open one, or an empty one when none is open.
   - At an abort or a failure, an open message with a tool call joins with the stop reason `:tool_use` and usage `%{}`. An open message with text only joins with the stop reason `:aborted` or `:error`, and its `message_end` has the reason in `error`. An open message with no block gets its `message_end` and is not stored.
   - Then each open tool call (`Transcript.open_calls/1`) gets an `aborted` error result. No message goes between a call and its result.
3. The steers end (`Steering.end_turn/3`). At `done` a steer with no answer stays in the ledger as `{:ended, turn_id}`, and its late answer alone decides what happens to it. An abort or a failure drops both queues.
4. Each open Helyx tool request of the turn gets `aborted` (`ToolRuns.end_turn/2`), while the provider process lives. No answer is awaited.
5. `turn_end` goes out with `%{outcome: :done}`, `%{outcome: :aborted}`, or `%{outcome: :error, error: reason}`.
6. The hands get the cleanup request (`Hands.request_cancel/2`): always at an abort or a failure, and at `done` when a Helyx tool still runs. They kill the Tasks of the turn and release their handles.
7. Only an abort of a turn in `submitting`, `submitted`, or `context` sends `{:interrupt, turn_id}`. It goes after the `aborted` answers of step 4, so the provider process gets them first.

## The wait

`Wait` holds the parts that must end before the next turn: `hands` (the cleanup answer), `reply` (the answer to an interrupt or an idle close), and `provider` (a provider process that ends, until the hands' `provider_down`). `TurnLoop` ends the wait when no part is left. Then the abort callers get `:ok`, a provider process of another model gets `:close`, and the queues start the next turn, steers first.

- While the wait lasts, the session starts no turn. A prompt and a follow-up queue as follow-ups, and a steer queues as a steer. So a new turn never runs tools beside a Task of the old turn.
- An interrupt answer `:ok` keeps the provider process. Any other answer, or its armed kill, stops it, and the wait lasts until its `provider_down`.
- A failed cleanup gives one `notice` with a fixed text. The abort still replies `:ok`.
- An abort in a wait drops the queues, and its caller gets `:ok` at the end of the wait. An abort with no turn and no wait replies `:ok` at once.

## Deadlines

Every request of the session to the provider process has a kill armed at the OTP timer server (`ProviderRequest.ask/3`). The loop cancels the kill when the provider replies, and sends the reply after the cancel. A blocked callback blocks the cancel too, so a blocked loop is killed at the bound, whatever the session and the hands do. The OTP timer fires at the bound or later, so a bound is the least wait, not an exact time.

- The connect kill is armed by the hands as the first act of the provider process, and the loop cancels it after `init/3`, before `{:provider_ready, pid}`.
- The prepare Task arms its own kill as its first act, before any plugin code, and cancels it before it sends the context.
- The timer can fire during the cancel, so a reply can still be followed by the kill. Then the `provider_down` decides the end, not the reply.

## Steer

The session gives each sent steer a `steer_id` and keeps it in the ledger of `Helyx.Session.Queue` until its `user_message` and its answer. Delivery is at most once.

| Answer to `{:steer, ...}` | Session |
| --- | --- |
| `:ok` | waits for `{:user_message, steer_id}` |
| `:rejected` | queues the steer for the next turn |
| `{:error, _}`, or the armed kill | the steer is unknown. It is never sent again |

- At `{:user_message, steer_id}` the open assistant message closes, each open call gets `aborted`, and the session appends its own text of the steer. An unknown or repeated id is dropped.
- A steer with `:ok` or an unknown answer and no `user_message` at the end of its turn gets a `steer_unconfirmed` event with its text. At `done` a late `:rejected` still queues it; at an abort or a failure it gets the event at once.

## Provider death

The session monitors its provider process, and the hands send `{:provider_down, pid, reason}` after they release its handles. The two messages have no order between them. `reason` is `:provider_timeout` after an armed kill, the stop reason after an exit with `{:shutdown, reason}`, `{:task_exit, reason}` after any other exit, or `{:error, unconfirmed}` when the release left handles unconfirmed.

- Outside a turn, the `:DOWN` drops the process at once, and the next turn waits for its `provider_down`.
- In a sent turn (`submitting` or later), the `provider_down` fails the turn with `reason`.
- In `preparing`, the `:DOWN` holds back `{:turn, ...}`. When the process was started by an earlier turn, its `provider_down` makes the turn connect a new one, once. A process that this turn started fails the turn.
- At `provider_down` each sent steer with no notice gets `steer_unconfirmed`, and the ledger drops every entry of that process.
- Provider output outside the contract (a bad event, a context request outside `submitted`, a message over a bound) stops the provider process with `{:shutdown, reason}` and fails the turn.

## Idle close

With a ready provider process and no turn and no wait, the session arms one idle timer (`provider_ms.idle`). Each arm has a new ref, and a timer message with an old ref, or during a turn or a wait, is dropped. When it fires, the session sends `:idle_close` with the close bound and waits. `:ok` ends the process, and the wait lasts until its `provider_down`. `:busy` keeps it, and the timer is armed again.

## Subscribers

`Helyx.Session.subscribe/1` returns `{:ok, snapshot, ref}`. The session adds the entry and takes the snapshot in one call, so every later event reaches the caller. `ref` is the caller's monitor of the session: its `:DOWN` ends the stream. The session monitors each subscriber and drops its entry at its `:DOWN`. The rules are in `docs/features/session-subscribers.md`.

## Session stop

`terminate/2` runs `Helyx.Session.Server.Stop.run/1` on the list of `TurnLoop.work/1`. In a turn, the prepare Task is killed, and the provider process ends with the hands. With no turn, the current provider process and the one the wait is for get `:close`, in parallel, each with its armed kill. Then the session stops the hands and waits for them.

## Bounds

| What | Bound | Over the bound | Owner |
| --- | --- | --- | --- |
| connect: provider process start to `{:provider_ready, pid}` | 30,000 ms, armed kill (`connect_ms` in `Helyx.Session.Hands.State`) | the process ends; its `provider_down` fails the turn with `:provider_timeout` | hands |
| prepare Task | 10,000 ms, armed kill (`prepare_ms` in `Helyx.Session.Server.State`) | the turn fails with `{:task_exit, :killed}`, or a context request gets that error; the provider process stays | session |
| answer to `{:turn, ...}`, `{:steer, ...}`, `{:interrupt, ...}`, `{:tool_result, ...}`, `{:context, ...}` | 2,000 ms, armed kill (`@provider_reply_ms` in `Helyx.Session.Server.State`) | the provider process ends; in a turn its `provider_down` fails the turn with `:provider_timeout`; a kill that fires in the next turn fails that turn | OTP timer server |
| answer to `:close` and `:idle_close` | 5,000 ms, armed kill (`@provider_close_ms` in `Helyx.Session.Server.State`) | the provider process ends | OTP timer server |
| `submitted`: the `:ok` answer to the terminal | unbounded, accepted: a model turn has no time bound | the user aborts; the interrupt has its armed kill | client |
| idle time with a ready provider process | 1,800,000 ms (`provider_ms.idle` in `Helyx.Session.Server.State`) | the idle close | session |
| queued steers, and sent steers until their `user_message` and their answer, also after their turn | 32 together (`@limit` in `Helyx.Session.Queue`) | `{:error, :queue_full}` to the client | session |
| queued follow-ups | 32 (`@limit` in `Helyx.Session.Queue`) | `{:error, :queue_full}` to the client | session |
| bytes of text, thinking, and tool calls in the open assistant message | 8 MiB (`@max_message_bytes` in `Helyx.Session.Turn`) | `{:message_too_large, bytes, max}`: nothing is added, the provider process stops, the turn fails | session |
| blocks in the open assistant message | 1,024 (`@max_message_blocks` in `Helyx.Session.Turn`) | `{:too_many_blocks, blocks, max}`: as above | session |
| Helyx tool requests of one turn | one runs, at most 16 wait (`@max_waiting` in `Helyx.Session.ToolQueue`) | an error result to the provider at once; nothing runs | session |
| encoded bytes of the running and waiting Helyx tool calls | 8 MiB together (`Turn.max_message_bytes/0`, read by `ToolQueue.request/4`) | an error result to the provider at once; nothing runs | session |
| messages that wait in the session mailbox before a provider send | 10,000 (`@max_session_queue` in `Helyx.Session.Stream`) | `{:session_behind, length, 10000}`: the provider process stops, the turn fails | provider process |
| hands release of one cleanup or delivery | 20,000 ms (`release_ms` in `Helyx.Session.Hands.State`) | the handles stay unconfirmed, and the hands refuse tool calls and provider starts until a retry releases them; a failed cleanup gives a notice | hands |
| session stop | closes 5,000 ms, then the hands 22,000 ms (`@hands_stop_ms` in `Helyx.Session.Server.Stop`); the shutdown is `Stop.shutdown_ms/0`, 30,000 ms | the hands are killed, and the provider process and the tool Tasks end with them: no release runs | session |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| --- | --- | --- | --- | --- | --- |
| provider process | the hands (`Hands.start_provider/3`), a Task in `tasks` | hands, linked; the session monitors it | `:close` at the session end, at a model switch, or `:ok` to an idle close; then the hands release its handles | the link ends it with the hands; its end is a `:DOWN` and a `provider_down` | kept after an interrupt `:ok`; any other answer or the armed kill stops it |
| prepare Task | the session, under the task supervisor | the session, monitored; its pid in `Turn.prepare` | sends the context | its armed kill ends it after an untrappable kill of the session | killed by `Wait.finish/2` at every turn end |
| Helyx tool Task | the hands (`Hands.run/3`) | hands, linked | the result goes to the session | the link | killed and released by the cleanup request |
| open request to the provider process | the session (`ProviderRequest.ask/3`) | the provider process, with its armed kill | answered | ends with the provider process | answered, or the kill stops the provider process; a late reply is dropped |

## Out of scope

- The provider protocol: `docs/features/one-provider-path.md`.
- The harness programs: `docs/features/long-lived-harness.md`.

## Current limits

- A cut with no block stores no message. The last stored assistant message is then an older one, so a later turn can resume an older provider session (`Transcript.resumable/3`).
- An abort with a tool call joins the message with the stop reason `:tool_use`, not `:aborted`. So `Transcript.resumable/3` still resumes the provider session, which may not keep that partial message.
- `Helyx.Provider.Loop` drops a `done` with no content while a steer is held, before the stream check, so nothing checks its stop reason.
- An armed kill of a request of the old turn (a steer, a tool result, a context) can fire in the next turn and fail it. Only a provider that did not answer within its bound does that.
- A provider process of an earlier turn that ends after the context is prepared, before the session reads its `:DOWN`, ends in `submitting`, and the turn fails.
- At a session stop during a wait for an interrupt or an idle close answer, the armed kill of that request still runs beside the kill of the close. When it fires first, it kills the provider process before the close answers. The release still runs.
