# Review: the feature doc of Helyx.Hub (#868)

Docs-only change: `docs/features/hub.md` (new). A feature doc gets the Codex review of `/ship` step 2; a spec agent checked the doc against the ticket, the owner note of 2026-11-06 on #857, ADR 0010, ADR 0008, ADR 0009, `AGENTS.md`, the template, and the code that it names. No simplify or standards pass: Markdown only. Bounds sensor: not run, no `lib/` change.

## Round 1 (full for a Markdown change: Codex and spec)

| Finding | Source | Resolution |
|---|---|---|
| A prompt that `prompt/3` queues during an abort wait answers `:ok` before it is in the transcript; marking it delivered at `:ok` loses it at a VM stop or a second abort | Codex (high) | Fixed: a wake-up is delivered when the `message_end` of its user message comes on the subscription of the delivery Task; `queue_dropped` or the end of the session sends it back to `waiting` (decision 12, steps 3 to 5) |
| The 5,000 ms call timeout does not bound the mailbox of Hub: a caller that left frees its request slot while its call stays queued, and a late call still changes state | Codex (high) | Fixed: an admission count of 1,024 calls sent and not yet taken, `busy` past it, and a deadline in each call that Hub checks before it acts (decision 5) |
| The resume of a delivery has no deadline: the tool checks of `Helyx.Session.resume/2` have no timeout, so four stalled resumes hold every delivery slot | Codex (high) | Fixed: Hub kills a delivery Task 120,000 ms after its start; the wake-up stays `sending`, and the next try checks the transcript first (decision 12) |
| The transcript check claimed 1,000 messages and 16 MiB; the tail cuts on bytes too and can be the newest group alone | Codex (medium) | Fixed: the check reads the snapshot, then `history/4` pages, up to 1,000 messages; each piece has the cut of `wire-protocol.md`, the newest group included, one at a time |
| The per-user cap refused a `resume` that attaches to a running session | Codex (medium) | Fixed: only a `resume` of a session that does not run needs a place; the race with a stop is an accepted hole |
| The count of live sessions needs `list_live/1` (5,000 ms) inside the Hub process, inside the 5,000 ms of `check` | spec (defect) | Fixed: the live set, monitors of the sessions that Hub started or attached to, read from `list_live/1` once at the start of Hub in a Task; callbacks run in the caller, and no Core call runs in the Hub process (decisions 5, 14) |
| `resume {cwd}` scans `list_saved/2` (10,000 ms) inside a 5,000 ms `check`, and in an unnamed process | spec (defect) | Fixed: the scan runs in the caller and has its own 10,000 ms; the reply bound of that resume is stated |
| `unsubscribe` named, but `Helyx.Session` has no public one | spec (defect) | Fixed: the subscription ends at the `:DOWN` of the Task |
| The cap of #859 holds only on the wire; a tool start would pass it | spec (defect) | Fixed: `start_session/3`, `authorize/4`, `owner/2` run the same `check` and `result` |
| The session operations gain error codes that the doc did not list | spec (defect) | Fixed: a table of the new errors per operation (decision 7) |
| The protocol 4 schema held the #870 codes with no marker | spec (defect) | Fixed: every #870 line is marked; #870 adds them with protocol 5 |
| The open of the store said "no wait" and "after the busy wait" | spec (wording) | Fixed: 5,000 ms |
| "a new owner" in decision 13: no operation changes an owner | spec (wording) | Fixed |
| The reason of the monitor hole named the transport's processes | spec (wording) | Fixed: the transport has no list of connections by user |
| A revoke of the connection's own token: the close comes before the reply | spec (wording) | Fixed: stated |
| Wake-ups leave sessions running and can fill the Core | spec (wording) | Fixed: accepted hole |
| The transport does not check the params that `check` returns | spec (wording) | Fixed: stated, with the reason |
| A reader reaches a stopped session only by its record | spec (wording) | Fixed: stated in decision 4 |
| A child of another user's session shows its id in the TUI but cannot be subscribed | spec (wording) | Kept: decision 8, Consequences, and Accepted holes state it |
| A Task holds a subscription and a resumed session: the template flags a Task holder | spec (wording) | Fixed: decision 12 says why the store makes it recoverable |

