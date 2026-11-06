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
