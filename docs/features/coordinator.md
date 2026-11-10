# Coordinator tools

Ticket #859, part of #853. Builds on `Helyx.Hub` (ADR 0010, `docs/features/hub.md`, #869, #870) and the start option `:model_context` (#854, `session-model-context.md`).

## Goal

A coordinator is a session with no working folder that starts, steers, reads, and waits for other sessions, and sets schedules (Amp's Puck). Its sessions are normal Hub sessions of its user, with a record, and they outlive the call that started them. The agent tool stays as it is: its children are call-scoped, depth 1, and stop with the call (`agent-tool.md`, decisions 1, 6, and 9).

User story: the user asks the coordinator to run a ticket through implement and review. The coordinator starts a coding session in the folder with the coding mode and a prompt, waits for its turn end, reads its final text, starts a review session, sends the review back, and tells the user.

Decisions (ticket #859, owner decisions of 2026-11-06: Hub first, then as written):

1. **The Hub of a tool call.** A tool plugin is a module with no options, so the tools find their Hub in the application env of `helyx_plugins`: `:coordinator_hubs`, a map of a Core name to its Hub (a registered name, a pid, or a `{:via, _, _}` name). A Hub serves one Core (`hub.md`, decision 10), so the Core of the call (`Helyx.Tool.context/0`) picks it. A Core with no entry, or an entry of another shape, gives each tool an error result. Prior art: the env keys of the other bundled plugins (`:openai_req_options`, `:memory_markdown_dir`).
2. **Modes.** A mode is a name that the product maps to start options (`session-model-context.md`, decision 3): the env `:coordinator_modes`, a map of a mode name to a keyword list of `:model` (a model ref), `:model_context` (a registered ModelContext plugin), and `:tools` (a list of tool names), each optional. Core checks the values at the start. A mode with another key or a value of another type gives an error result, and so does a name that is not in the map; that error lists the mode names. A mode with no `:model` gives the session the model of the coordinator's turn, as the agent tool does.
3. **The user.** Every tool acts for the user whose start or resume through Hub made or attached to the running process of the coordinator session (`start_session/3`, the wire `start` and `resume`, a wake-up of a schedule of that user), while that user exists and owns the session: `Helyx.Hub.actor/2`. Hub keeps this starter beside the entry of the live set (`hub.md`, decision 14), in memory, and drops it with the entry. Any other session acts for no user, and each tool gives an error result: a session started around Hub (a child of the agent tool, a print run, `Helyx.Sessions.start/2`), one whose record was deleted or whose user was removed, and one of a Hub that restarted since its start. Reason: the derived record of decision 8 of `hub.md` gives a session with no row to the default owner, so the owner of the record alone would let a user who deletes the record of her own coordinator session, or whose user is removed, run the rest of its turn as the operator (review of 2026-11-09).
4. **The checks of the wire.** Each tool runs the check of the wire operation it stands for, through the Elixir API of Hub, before it calls `Helyx.Session`: `start_session/3` for `session_create` (the `check` with the caps of the user, `Helyx.Sessions.start/2`, then the `result`, which writes the record); `authorize/4` with `prompt`, `steer`, or `follow_up` for `session_send` and the first prompt of `session_create`, with `history` for `session_read`, and with `subscribe` for each id of `session_wait`; `schedule/3` for `schedule`, and `schedules/3` and `delete_schedule/3` for `schedule_list` and `schedule_delete`. So a session that the user may not read gives the same text as a missing one, and a session that the user reads but does not own gives `forbidden` on a write.
5. **A start leaves no session that no user owns.** `start_session/3` runs in a process under the Core task supervisor that a kill of the call does not end, so its `result` writes the record also when the coordinator turn aborts. A `start_session/3` whose `result` fails (a Hub that does not answer, a store that fails, a removed user) stops the session it started and gives the code: the caller gets no id of it, and the session would belong to the default owner. A first prompt that the check or the session refuses stops the session too, so a session that got no prompt takes no place of the cap. The wire keeps its own rule (`hub.md`, Accepted holes, "Hub crash between a start and its record").
6. **`session_wait` is bounded by its deadline.** It subscribes to each session in the Task of the call with a tail of one message, so the snapshot is small, and acks every event. A session whose snapshot shows no turn counts as ended at once ("no turn runs"), so a turn that ended before the call does not make the wait sit until the deadline. The first `turn_end` or end of a subscribed session ends the wait. The deadline is 1 to 3,600 seconds, default 300; past it the result is an error that tells the model to call `session_wait` again. An abort of the coordinator turn kills the Task, and the subscriptions end with it.
7. **`session_read` reads a running session.** A process of its own subscribes with a tail of 1,000 messages, renders the newest messages that fit in the budget, and exits, so no event reaches the Task of the call. With no question the budget is `Helyx.Message.max_result_bytes/0`; with a question it is 262,144 bytes, and a child session reads it: the child of the agent tool (`agent-tool.md`), with no tools, the coordinator's model, ModelContext, and `:provider_opts`, a parent link to the call, and the prompt of the question and the transcript. The child machinery moved from `Helyx.Tool.Agent` to the helper `Helyx.Subagent`, which both tools call (ADR 0005); the agent tool keeps its behaviour. A session that does not run gives the text of a missing one: the wire reads only a running session too (`hub.md`, decision 4).
8. **The origin of a sent text.** A prompt, steer, or follow-up that a tool sends has the product origin, with the id `Helyx.Sessions.child_id/2` of the coordinator session and the call id: 12 characters, unique per call, so a reader of the session sees that a coordinator sent it.
9. **`Helyx.ModelContext.Coordinator`.** The system prompt of the mode: the role, the nine tools, the mode names (at most 32), the model, the session id, and the time in UTC to the minute with its POSIX seconds, which `schedule` takes. No context file and no working folder. The coordinator mode is a mode of the product with this context and `tools: ["session_create", "session_send", "session_read", "session_wait", "schedule", "schedule_list", "schedule_delete", "subscription_list", "subscription_delete"]`, so its sessions have no bash and no file tools.
10. **Concurrency.** Every tool is concurrent (`concurrent-tool-calls.md`): each acts on Hub and on other sessions only. A start reserves its place of the cap by the pid of its Task, so two starts in one response each take a place.
11. **Event subscriptions** (#921). `subscription_list` shows the event subscriptions of the user of the calling session, of one session or of all, with the endpoint path and the template, and never the secret (`hub.md`, decision 17). `subscription_delete` deletes one. There is no create tool: the secret must not enter a transcript, so a user makes a subscription with the Elixir API of Hub or `hub.subscriptions.create`, and gives the secret to the sender.

## Interface changes

- `Helyx.Hub.start_session(hub, user_id, opts)`, `authorize(hub, user_id, op, params)`, `owner(hub, session_id)` (`hub.md`, Interface changes), and `actor(hub, session_id)` (decision 3). `authorize/4` takes the params map of the wire, `%{"session" => id}`, with `"text"` for the text operations, whose check moves the record as on the wire. An exit of a Hub call is `{:error, :timeout}`, a user that no longer exists `{:error, :unknown_user}`.
- `Helyx.Tool.SessionCreate` (`session_create`: `mode`, `folder`, `prompt`), `Helyx.Tool.SessionSend` (`session_send`: `id`, `text`, `disposition`), `Helyx.Tool.SessionRead` (`session_read`: `id`, `question`), `Helyx.Tool.SessionWait` (`session_wait`: `ids`, `deadline`), `Helyx.Tool.Schedule` (`schedule`: `id`, `at`, `prompt`, `every`), `Helyx.Tool.ScheduleList` (`schedule_list`: optional `id` of a session), `Helyx.Tool.ScheduleDelete` (`schedule_delete`: `schedule`), `Helyx.Tool.SubscriptionList` (`subscription_list`: `id?`), `Helyx.Tool.SubscriptionDelete` (`subscription_delete`: `id`).
- `Helyx.ModelContext.Coordinator`.
- The application env of `helyx_plugins`: `:coordinator_hubs` and `:coordinator_modes`.
- `Helyx.Subagent` (helper, `@moduledoc false`): `run/4` and `release/2`, moved from `Helyx.Tool.Agent`.

## Replaced mechanism

None. The agent tool's child machinery moved to `Helyx.Subagent` with no change; its tests keep their properties (`test/helyx/tool/agent_test.exs` finds the owner process by the new module).

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| sessions of a user | the Hub cap `:max_live_sessions` (`hub.md`, decision 14) | an error result: the cap of the user | `Helyx.Hub.start_session/3` |
| records of a user | 10,000 (`hub.md`, Bounds) | an error result | `Helyx.Hub.start_session/3` |
| a session id from the model | a string of 1 to 64 bytes, the frame rule of an id | an error result | `Helyx.Coordinator.id?/1` |
| `folder` | an absolute path of a folder that exists; Core checks the rest | an error result | `Helyx.Tool.SessionCreate` |
| `prompt` of `session_create`, `text` of `session_send` | `Helyx.Session.max_text_bytes/0` | an error result, before the start or the check | the tools, then `Helyx.Session.prompt/3` |
| `ids` of `session_wait` | 1 to 64, the Core cap; duplicates count once | an error result | `Helyx.Tool.SessionWait` |
| `deadline` of `session_wait` | 1 to 3,600 s, default 300 | an error result; past the wait, an error result that says to wait again | `Helyx.Tool.SessionWait` |
| events of a wait | each acked; the subscription of the session ends past 16,384 unacked | an error result | `Helyx.Session` subscribers |
| the snapshot of a wait | a tail of 1 message | n/a | `Helyx.Session.subscribe/2` |
| the messages of a read | a tail of 1,000, the most of a snapshot | the older ones are left out, and the text says so | `Helyx.Tool.SessionRead` |
| the text of a read | `Helyx.Message.max_result_bytes/0`, or 262,144 bytes for a child, newest messages first; a message that does not fit is cut to its end | the older messages are left out, and the text says so | `Helyx.Tool.SessionRead.render/3` |
| `question` | 16,384 bytes | an error result | `Helyx.Tool.SessionRead` |
| the child of a read | the bounds of the agent tool's child (`agent-tool.md`, Bounds) | as there | `Helyx.Subagent` |
| `schedule` | the Hub rules of `hub.schedules.create`: 16 schedules of a session, 256 of a user, `at` from now to 366 days, `every` 300 to 2,678,400 s, a prompt of 1 to 16,384 bytes | an error result | `Helyx.Hub.schedule/3` |
| `schedule_list` result | the schedules of the user, at most 256 (the Hub cap of a user); each line shows a prompt cut to 256 bytes, as escaped text, with `(cut, N bytes)` after a cut prompt, and the lines stop at 60,000 bytes, under `Helyx.Message.max_result_bytes/0` (65,536): `inspect` can make a cut prompt about four times longer, so 256 full lines do not fit | a last line counts the schedules not shown and points to the list of one session | `Helyx.Tool.ScheduleList` |
| `schedule_delete` | a schedule id of the frame rule of an id; another user's schedule gives the answer of a missing one | an error result | `Helyx.Tool.ScheduleDelete`, `Helyx.Hub.delete_schedule/3` |
| `subscription_list` result | the subscriptions of the user, at most 256 (the Hub cap of a user); each line shows a template cut to 256 bytes, as escaped text, with `(cut, N bytes)` after a cut template, and the lines stop at 60,000 bytes, under `Helyx.Message.max_result_bytes/0` (65,536): `inspect` can make a cut template about four times longer, so 256 full lines do not fit | a last line counts the subscriptions not shown and points to the list of one session | `Helyx.Tool.SubscriptionList` |
| `subscription_list`, `subscription_delete` | the Hub rules of `hub.subscriptions.list` and `hub.subscriptions.delete`: 16 subscriptions of a session, 256 of a user, a template of 1 to 16,384 bytes with `{{payload}}` once; no secret in a listing or a result | an error result | `Helyx.Hub.subscriptions/3`, `Helyx.Hub.unsubscribe/3` |
| Hub calls of the tools | one at a time per Task: at most the 8 calls of a turn in each of 64 sessions, 512, within the admission bound of Hub (`hub.md`, decision 5) | `busy`: an error result | `Helyx.Hub.call/3` |
| mode names in the system prompt | 32, sorted | the rest are left out | `Helyx.ModelContext.Coordinator` |
| a value line of the system prompt | 4,096 bytes, one line | cut | `Helyx.ModelContext.Coordinator` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| a session of `session_create` | `Helyx.Hub.start_session/3` in a Task under the Core task supervisor, not linked to the call | Core and the Hub record; not the call | not at the end of the call: it outlives it, until a client or the server stops it | as on a normal end; a `result` or a first prompt that fails stops it (decision 5) | as on a normal end: the start Task writes the record |
| the subscriptions of `session_wait` | the Task of the call | the Task | they end with the Task | they end with the Task | the hands kill the Task |
| the starter of a session (decision 3) | the `result` of a start or resume through Hub, a wake-up | the Hub process, beside the entry of the live set | with the entry, at the `:DOWN` of the session | gone with Hub (Accepted holes) | n/a |
| the reader of `session_read` | the Task of the call, linked | the reader | it exits after the render | it dies with the Task by the link | as on crash |
| the child of `session_read` | `Helyx.Subagent` | the hands (`hold/1`) and its owner process | as the agent tool's child (`agent-tool.md`, Ownership) | as there | as there |

## Accepted holes

- **A stopped session.** `session_send`, `session_read`, and `session_wait` act only on a running session, as the wire does; a session that stopped gives the text of a missing one. A resume through Hub for the coordinator is a later ticket.
- **No product registers the tools yet.** `helyx serve` does not start a Hub on this branch, and the wire has no mode field (`session-model-context.md`, Out of scope). A product registers the tools, `Helyx.ModelContext.Coordinator`, and the env keys, and starts a coordinator session with `Helyx.Hub.start_session/3`.
- **A restart of Hub.** The starters are in memory, so after a restart of Hub a running coordinator session acts for no user until its user resumes it over the wire, which attaches and binds it again.
- **A record whose `result` timed out after its commit.** The session stops (decision 5), and the record stays for a stopped session, which the user can resume over the wire.

## Out of scope

Slack or other chat front ends, a coordinator that runs tools on a working directory, changes to the agent tool, a mode field on the wire.
