# Background bash

## Goal

The agent starts a long command in the background, such as a precommit run that waits in a queue on the host. The call returns at once with an id, the process group, and the path of the output file. The agent goes on with other work, or ends its turn. When the command ends, the session gets a message with the end status and the tail of the output: a steer while a turn runs, or a new turn while the session is idle. The agent never polls. Issue #577.

A foreground `bash` call holds the turn for at most 600 s (`docs/features/bash-timeout.md`). A command that needs more time, or that the agent does not need to wait for, holds nothing in the background.

Decisions of the owner (2026-10-14, in #577):

- `bash` gets `background: true`.
- **A generic Core path.** A tool may answer that its work started and keep its Task. The hands keep that Task and its handles past the call, outside every turn, and send the session the end. Bash is the only user now.
- **The message.** The end reaches the model as a user message (role `:user`) in a fixed form. The tail is at most `Helyx.Message.max_result_bytes/0`; the full output is in the file. No new message role: the transcript and the session file keep their shape. The TUI shows it as a user cell.
- **Delivery.** Background ends have their own queue, not the steer queue. During a turn an end joins as a steer. While the session is idle, an end starts a turn. An abort never drops them: after an abort they wait, do not wake the session, and go with the next turn.
- **Lifecycle.** An abort of the turn does not end background commands. A session stop ends them with the existing release (TERM, grace, KILL). At a resume, each background start with no end gets an end message that says it was lost because the session stopped. It is derived from the transcript at resume, not stored at the stop.
- **Bounds and stop.** The output file is in the system temp folder, one folder per session, which the session deletes at its stop. At most 64 MiB per file; after that the output is dropped and the end message says so. At most 16 live background commands per session; a start over that gives an error result and runs nothing. A background `timeout` defaults to 3,600 s and allows up to 86,400 s. No stop tool: the agent ends a command with `kill` on its process group through bash, and the end message then arrives as usual.
- **Harness providers.** The program gets the start answer at once. The end goes to the program as a user line, through the path of a steer or a prompt.

Decisions of this doc (the open items of #577):

- **The tool contract.** Two functions of `Helyx.Tool`, called from the tool Task as `hold/1` is: `background/0` takes a place among the 16 and gives an id and the background folder of the session, before the external work starts; `started/1` gives the start answer. The Task then runs on, and its return value is the end. A place taken before the work starts is what lets a start over the limit run nothing. Bash needs the process group in its answer, which exists only after the start, so the answer is a second call.
- **Background Task or turn Task.** The hands keep each Task under its turn id and its call id. At `started/1` the entry of the Task becomes `{nil, {:background, id}}`, the shape of the provider process, which has no turn either. `request_cancel/2` and `kill/3` match the turn id, so they never reach a background Task. Only the stop of the hands ends it.
- **The events.** No new event type. The start answer is the call's tool result, so the clients see it in `tool_execution_end`. The end is a user message, so they see `message_start` and `message_end` when it joins the transcript, and `turn_start` when it opens a turn. A client folds both as it folds any result and any user message.
- **Print mode.** Since #591, print mode waits while a background run is open and its end can open a turn; each end opens a turn as in an idle TUI session. It exits when the session settles, with the answer of the last turn. A held end does not hold it (`docs/features/print-background-wait.md`). A print run that resumes a session (#574) gets the lost ends of that session in its turn, after its prompt: the resume holds them, so no turn opens before the prompt.
- **The id.** `Helyx.Session.Id.new/0`, 12 URL-safe characters: unique across resumes with no counter to derive.

## Interface changes

`Helyx.Tool`:

```elixir
@spec background() :: {:ok, %{id: String.t(), dir: String.t()}} | {:error, String.t()}
@spec started(String.t()) :: :ok
```

- `background/0`, from a tool Task of the hands. It takes one of the 16 places of the session and gives the id of the run and the background folder of the session, which the hands create with mode `0700` at each call. The tool names its files by the id there: bash writes `<folder>/<id>.out`. A second call from the same Task, a call from a Task that is not a tool call, a call outside the hands, a full set of 16, and a folder that cannot be made give `{:error, text}`; the tool returns an error result and starts nothing. The place stays taken until the Task ends.
- `started(text)`, from a Task that has a place. The hands send `text` as the result of the call, at once, in the form below, and move the Task out of its turn. The Task's return value, or its crash, is then the end of the run. A Task with no place raises `ArgumentError`, as `hold/1` does for a tool with no `release/3`.
- The hands release the handles of a background Task when it ends, as at a delivery (`:deliver`), and send the session `{:background_end, text}` after the release.

The start answer, the result of the call:

```text
<background id="ID" status="started">
TEXT OF THE TOOL
</background>
```

The end, a user message:

```text
<background id="ID" status="done">
TEXT OF THE TOOL
</background>
```

`status` is `done` for `{:ok, text}` and `error` for `{:error, text}`, a crash, or a handle that the release did not confirm. The text of the tool goes through `Helyx.Message.cut_result/1`, so it is valid UTF-8 of at most `Helyx.Message.max_result_bytes/0`, before the wrap. The end of a run that was live at a session stop, derived at resume:

```text
<background id="ID" status="lost">
The session stopped while this background command ran, and its end was lost. The command may have run in full or in part. Check its effects before you run it again. Its output file was deleted with the session.
</background>
```

`Helyx.Session.Hands`: `start_link/1` takes `dir:`, the background folder of the session. The session names it `<system temp>/helyx-<instance id>` and deletes it at its stop.

`Helyx.Tool.Bash`:

- `background`, a boolean. Missing, `null`, or `false` is a foreground call, as before.
- `timeout`: from 1 to 600 s in the foreground, default 120; from 1 to 86,400 s in the background, default 3,600. The schema maximum is 86,400; `run/2` checks the bound of the mode.
- A background call takes a place, opens the output file, starts the command, and answers with the process group, the output path, and how to stop it (`kill -TERM -- -<group>`). It then writes the output to the file and keeps the tail, as a foreground call does. At the end it returns the first line of the command, the exit code or the timeout, a note when the file was cut, and the tail.
- The tool-set digest of a Codex thread changes with the spec (as for `workdir`, `docs/features/bash-workdir.md`).

The session:

- `Helyx.Session.Queue` gets `ends`, the background ends that wait, and `hold`, true from an abort, a failed turn, a resume, or an end given back until the next turn that is not a compaction opens. A give-back in an open turn (a late answer from an earlier turn, or the end of an earlier provider process while a turn prepares) sets `hold` in that turn: the end goes in it, and after it the ends wait for the next prompt. An end that waits goes as soon as a steer frees its place in a `submitted` turn.
- An end that arrives: in a `submitted` turn that is not a compaction, it goes to the provider as a steer while the 32 steers have room, else it waits. In `preparing` it joins the transcript and the context at the send of the turn, after the queued steers' place. In `submitting` it goes at the `:ok`, with the local steers. In a wait, and while idle with `hold`, it waits. While idle without `hold`, it opens a turn with no user message of its own, and joins at the send.
- An end that a steer sent: `:rejected` puts it back with the ends, not the steers, and no end goes as a steer again until the next turn that is not a compaction opens, as a rejected steer waits for the next turn. A late `:rejected` that comes in a later turn stops the ends of that turn too, until the next one opens; the ends wait and are not dropped. A `user_message` takes it as any steer. An answer other than `:rejected` with no `user_message` at a normal end of its turn, or, after the end of its turn, a late answer other than `:rejected`, puts the end back at the front of the ends with `hold` set, as after an abort. It gets no `steer_unconfirmed`. An end is never dropped, and the hold stops a resend loop: the end waits for the next prompt (owner decision, 2026-10-14).
- An abort, a failure, and the end of the provider process put every sent end that no `user_message` took back at the front of the ends, with no notice. An abort and a failure always set `hold`. The end of the provider process sets `hold` only when it gives an end back: the idle close ends the provider process in the normal course, and a background run that outlasts it must still wake the session. In a turn, the end of the provider process fails the turn, and the failure sets `hold`. Each path that does not deliver an end puts it back once, held; only a rejected end goes to the back, with no `hold`, as above. `queue_dropped` never holds an end.
- A failed turn and a failed compaction set `hold`, as an abort does: the ends wait for the next prompt and do not wake the session (owner decision, 2026-10-14). A failure often repeats, and a wake would start a turn that fails again with no user present.
- Accepted edge: after an abort, a failure, the end of the provider process, or an answer other than `:rejected` with no `user_message`, an end is delivered at least once, not exactly once. The cause: the session cannot know if the provider put a sent end in its context when no `user_message` came for it, so it gives the end back, and the next turn can send it again. The other choice drops an end that the provider never got. No check removes the duplicate.
- The session server's `init` derives the lost ends from the transcript with `Helyx.Session.Background.lost/1`, the one function that holds the derivation, and queues them with `hold`: the resume wakes nothing, and they go with the next turn.

## Replaced mechanism

none. A foreground call does not change. The rule of the hands "no resource survives its call" becomes "no resource survives its Task": a background Task holds its handles until it ends, and its release and its end follow the same delivery path.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| live background runs of a session | 16 places, taken at `background/0` and freed when the Task ends (`@max_live` in `Helyx.Session.Background`) | `{:error, text}` to the tool; bash returns an error result and starts nothing | hands |
| background `timeout` | an integer from 1 to 86,400 s, default 3,600 | an error result; nothing runs | `Helyx.Tool.Bash.run/2` |
| foreground `timeout` | from 1 to 600 s, default 120, as before | an error result; nothing runs | `Helyx.Tool.Bash.run/2` |
| `background` argument | `true`, `false`, missing, or `null` | an error result; nothing runs | `Helyx.Tool.Bash.run/2` |
| output file | 64 MiB (`@max_file_bytes` in `Helyx.Tool.Bash`): bytes past it are not written | the end message says how many bytes the command wrote and that the file holds the first 64 MiB | bash |
| output in memory | the kept tail, `keep_tail/1`, as for a foreground call | as before | bash |
| tail in the end message | `Helyx.Text.truncate/2` of the tail, then `Helyx.Message.cut_result/1` in the hands; the wrap adds the fixed lines | cut | bash, hands |
| first line of the command in the end message | 200 bytes (`Helyx.Text.cap/3`) | cut | bash |
| start answer | 4,096 bytes of valid UTF-8 (`@max_start_bytes` in `Helyx.Session.Background`) before the wrap, far under `Helyx.Message.max_result_bytes/0` | cut | hands |
| wait of a background Task | the `timeout` of the run; at it the release of a timeout, as in the foreground (`docs/features/bash-timeout.md`) | the end with the timeout | bash |
| background ends that wait in the session | outside a `submitted` turn no tool call runs, so at most the 16 live runs end there; an end that a turn gave back adds at most the 32 entries of the ledger; in a `submitted` turn an end waits only while the 32 steers have no room or after the provider rejected an end, so the count there is the runs that end in one turn while the provider takes no steer: unbounded in theory, #587 | none | session |
| lost ends at resume | one per start answer in the transcript with no end message | none | `Helyx.Session.Background.lost/1` |

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort | Released at session stop |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- | ------------------------ |
| command process group, watchdog | `Helyx.Watchdog.start/4` in the background Task | hands (opaque handles), the port (life) | hands, `:deliver`, when the Task ends | the watchdog when the port closes; the hands release at the delivery of the crash | not released: an abort does not end a background run | the hands stop: the Task dies, the port closes, the watchdog TERMs the group, waits the grace, and KILLs it |
| output file handle | bash, a `:raw` file of the Task | the Task | closed when the Task ends | closed by the runtime when the Task dies | as on normal end | as on normal end |
| background folder and its files | the hands, at the first `background/0` | the session | kept while the session runs, so the agent can read a file after its end | a session crash or kill leaves it in the system temp folder: open, see "Open" | kept | deleted by `Helyx.Session.Server.Stop.run/1` after the hands stop |

## Open

- Ends that wait in a `submitted` turn while the 32 steers have no room have no count bound. Each needs a background run that ends in that turn while the provider takes no steer. #587.
- A session that crashes or is killed leaves its background folder in the system temp folder. #587.
- An abort that comes between the start of a background run and the session's read of its start answer drops the answer with the turn: the call gets `aborted`, and the run goes on. Its end still arrives, with the first line of the command.
- A foreground result whose text starts with the exact start line of a background answer counts as a start at a resume, and gets a lost end. The id must have the form of `Helyx.Session.Id`.

## Out of scope

- A tool to list, poll, or stop background runs: the agent uses `kill` through bash.
- A count of the ends that wait with no hold, or of the live runs, in the snapshot or in `queue_update`. Both count only the held ends (`held`, #591).