## Round 2 (reduced: Codex and spec)

Both reproduced defects, by reading the code. The confirmation of a wake-up got a second finding on one mechanism, so round 2 changed the mechanism, not the path: the retry no longer guesses whether an earlier send can still run. A wake-up is never sent twice into one session instance; the row keeps the instance that may hold the prompt, and a send again needs a transcript with no message and a new instance (decision 12).

| Finding | Source | Resolution |
|---|---|---|
| A wake-up that `prompt/3` queues behind client follow-ups (any wait, not only an abort) can wait past the 120,000 ms kill; the next try misses it and sends again | spec (defect) | Fixed by the mechanism above; the kill covers only the resume and the check; the confirmation ends with the life of the wake-up and a last check, `unconfirmed` when it finds nothing |
| The schema had no next-try time, and a retry did not say its state, so a resume error could skip the check | spec (defect) | Fixed: `next_try_at`, `instance_id`, states `waiting` and `sent`, outcome `unconfirmed` |
| The Task subscribes to instance A, the prompt reaches instance B; the end of A sent the wake-up back to `waiting`; `:slow` the same | Codex (high) | Fixed: an end of the subscription keeps `sent`, and the next try checks; the narrow case where B queued it is an accepted hole, the same one as the agent tool's prompt on an id |
| After a restart of Hub, a revoked token keeps working: the callbacks got only the user | Codex (high) | Fixed: `hello` gives a credential with the token id; every Hub call of `check`, `run`, `result` checks it and gives `{:close, 4403}` |
| A reserved place of `start_session/3` whose Core start fails stays with a caller that lives on | Codex (medium) | Fixed: the `release` callback after a failed Core call, and an expiry of 60,000 ms; a start slower than that is an accepted hole |
| The mailbox bound counted only the callers of the transport | spec (wording) | Fixed: 4,096 reserved places, also through `start_session/3` |
| A cross-reference to step 4 for the resume errors | spec (wording) | Fixed: step 6 |
| The prompt call that exits on its timeout was not specified | spec (wording) | Fixed: the row stays `sent` |

## Round 3 (reduced: Codex and spec): open

Both reproduced defects, by reading the doc against the code. Round 3 is the last round of `/ship`. The small-fix round does not apply: the defects are a third finding on the delivery of a wake-up (decision 12), one mechanism, and two of them are in the admission and the reservation of Hub calls. The doc is committed as round 3 reviewed it; these findings are open, and #870 (and #869 for the admission count) must not build decision 12 or the admission count as written until they are settled.

| Finding | Source | State |
|---|---|---|
| A resume error (`too_many_sessions` and the others of step 6) writes `waiting` over a row in `sent`, so the next try skips the check of step 3 and can send a wake-up that the transcript holds | Codex (high) | open: keep `sent` and `instance_id` at a transient error, change only `next_try_at` |
| A row in `sent` never gets a `next_try_at`, so the poll never picks it up again; the accepted hole claims a try within 30,000 ms | spec (defect) | open |
| A prompt call that exits on its timeout and that the session drops as a late call leaves `sent` in the same instance: the Task waits the whole life and the other schedules of the session end `missed`; a `queue_dropped` that comes while no Task is subscribed ends `unconfirmed`, against "lost only when the session never took it" | spec (defect) | open: two loss paths with no accepted hole |
| The last check of an expired `sent` row resumes the session with no end: the tool checks of `Helyx.Session.resume/2` have no timeout, the 120,000 ms kill keeps the row, and each retry repeats it; the schedule never advances | Codex (medium), spec (defect) | open: a terminal path that writes `unconfirmed` |
| A caller killed between the add to the admission count and the send leaves the count up; repeated losses fill the 1,024 places | Codex (medium) | open: the count needs an owner of each place, or a release at the death of the caller |
| The mailbox row counts 64 delivery Tasks, the bounds row 64 + 4; how Hub learns that a Task left steps 1 to 3; a `busy` or an exit of the write of `sent` must send nothing | spec (defect) | open |
| `pending` of the codec, how a row comes due at `at`, the end of a one-run row | spec (wording) | open |
| A kill at 120,000 ms during a resume can start a session outside the live set | spec (wording) | open: an accepted hole to state |
| `4503` also answers `busy` and an exit of the Hub call | spec (wording) | open |

Question for the owner, from the rule on two findings on one mechanism: the confirmation of a wake-up keeps finding paths. One way out is to drop exactly-once by the transcript and pick one plain guarantee: at most once (send once, record `sent`, never send again; a lost wake-up shows `unconfirmed`), or at least once (send again after any doubt; a doubled wake-up is the hole). Either removes the instance tracking of decision 12.

## The decision of the owner, and the revision after round 3

The owner answered the question of round 3 on #868 (2026-11-06): at most once. Hub sends a wake-up once and never again; a wake-up in doubt ends `unconfirmed`, and the user sends it again by hand. The instance tracking goes, and the admission count is derived from the live callers. The other four choices of the first commit stand (the default owner, `helyx serve` starts Hub in #869 and the schedule ops come with protocol 5 in #870, the close codes `4403` and `4503`, SQLite through `exqlite` with exclusive locking and a store in memory for a Core with no data folder).

The revision of decision 12 removes the transcript check, the subscription and the history pages of the delivery Task, the confirmation, the states `waiting` and `sent`, the column `instance_id`, the last check, and the accepted holes that only they needed. The new rule: a write of the outcome `unconfirmed` and the next pending wake-up comes before the prompt call, so no path sends twice; a definite refusal (`turn_running`, `queue_full`, `session_not_found`) writes the row back. The round-3 items, after the revision:

| Round 3 item | State |
|---|---|
| A resume error writes over `sent` and skips the check | gone with `sent` and the check; a resume error comes before the decided write |
| A row in `sent` gets no `next_try_at` | gone; a row is pending with a `next_try_at`, set to the start plus 150,000 ms when its Task starts |
| A late call or a `queue_dropped` with no Task subscribed loses the wake-up outside the holes | gone: an exit of the call is `unconfirmed` by the rule; a queued and dropped wake-up shows `delivered`, an accepted hole |
| The last check resumes with no end | gone: no last check; a pending row past its life ends `missed` with no resume |
| A caller killed before its send leaves the admission count up | fixed: no stored count; the caller reads the mailbox length of Hub, bound 1,024 plus one for each live caller, 2,628 |
| Two maximums of delivery Tasks | fixed: one per session and 4 in all |
| How Hub learns the step of a Task; a failed write of the decided send | fixed: no step tracking; a failed write sends nothing |
| `pending`, a row that comes due at `at`, a one-run row after its run | fixed in decision 12 and the op table |
| A kill during a resume starts a session outside the live set | an accepted hole |
| `4503` on `busy` and an exit | fixed in the close codes and the bounds |
| The ownership row of a reserved place named only `result` | fixed: `result`, `release`, the `:DOWN`, the 60,000 ms timer |

## Round 4 (reduced: Codex and spec)

The last round that the brief of the owner allows. Both reproduced the first defect, by reading the code.

| Finding | Source | Resolution |
|---|---|---|
| `session_not_found` of the prompt call was read as "took nothing", but `Helyx.Session.Call.call_pid/3` (`lib/helyx/session/call.ex:16-23`) gives it also for a session that died in the call, and an idle session writes the user message before its reply (`TurnLoop.admit/3`): the row went back and the wake-up could be sent twice | spec (defect), Codex (high) | Fixed in the small-fix round: `session_not_found` of the prompt call is `unconfirmed`; only `turn_running` and `queue_full` write the row back |
| After a crash of Hub, a Task of the old Hub still in its resume and a Task of the new Hub could both pass the write of step 2 | spec (defect) | Fixed in the small-fix round: the write of step 2 applies only when the row holds the run number and the `next_try_at` of the start of this Task; the Tasks are linked to Hub |
| "two Hub calls" in the deadline of a Task | spec (wording) | Fixed: at most four |
| The admission bound of 2,628 counts only the tools of #859 as callers of the Elixir API; a product or an operator that calls it from more processes passes the bound, so the mailbox has no fixed number | Codex (medium), spec (wording) | Open: the second finding on the admission bound (round 3: a caller that died before its send). The rule on two findings on one mechanism stops the patching; the derived bound of decision 5 needs a numeric limit on the callers of the Elixir API, or an accepted hole, which the owner decides |

## Small-fix round (reduced: Codex and spec)

The two fixes of decision 12 touch one file and a few lines, and are the first findings on the rule of at most once, so they took the small-fix round of `/ship`. Codex: approve, no material findings. Spec: no double send reproduced; it checked that `turn_running` and `queue_full` leave the session state unchanged (`turn_loop.ex:27`, `steering.ex:20-24`), that a late prompt call does not act (`calls.ex:15-22`), and the races of the write-back with a new Task and a delete. The round reproduced no defect, so the loop ended; its doc findings were fixed with no further round:

| Finding | Resolution |
|---|---|
| The accepted hole named three causes of `unconfirmed`; decision 12 gives more (`session_not_found`, a late reply of the write of step 2, a failed write of `delivered`, a failed write-back), and two of them show a wrong outcome | Fixed: the hole lists every cause and says the outcome can be wrong either way, the session getting the prompt at most once |
| `invalid_utf8` and `invalid_origin` of `prompt/3` not named | Fixed: they cannot come, and a crash leaves `unconfirmed` |
| The example of two Tasks cannot happen with the link | Fixed: the condition is a second guard |
| An empty section heading in this record | Fixed |

## The Codex gate, and the admission decision of the owner

The Codex gate of the orchestrator (round 1) found one defect, confirmed in the code: under a Hub, `sessions.saved` kept the page of Core and left out the sessions that the user may not read, but Core makes `next` as `<mtime>:<session id>` of the last summary of its page (`lib/helyx/sessions.ex:119`). When that summary was a hidden one, the cursor carried a private session id and its time, and with `limit: 1` a user could list every hidden session. Fixed: under an authority, `sessions.saved` goes to `run`; the authority reads the whole scan of Core (one `list_saved/2` with `limit: 256`, the 256 newest files), filters by access, then makes the page and `next` from readable sessions only (decision 7). The other operations were checked for the same leak: `hub.records.search` filters in its query before it pages, and its cursor is of a returned record; a project, a token, or a schedule of another user gives the answer of a missing one; `sessions.live` has no cursor; `history` pages only a session that the user may read; the shared Core cap tells only that the server is full (accepted hole). An access test list for #869 is in the doc.

The owner answered the open admission finding on #868 (2026-11-06): accept it as a stated hole; a product bounds its own callers of the Elixir API, the wire keeps its numbers, and Hub stores no count. Written in decision 5, the bounds, and the accepted holes.

## Round after the gate (reduced: Codex and spec)

Both confirmed that the cursor leak of `sessions.saved` is closed: one `list_saved/2` with `limit: 256` returns every summary of the scan of 256 files (`scan.ex:8`, `sessions.ex:22`, `:114`), with the order and the cursor format of Core (`sessions.ex:92`, `:116`, `:119`). Both found leak paths by reading the code; the round reproduced defects, and it was the one round that the brief allowed.

| Finding | Source | State |
|---|---|---|
| The scan takes the 256 newest files of every user before the filter, so a new private session of A pushes an old session of B out of B's `sessions.saved` and `resume` `{cwd}`: a count channel; the access test "the pages of B are the same as on a server where that session does not exist" cannot pass | Codex (medium), spec (defect) | fixed after the decision of the owner of 2026-11-06: the listings read the store (see below) |
| The default owner gets a derived record for an id with no row, and `session_not_found` for a private session of another user, so it can tell that such a session exists | Codex (medium), spec (defect) | fixed after the decision of the owner of 2026-11-06: an existence check before a derived record (see below) |
| A shared record returned the project id of its owner to other users | Codex (medium) | fixed in the small-fix round: `project` is null for a user who does not own the project |
| `hub.records.search` does not reach the default owner's sessions with no record | spec (wording) | fixed |
| `resume` `{cwd}` under a Hub orders by file time, Core by header time | spec (wording) | fixed: stated |
| The deadline and the encoder slot of the `run` of `sessions.saved` | spec (wording) | fixed: 15,000 ms and the encoder slot |

## Small-fix round after the gate (reduced: Codex and spec)

The fix of the project id is one line of the op table and a first finding, so it took the small-fix round; the wording fixes went with it. Spec: no leak reproduced; the fixes (a) to (c) hold, `scan.ex:113` and `sessions.ex:92`, `:116` confirm the order of (c), and the encoder slot of `wire-protocol.md` holds. Codex reproduced a leak by reading the code, so the loop stops here, and the doc is committed as this round reviewed it. Open:

| Finding | Source | State |
|---|---|---|
| The delivery id `<schedule id>:<run number>` is the origin id of the prompt; Core keeps it in the message, and the wire sends it in events and `history`, so a reader of a `"hub"` session learns the private schedule id and the run count of its owner | Codex (medium) | open: an opaque delivery id (random, kept in the schedule row) and an access test that reads a scheduled message as another user |
| The Bounds row "`check`, `result`, `run`: 5,000 ms each" contradicts the 15,000 ms of the `run` of `sessions.saved` (decisions 5 and 7); the transport Interface changes do not name that deadline | spec (defect, contradiction) | open: one row and one line |
| "the 256 newest files of the data folder" is wrong with a `cwd`: the scan takes the 256 newest files of that folder (`scan.ex:120`, `:131`) | spec (defect, false claim) | open: "of the folder of `cwd`, or of the data folder without one" |
| The project-null rule is in the op table, not in the `record` codec; "a user who does not own the record" is the plainer rule | spec (wording) | open |
| The order of `bad_params` and the access check is not stated (an error-order channel) | spec (wording) | open |

## Fixes after the small-fix round (no review round; the Codex gate of the orchestrator follows)

At the request of the orchestrator, the open items that need no decision of the owner were fixed without a review round:

| Open item | Fix |
|---|---|
| The delivery id showed the schedule id and the run count to readers of a `"hub"` session | A random delivery id of 12 characters for each pending wake-up, kept in the schedule row (`delivery_id`); a write-back keeps it; an access test reads a scheduled message as another user |
| The Bounds row of `check`, `result`, `run` against the 15,000 ms `run` of `sessions.saved` | The row and the transport changes name the 15,000 ms |
| "the 256 newest files of the data folder" with a `cwd` | The 256 newest files of the folder of `cwd`, or of the whole data folder with no `cwd` |
| The project-null rule only in the op table | In the `record` codec: null for a user who does not own the record |
| The order of `bad_params` and the access check | Stated in decision 5: the params first, so `bad_params` never depends on an object of another user; an access test |

The two channels for the owner were fixed after the decision below.

## The two channels, after the decision of the owner (no review round; the Codex gate of the orchestrator follows)

The owner decided on #868 (2026-11-06) to fix both channels.

| Channel | Fix in the doc |
|---|---|
| The scan of 256 files across users | `sessions.saved` and `resume` `{cwd}` read the stored records of the store, where the owner and the visibility are columns (decision 7); the records gain `cwd`, `model`, `prompt` (1,024 bytes), and `active_at`, written by the `result` of a start and by the Hub calls of `check` (Store schema). Only the derived records of the default owner come from the scan of Core. A page is one Hub call of at most `limit` + 1 rows in 5,000 ms; with the scan for the default owner, 15,000 ms. A record whose file was deleted stays listed until a `resume` gets `not_found`, which deletes the row (decision 8, accepted hole) |
| The derived record of the default owner | Before a derived record, a check confirms that the session runs or that `Helyx.Session.File.Scan.find/2` finds its file; a missing session and a private session of another user both give `session_not_found` (decision 8). The access tests run with B as the default owner too |

A deviation from the words of the decision, for the gate and the owner: the decision names "one file stat" as the bound of the check. One stat cannot do it: an id with no row has no stored `cwd`, and the path of a session file depends on its `cwd` (`Helyx.Session.File.path/4`, `Helyx.Session.File.Scan.folder/3`); Core finds a file by id by listing the folders and matching the names (`Scan.find/2`, `lib/helyx/session/file/scan.ex`), which also avoids a built path that a filesystem that ignores case could match for another id. So the check is that find, in a Task with a deadline of 5,000 ms; past the deadline it answers `session_not_found`, and its memory is the names that the listing read by then. Both are in the accepted holes of the doc.

## Guarantee table (spec agent, round 1)

| Guarantee about existing code | Proof |
|---|---|
| `Helyx.Sessions.resume/2` gives `:not_found` with no `:sessions_dir` | `lib/helyx/sessions.ex:168-173` |
| `list_saved/2` limit 1 to 256 | `lib/helyx/sessions.ex:22`, `:114` |
| `list_live/1` at most 64, 5,000 ms per call | `lib/helyx/sessions.ex:43-62` |
| `start/2` with `:parent` gives a derived child id | `lib/helyx/session.ex:72`, `:86` |
| Children are out of the list; the scan reads 256 files | `lib/helyx/session/file/scan.ex:8`, `:24-25`, `:59-62` |
| `prompt/3` takes `origin: %{kind: :product, id}`, gives `:turn_running` and `:queue_full` | `lib/helyx/session.ex:293-305` |
| A prompt during an abort wait queues as a follow-up | `lib/helyx/session/server/turn_loop.ex:25-31` |
| The user message of a turn emits `message_start` and `message_end` | `lib/helyx/session/server/records.ex:22-23` |
| A follow-up is dropped with `queue_dropped` at an abort | `lib/helyx/session.ex:326-336` |
| `subscribe/2` `tail` 1 to 1,000; one subscription per caller | `lib/helyx/session.ex:170-200` |
| `history/4` pages, `ack/2` | `lib/helyx/session.ex:211-232` |
| `max_text_bytes/0` is 4 MiB | `lib/helyx/session/input.ex:13` |
| A session id is 12 URL-safe characters of 9 random bytes | `lib/helyx/session/id.ex:8`, `:23` |
| The HMAC proof, the constant-time compare, `4401` | `plugins/bundled/lib/helyx/transport/web_socket/connection.ex:84-85`, `:116-123` |
| A `{:close, code}` message closes after the frames before it | `connection.ex:246` |
| `:invalid_options`, `:token_required` | `plugins/bundled/lib/helyx/transport/web_socket.ex:57-70` |
| Deadlines 30,000, 10,000, 6,000, 5,000 ms; 64 connections, 16 requests in flight | `wire-protocol.md`, Deadlines and Bounds; `web_socket.ex:33` |
| The data folder mode check, the server token, the server file, sessions that stay running | `serve.md`, decisions 4, 7, 8, 11 |
| Print mode runs in its own node | `tui-attach.md`, decision 12 |
| Two instances of one id in two Cores | `CONTEXT.md`, "Session instance" |
| Users, tokens, the store, the authority, schedules, wake-ups, `4403`, `4503`, the caps | decisions for #869 and #870 |
