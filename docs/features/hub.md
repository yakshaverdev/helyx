# Helyx.Hub

Ticket #868, part of #853. The decisions of ADR 0010 (`docs/adr/0010-hub.md`) hold; this doc gives the codec, the schema, the rules, and the bounds that it leaves to the feature doc (ADR 0010, Consequences, item 1). Tickets #869 (Hub, users, records, the authority of the transport, the store) and #870 (schedules and wake-ups) build from it.

## Goal

`Helyx.Hub` is a bundled module in `plugins/bundled` that a product starts beside Core and `Helyx.Transport.WebSocket`. It gives the server users and their credentials, a record for each session (owner, project, title, labels, visibility, archive), search over the records, and schedules that prompt a session at a time. It uses only the public session API and the server-management API (`Helyx.Session`, `Helyx.Sessions`); Core never names it, and the transport knows it only as an authority (decision 5).

User stories:

- A user starts a session on the laptop, gives it a title and the label `release`, and finds it on the phone with `hub.records.search`. Another user of the same server gets no record of it in a search, no line of it in `sessions.live`, and `session_not_found` when the user subscribes to its id.
- A user saves a prompt that runs each day at 08:00 UTC in one session. The server stopped the session overnight; at 08:00 Hub resumes it and prompts it once, and the user reads the result in any client.
- The single user of `helyx serve` runs `helyx -p` in a folder, and an agent call of a session starts a child. Neither start goes through Hub; the user sees both sessions, as before Hub.

### Decisions

1. **Users.** A user is a row of the store: an id that Hub makes (12 characters, the base64url of 9 random bytes, the shape of a session id), and a name of 1 to 64 bytes of UTF-8 with no control character, unique in the Hub. A Hub holds at most 64 users. Users are made and removed with the Elixir API of Hub (`Helyx.Hub.add_user/2`, `remove_user/2`), which a product puts behind its own command; the wire has no operation that makes a user. Reason: the wire carries no secret (decision 2), and a user with no token cannot connect, so the step that makes a user is the step that shows its first token, on the terminal of the operator. One user is the **default owner** of the Hub: the option `:default_owner` names it, and Hub makes it at its start when the store does not hold it. The default owner cannot be removed. Every user of a Hub runs tools as the OS user of the server: Hub separates records and access, not folders or processes. The isolation of one user from another is executor assignment (ADR 0010 §2, after #856), out of scope here.

2. **Credentials: tokens first.** A token is the text `<token id>.<secret>`: the token id is 12 characters, the base64url of 9 random bytes, and the secret 43 characters, the base64url of 32 random bytes, with no padding; 56 characters in all. `Helyx.Hub.create_token/3` makes one for a user and returns its text once; the store keeps the token id, the user, a name of 1 to 64 bytes of UTF-8, the time it was made, and the key, `SHA-256(token text)`, never the text. A user holds at most 16 tokens. A user lists the ids and names of its tokens and revokes one over the wire (`hub.tokens.list`, `hub.tokens.revoke`); no frame makes a token or carries its text. Reason: the rule of ADR 0008, revision of 2026-10-18, holds for every credential of a user (ADR 0010 §3). The key in the store gives the access that the token gives: the store file has mode 0600 in a folder that its group and other users cannot write (decision 9), the trust boundary of the session files. OIDC comes later, when a deployment needs it (ADR 0010, Consequences, item 5).

3. **The proof in `hello`.** The proof is the proof of protocol 3 (`docs/features/wire-protocol.md`, Connection): the base64 of HMAC-SHA256 with the key `SHA-256(token text)` over the 32 bytes of the nonce. `hello` gets the optional field `token`, the token id, so the authority finds the key without a scan. A `hello` with `token` is checked against the key of that token. A `hello` with no `token` is checked against the **server token**, the option `:server_token` of Hub, a closure that returns the token text as `child_spec/1` of the transport does, and its user is the default owner; a Hub started with no server token closes such a connection with `4401`. An unknown token id, a revoked token, a missing proof, and a wrong proof all close with `4401`, after the authority computed an HMAC with a key of 32 random bytes for an unknown id, so the answer does not tell whether the token id exists. The proof is compared in constant time, as today. Reason: `helyx serve` keeps its server file and its TUI connect (`docs/features/serve.md`, decisions 7 and 8) and gives the server token to Hub in place of the transport; a phone or a second user gets a token of its own, which a revoke ends alone.

4. **Visibility.** A record has one of two values. `"private"`, the default: only the owner reaches the session. `"hub"`: every user of the Hub can read the session: list it, subscribe to it, read its history, and read its record. Only the owner writes: a prompt, a steer, a follow-up, an abort, a model change, a compaction, an answer, a stop, a resume, a record change, and a schedule. A reader can `subscribe` and read `history` only while the session runs, as for any client, and cannot resume it: a stopped session of another user shows its record and its line in `sessions.saved`, not its transcript. Reason: several humans in one session are out of scope (ADR 0010, Consequences); a team still needs to watch a session that another user runs.

5. **The authority of the transport.** The transport gets the option `:authority`, `{module, arg}`, where `module` implements the behaviour `Helyx.Transport.WebSocket.Authority` of the transport; `Helyx.Hub.authority/1` gives the value for a Hub. The transport names no Hub module. A transport with `:authority` takes no `:token`: both give `{:error, :invalid_options}`, and an address that is not loopback needs one of the two. A transport with no authority keeps the server token of ADR 0008 §6 and answers every `hub.*` operation with `unknown_op`.

   Each callback runs in the process of the transport that calls it, never in the Hub process. It reads and writes the store through **Hub calls**: a call to the Hub process with a timeout of 5,000 ms. Each callback makes one Hub call. Before it, the `check` of a `start` or `resume` looks up whether the session runs (`Helyx.Session.pid/1`, a Registry lookup), and the `check` of a `resume` of a folder first scans the folder in the caller (decision 7). A Core call (`Helyx.Sessions.list_saved/2`, `list_live/1`) never runs in the Hub process, so a slow session stalls no other user. The Hub process takes a call only while its **admission count** allows: the caller adds one to a shared counter (`:atomics`) before it sends, and Hub takes one off when it takes the message. Past 1,024 the caller gets `busy` at once and sends nothing, so the mailbox of Hub holds at most 1,024 calls, also when callers left after their timeout. Each call carries its deadline; Hub drops a call that it takes at or past the deadline, before it reads or writes anything, as Core drops a late session call (`docs/features/session-lifecycle.md`, "Late calls"). So a client that got `timeout` gets no late change of state. The callbacks:

   - `hello(arg, hello)` with `%{nonce: binary, token: String.t() | nil, proof: String.t() | nil, connection: pid}`: `{:ok, auth}` or `:error`, where `auth` is the credential of the connection, `%{user: user_id, token: token_id | nil}` (nil for the server token), opaque to the transport, which passes it to every later callback as `user`. It runs in the connection process, after the protocol check and in place of the proof check of today. `:error` closes with `4401`. An exit of the Hub call (a timeout, a Hub that is down) and `busy` close with the new code `4503`: the client connects again later. Hub monitors the connection pid from `{:ok, auth}` on (decision 13).
   - `check(arg, user, op, params)`: `{:ok, params}`, `{:error, code}`, or `{:close, 4403}`. Its Hub call first checks that the credential still holds: the user exists, and its token, when it has one, is not revoked. A credential that no longer holds gives `{:close, 4403}`, and the transport closes the connection with that code instead of a reply; `run` and `result` check the credential the same way. So a revoke ends the use of a token at its next request, also after a restart of Hub, which loses the monitors of decision 13. It runs before every `req`, a `subscribe` too, in the worker of the request or in the subscription process, after the transport checked the params and before the Core call. `{:ok, params}` can give other params of the same operation: the `resume` of a folder becomes the `resume` of an id (decision 7). The transport does not check them again: the authority makes them from params that the transport checked, and a value that only Core checks still meets Core. `{:error, code}` is the reply of the request; an exit is `timeout`. `unsubscribe` gets no check: it acts on a subscription of the connection.
   - `run(arg, user, op, params)`: `{:ok, result}` or `{:error, code, text}`, for an `op` that starts with `hub.`. The transport checks only that `params` is an object and the decode bounds of the frame; Hub checks each param at its entry (decision 6, Bounds), so `bad_params` of a `hub.*` operation is Hub's answer.
   - `result(arg, user, op, params, result)`: `{:ok, result}` or `{:error, code}`, after a Core call of `sessions.live`, `sessions.saved`, `start`, or `resume` succeeded. It filters the lists and writes the record of a started session.
   - `release(arg, user, op, params)`: `:ok`, after the Core call of a `start` or `resume` that `check` passed failed or exited, so the reserved place of decision 14 goes back at once.
   - `close(pid, code)`, a function of the transport, not a callback: the authority closes a connection with `4403` when the access of its user changes (decision 13). It sends the connection the message of a close that a writer decides, so the frames that the connection took before it run first (`wire-protocol.md`, Close codes).

   The deadline of an operation (`wire-protocol.md`, Deadlines) starts after `check` and ends with its Core call; `check` and `result` have their own bounds beside it: one Hub call each, 5,000 ms, and for the `check` of a `resume` of a folder the scan of `Helyx.Sessions.list_saved/2` first, 10,000 ms, the deadline of `sessions.saved`. So a `start` replies within 5,000 + 30,000 + 5,000 ms, a `resume` of a folder within 15,000 + 30,000 + 5,000 ms, and every other operation within 5,000 + its deadline + 5,000 ms. A `hub.*` operation has the deadline of 6,000 ms of "every other operation", which holds its one `run` call. Reason: the deadlines of protocol 3 are derived from Core bounds; a Hub call is a separate bound, stated once.

   The Elixir API of Hub for a product and for the tools of #859 (`start_session/3`, `authorize/4`, Interface changes) runs the same `check`, Core call, and `result` as the wire, so a start through a tool meets the same caps.

6. **The `hub.*` operations.** One namespace on the same wire (ADR 0010 §3), protocol 4. The codec is under "Interface changes". Hub answers a session that the user may not read with `session_not_found`, as a session that does not exist, and a write to a session that the user may read but does not own with `forbidden`: such a user already sees the session, so the code tells nothing new. Records, projects, tokens, and the user are the ops of #869; schedules are the ops of #870.

7. **The session operations under a Hub.** They keep their codec. Access as decision 4:

   | Operation | Rule under a Hub |
   |---|---|
   | `sessions.live` | the live sessions that the user may read |
   | `sessions.saved` | the page of Core with the sessions that the user may not read left out; a page can hold fewer items than its `limit`, and `next` still pages on. Core scans the 256 newest files of the data folder (`Helyx.Session.File.Scan`), so a user of a busy Hub finds older sessions with `hub.records.search` |
   | `start` | any user, within the caps (Bounds); `result` writes the record when the user is not the default owner (decision 8) |
   | `resume` `{id}` | the owner; any other user gets `not_found`, the answer of `resume` for a session that does not exist. A session that runs is attached, as today, also at the cap of decision 14 |
   | `resume` `{cwd}` | the `check`, in the caller, makes it the `resume` of the newest session of the folder that the user owns, from one call of `Helyx.Sessions.list_saved/2` for the folder with the limit 256; none gives `not_found` |
   | `subscribe`, `history` | a user who may read; any other gets `session_not_found` |
   | `prompt`, `steer`, `follow_up`, `abort`, `set_model`, `compact`, `answer`, `stop` | the owner; a reader gets `forbidden`, any other user `session_not_found` |
   | `unsubscribe` | no check |

   The check before `subscribe` guards the event stream with the same rule as the record (ADR 0010 §3). The error codes that the session operations gain under a Hub, for the op table of `wire-protocol.md`:

   | `op` | new errors |
   |---|---|
   | `start` | `too_many_records` (`too_many_sessions` is there already and also answers the cap of decision 14) |
   | `resume` | none: the cap of decision 14 answers `too_many_sessions`, a refusal `not_found` |
   | `prompt`, `steer`, `follow_up`, `abort`, `set_model`, `compact`, `answer`, `stop` | `forbidden` |
   | `sessions.live`, `sessions.saved`, `subscribe`, `history`, `unsubscribe` | none |

   Every operation can also answer `busy` when the admission count of Hub is full (decision 5); `busy` is in the list of every operation already.

8. **A session with no Hub record: the default owner.** A session that has no row in the store has a derived record: the default owner of the Hub, no project, no title, no labels, `"private"`, not archived. Hub writes a row only when the derived record is not the record: at the `start` of a user who is not the default owner, and at the first `hub.records.update`. This covers every start that does not go through Hub: a child of the agent tool (`Helyx.Sessions.start/2` with `:parent`, `docs/features/agent-tool.md`), a print run (`helyx -p`, which runs in its own node, `docs/features/tui-attach.md`, decision 12), a session that a product starts with the session API, and every session from before the Hub. Under `helyx serve` the default owner is its single user, so that user sees every session, as before Hub.

   Reason. The other rule, a record at every start, cannot hold: Hub sees only the starts that come through it, Core never names Hub (ADR 0010 §1), and Core gives no notice of a start, so a start by a tool, by print mode, or by a product writes no record. A rule that fails for these starts would leave their sessions invisible to everyone under deny by default. The derived record needs no write for them, so it has no write that can fail, race, or be lost in a crash. The default owner is the operator of the server, who can read every session file in the data folder anyway, so no session becomes visible to someone who could not read it before.

   Consequences. On a Hub of several users, a child that the agent tool starts in a session of another user is owned by the default owner: the other user reads the final text of the child in the tool result of the parent, but cannot subscribe to the child. A start of that user that Hub saw but whose record write failed (decision 5, `result`) goes to the default owner too (Accepted holes). `hub.records.delete` removes a row, and the session goes back to the default owner.

9. **The store.** `Helyx.Hub.Store` is a behaviour of Hub; `Helyx.Hub.Store.SQLite` is the first implementation, with the library `exqlite`, a new dependency of `helyx_plugins`. The Hub process is the only caller of the store: every read and every write runs in it, so a cap check and its insert are one step, and no lock of Hub spans two processes. The file:

   - **Under `helyx serve`**: `<data folder>/hub.db`, where the data folder is the `:sessions_dir` of Core. The server lock makes one server per data folder (`serve.md`, decision 4), so one Hub opens the file.
   - **Outside `helyx serve`** (a product that starts Hub itself): the option `:path`, default `<sessions_dir>/hub.db`. Hub refuses a folder of the file that its group or other users can write, with the check of `helyx serve` (`mode &&& 0o022 == 0`), and makes the file with mode 0600. The store owns its file by the lock of SQLite: it opens the file with `PRAGMA locking_mode = EXCLUSIVE` and takes the write lock at the open (`BEGIN EXCLUSIVE`, then `COMMIT`), and the lock stays until the connection closes. A second Hub on the same file, in the same node or in another OS process, fails its start with `{:error, :store_locked}`; a test of #869 checks both. The lock ends with the OS process, so a killed VM leaves no stale lock.
   - **A Core with no data folder** (`:sessions_dir` nil, and no `:path`): the store is a SQLite database in memory, which ends with the Hub process. Reason: such a Core persists no session and resumes none (`Helyx.Sessions.resume/2` gives `{:error, :not_found}`), so records and schedules that outlive it would name sessions that no longer exist. A product that wants lasting users gives `:path`.

   The store sets `PRAGMA journal_mode = WAL` for a file, `foreign_keys = ON`, and a busy timeout of 5,000 ms. The schema version is in `PRAGMA user_version`; a file of another version stops the start with `{:error, {:store_version, n}}`, with no migration in the first build.

10. **Routing.** A Hub serves one Core, its option `:core`, and every session id routes to that Core. A product with several Cores in one node starts one Hub and one transport for each, each Hub with its own store: two Cores can hold one id with two instances (`CONTEXT.md`, "Session instance"), and one record over two instances would give one owner to two sessions. A client reaches one Core through the transport that it connects to. The map across nodes waits for a deployment with more than one node (ADR 0010 §2).

11. **Schedules** (#870). A schedule belongs to a user and a session that the user owns, and holds a prompt of at most 16,384 bytes, the next time `at` (POSIX seconds, UTC), and `every`: null for one run, or a period of 300 to 2,678,400 seconds (31 days). After each run the next time is `at + every`, then again until it is past now, so a stop of the server that spans several periods gives one run, not one for each. A period is in seconds of UTC: "each day at 08:00" in a zone with daylight saving moves by one hour twice a year (Accepted holes). A schedule of a session that the user no longer owns (a record delete, a user removed) is deleted at its next run, with the outcome `refused`.

12. **Wake-ups** (#870). A wake-up is the run of one schedule at one time. Its delivery id is `<schedule id>:<run number>`, and it is the `id` of the product origin of its prompt, `origin: %{kind: :product, id: delivery_id}` of `Helyx.Session.prompt/3`. Hub keeps one pending wake-up per schedule in the schedule row, so the pending wake-ups of a session are at most its 16 schedules. The row holds the state of the wake-up: `waiting` (not sent, `next_try_at` says when), or `sent` (a prompt call went out or may have gone out, with the `instance_id` of the session instance that the Task saw before the call).

    **The rule: never send a wake-up twice into one session instance.** A wake-up is **delivered** when its user message is in the transcript, not when `prompt/3` answers `:ok`: in any wait of the session (the end of a turn, an abort), `prompt/3` queues the text as a follow-up behind the queued steers and up to 32 follow-ups (`Helyx.Session.Server.TurnLoop.admit/3`, `Helyx.Session.Queue`) and answers `:ok`, and an abort or a failure of the turn can drop the queue in a `queue_dropped` event. The queue of an instance ends with the instance. So a wake-up that may sit in the queue of an instance is never sent into that instance again; it is sent again only when the transcript does not hold it and the instance that may have queued it has ended. Reason: the second round of the review found two paths (a Task killed while its prompt waited behind follow-ups, and a subscription that ended while the prompt went to a newer instance) that sent a wake-up twice; both came from a retry that did not know whether the earlier send could still run.

    A delivery runs in a Task:

    1. When the session does not run, the Task resumes it with `Helyx.Sessions.resume(core, id: id)`, after a place of the live set of the owner (decision 14); at the cap the wake-up waits.
    2. The Task subscribes with `Helyx.Session.subscribe/2` and `tail: 1000`, before any send, so it misses no event after it; the snapshot gives the `instance_id`. One subscription serves the check and the confirmation (a caller holds one subscription of a session). It acks the events it takes (`Helyx.Session.ack/2`).
    3. **The check**, for a row in `sent`: the Task looks for a user message with the origin id in the snapshot, then in `Helyx.Session.history/4` pages before it, until it has read 1,000 messages or there are no more. Found: delivered. Not found and the `instance_id` of the row is the current one: the earlier send may still be queued, so the Task goes to the confirmation of step 5 and sends nothing. Not found and another instance: the earlier send is lost with its instance, and the Task goes on to step 4. The snapshot and each page have the cut of `wire-protocol.md` (Bounds, "tail snapshot and page"): at most 16,777,216 bytes of message content, or the newest group alone, which can be larger; the Task holds the snapshot and one page at a time, and the pages go on to 1,000 messages whatever the byte cut.
    4. The Task writes `sent` with the `instance_id` of step 2, then sends `Helyx.Session.prompt/3` with the origin. `{:error, :turn_running}` and `{:error, :queue_full}` write `waiting` with `next_try_at` 30,000 ms later: the session took nothing. An exit of the call (its timeout of 5,000 ms) leaves `sent`: the session may have taken it.
    5. **Confirmation.** The `message_end` of a user message with the origin id confirms the delivery: the Task writes `delivered` and the next time, and ends. The session stays running after the turn, as a session that a client resumed (`serve.md`, decision 11). A `queue_dropped` event that holds the message writes `waiting` with `next_try_at` 30,000 ms later: the instance dropped it, so no copy is left in it. The end of the subscription (the session ended, `:slow`, a crash of the Task) leaves `sent`, and the next try begins at step 1 with the check.
    6. **When a turn runs**, `prompt/3` answers `{:error, :turn_running}`, and the wake-up waits (step 4), so it runs as its own turn after the running one. Hub does not steer and does not queue a follow-up itself. The resume errors `too_many_sessions`, `{:session_locked, id}`, `{:lock_failed, text}`, and `:open_timeout` write `waiting` with `next_try_at` 30,000 ms later too. Any other error (`not_found`, `text_too_large`, a session that the owner may no longer write) ends the wake-up with the outcome `refused`.
    7. **The life of a wake-up** is 3,600 seconds from its due time. A row in `waiting` past it ends with the outcome `missed`. A row in `sent` past it gets one last check (steps 1 to 3, with no send; when the session does not run, the resume of step 1 runs for it): found, `delivered`; else the outcome `unconfirmed`, and it is never sent again, so it is lost only when the session never took it (Accepted holes). A recurring schedule goes on with its next time.

    **Deadlines of a Task.** Hub kills a delivery Task that has not finished steps 1 to 3 within 120,000 ms of its start: the resume (the open in the session process, at most 30,000 ms by the bounds of `wire-protocol.md`, Deadlines, after the tool checks, which have no timeout in Core) and the check. Steps 4 and 5 have no kill of their own: the prompt call ends within its timeout, and the confirmation ends at the end of the life of the wake-up, when Hub kills the Task and runs the last check. A killed Task leaves its row as it was, and its subscription ends at the `:DOWN` of the Task in the session. The Task holds a subscription and can resume a session: the template flags a Task as a holder, and here the row in the store holds the state that matters, so the next try or the next start of Hub recovers it.

    Hub runs at most one delivery Task for each session, and at most 4 Tasks in steps 1 to 3 at once, under the task supervisor of Hub; so at most 64 Tasks wait in a confirmation, one for each live session. The others wait in the store, in order of their `next_try_at`. Hub reads the rows whose `next_try_at` has come each 1,000 ms (at most 64 rows each read) and at its start.

13. **Access that changes.** Hub keeps the connections of each user, from the `hello` callback, with a monitor: at most 64, the connection cap of the transport. A revoke of a token closes the connections that proved it, a remove of a user closes its connections, and a record change that takes read access from a user (a change to `"private"`, a delete) closes the connections of every user but the owner that may no longer read it, each with `4403`. A revoke of the token of the connection that sends it closes that connection too: the close comes before the reply, so the client sees `4403` and no `res`. The client connects again; its next `subscribe` to that session gets `session_not_found`. Reason: the check runs before each `req` and `subscribe`, so an open subscription would go on streaming a session that its user may no longer read. A close covers it with no list of subscriptions in Hub; a change of access is rare.

14. **Caps for the coordinator** (#859). Hub keeps the **live set**: the session processes that a start or resume through Hub made or attached to, each with a monitor, and at the start of Hub every live session of its Core, read once with `Helyx.Sessions.list_live/1` in a Task (5,000 ms; past it the set starts empty). At most 64 entries, the Core cap. The live sessions of a user are the entries of the live set whose record, derived or stored, names that user as owner; Hub reads the owners of at most 64 ids in one query at the count, so a record change moves the count with it. A `start`, or a `resume` of a session that does not run (decision 5: the `check` looks it up), of a user at the cap answers `too_many_sessions`, as the Core cap does. A `resume` of a session that runs attaches and needs no place. The cap is the option `:max_live_sessions`, 1 to 64, default 64, the Core cap: under `helyx serve`, the single user keeps the bound of today. Hub counts a `start` or `resume` that `check` passed and whose `result` has not come as a reserved place, so two starts at the same moment cannot both pass the last place; Hub frees the place at `result`, which adds the session to the live set, at `release`, at the `:DOWN` of the process that called `check` (Hub monitors it), or 60,000 ms after `check`, whichever comes first. The last bound holds for a caller of `start_session/3` that lives on and never comes back: the wire deadline of a `start` is 30,000 ms, and a start through the Elixir API that is still open after 60,000 ms adds its session at its `result`, so the count can pass the cap by such slow starts (Accepted holes). The same rule bounds the records: a `start` of a user who is not the default owner reserves a record place too. A session that the agent tool, print mode, or a product starts without Hub after the start of Hub is not in the live set: the Core cap bounds it, and a child counts against no user. The other caps that #859 names are the records of a user (10,000) and the schedules of a session (16), in "Bounds".

15. **`helyx serve` starts Hub** (#869). The order in the serve process: Core, Hub with `core:`, `default_owner: "owner"`, and `server_token:` the closure of the server token, then the transport with `authority: Helyx.Hub.authority(hub)` in place of `token:`. The stop runs the other way: the transport, then Hub (decision 16), then Core. The server file, its token, and the connect of the TUI do not change (decision 3).

16. **The stop of Hub.** Hub kills its delivery Tasks (a killed wake-up keeps its row, and a row in `sent` gets the check of decision 12 at its next try), closes the store, and ends within 5,000 ms. Reason: the transport stopped first, so no request waits for Hub, and a killed delivery is recovered by the transcript check.

## Interface changes

### Hub

- `Helyx.Hub` (new, `plugins/bundled/lib/helyx/hub.ex`): `child_spec/1` and `start_link/1` with the options `:core` (required), `:default_owner` (required, a user name), `:server_token` (a 0-arity closure, optional), `:path`, `:store` (default `Helyx.Hub.Store.SQLite`), `:max_live_sessions`, and `:name`. A bad option gives `{:error, {:invalid_option, key}}`; a held store `{:error, :store_locked}`.
- The Elixir API of the operator, each a Hub call: `add_user(hub, name)`, `remove_user(hub, user_id)`, `users(hub)`, `create_token(hub, user_id, name)` (`{:ok, token_text}`, the only return of the text), `revoke_token(hub, token_id)`, `authority(hub)`.
- The Elixir API of the session for a product and for the tools of #859, in the caller as the callbacks of decision 5: `start_session(hub, user_id, opts)`, the `start` of the wire with its `check`, `Helyx.Sessions.start/2`, and `result`, giving `{:ok, %Helyx.Session{}}` or the error code; `authorize(hub, user_id, op, session_id)`, the `check` of a session operation, `:ok` or `{:error, code}`, for a caller that then calls `Helyx.Session` itself; `owner(hub, session_id)`, the owner of the derived or stored record, so a tool finds the user of its own session. #870 adds `schedule(hub, user_id, params)` with the rules of `hub.schedules.create`.
- `Helyx.Hub.Store` (new): the behaviour of the store, with `open/1` (the options, the lock, the schema check), `close/1`, and one callback for each query: `users/1`, `add_user/3`, `remove_user/2`, `token/2`, `tokens/2`, `add_token/2`, `revoke_token/3`, `record/2`, `records/2` (a list of at most 256 session ids, for the filter of a list), `put_record/2`, `delete_record/3`, `search/3`, `count_records/2`, `projects/2`, `put_project/2`, `delete_project/3`, and for #870 `schedules/3`, `put_schedule/2`, `delete_schedule/3`, `due/3` (the wake-ups due at a time, at most a limit). #869 fixes the exact arities with the code.
- `Helyx.Hub.Store.SQLite` (new): the implementation of decision 9.

### Store schema (SQLite, `user_version` 1)

```sql
CREATE TABLE users (
  id TEXT PRIMARY KEY,               -- 12 characters of base64url
  name TEXT NOT NULL UNIQUE,         -- 1 to 64 bytes
  created_at INTEGER NOT NULL        -- POSIX seconds
) STRICT;

CREATE TABLE tokens (
  id TEXT PRIMARY KEY,               -- the token id, 12 characters
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,                -- 1 to 64 bytes
  key BLOB NOT NULL,                 -- SHA-256 of the token text, 32 bytes
  created_at INTEGER NOT NULL
) STRICT;

CREATE TABLE projects (
  id TEXT PRIMARY KEY,               -- 12 characters
  owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,                -- 1 to 128 bytes
  created_at INTEGER NOT NULL,
  UNIQUE (owner, name)
) STRICT;

CREATE TABLE records (
  session_id TEXT PRIMARY KEY,       -- a session id (Helyx.Session.Id.valid?/1)
  owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
  title TEXT NOT NULL DEFAULT '',    -- 0 to 256 bytes
  visibility TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'hub')),
  archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT;
CREATE INDEX records_owner ON records (owner, updated_at);
CREATE INDEX records_visibility ON records (visibility, updated_at);

CREATE TABLE labels (
  session_id TEXT NOT NULL REFERENCES records(session_id) ON DELETE CASCADE,
  label TEXT NOT NULL,               -- 1 to 64 bytes
  PRIMARY KEY (session_id, label)
) STRICT;

-- #870
CREATE TABLE schedules (
  id TEXT PRIMARY KEY,               -- 12 characters
  owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL,          -- no foreign key: a session with no record has a schedule too
  prompt TEXT NOT NULL,              -- 1 to 16,384 bytes
  at INTEGER NOT NULL,               -- the next time, POSIX seconds
  every INTEGER,                     -- null, or 300 to 2,678,400
  run INTEGER NOT NULL DEFAULT 0,    -- the number of the pending or next run
  state TEXT NOT NULL DEFAULT 'waiting' CHECK (state IN ('waiting', 'sent')),
  due_at INTEGER,                    -- the due time of the pending wake-up; its life ends 3,600 s later
  next_try_at INTEGER,               -- when the next try of the pending wake-up may start
  instance_id TEXT,                  -- in 'sent': the session instance that may hold the prompt
  last_at INTEGER,
  last_outcome TEXT CHECK (last_outcome IN ('delivered', 'missed', 'refused', 'unconfirmed')),
  created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX schedules_at ON schedules (at);
CREATE INDEX schedules_next_try ON schedules (next_try_at);
CREATE INDEX schedules_session ON schedules (session_id);
```

A user removed takes its tokens, projects, records, labels, and schedules with it; its sessions go back to the default owner (decision 8).

### Transport

- `Helyx.Transport.WebSocket`: the option `:authority`, and `close/2` (decision 5). The protocol number goes to 4, and the schema of `wire-protocol.md` gets the lines below.
- `Helyx.Transport.WebSocket.Authority` (new): the behaviour of decision 5.
- New close codes: `4403`, the access of the user changed (decision 13); `4503`, the authority did not answer the `hello` within 5,000 ms.

### Wire schema additions (protocol 4)

#869 puts these lines in the schema of `wire-protocol.md`, with its SHA-256, but the lines and the alternatives marked `#870`: the three `hub.schedules.*` ops, the codes `too_many_schedules` and `unknown_schedule`, their params and results, and `schedule`. #870 adds them with protocol 5, by the rule of ADR 0008 §7.

```text
hello = {type: "hello", protocol: int, proof?: base64, token?: id}

op += "hub.me" | "hub.records.get" | "hub.records.update" | "hub.records.delete"
    | "hub.records.search" | "hub.projects.list" | "hub.projects.create"
    | "hub.projects.update" | "hub.projects.delete" | "hub.tokens.list"
    | "hub.tokens.revoke"
    | "hub.schedules.list" | "hub.schedules.create" | "hub.schedules.delete"   # #870

error_code += "forbidden" | "too_many_records" | "too_many_projects"
            | "unknown_project" | "unknown_token"
            | "too_many_schedules" | "unknown_schedule"                        # #870

params.hub.me              = {}
params.hub.records.get     = {session: string}
params.hub.records.update  = {session: string, title?: string, labels?: [string],
                              visibility?: "private" | "hub", project?: string | null,
                              archived?: bool}
params.hub.records.delete  = {session: string}
params.hub.records.search  = {query?: string, labels?: [string], project?: string,
                              archived?: bool, mine?: bool, after?: string, limit?: int}
params.hub.projects.list   = {}
params.hub.projects.create = {name: string}
params.hub.projects.update = {project: string, name: string}
params.hub.projects.delete = {project: string}
params.hub.tokens.list     = {}
params.hub.tokens.revoke   = {token: string}
# the lines from here to the end of the block marked #870 come with #870
params.hub.schedules.list   = {session?: string}
params.hub.schedules.create = {session: string, at: int, every?: int, prompt: string}
params.hub.schedules.delete = {schedule: string}

result.hub.me              = {user: user}
result.hub.records.get, result.hub.records.update = {record: record}
result.hub.records.search  = {items: [record], next: string | null}
result.hub.projects.list   = {projects: [project]}
result.hub.projects.create, result.hub.projects.update = {project: project}
result.hub.tokens.list     = {tokens: [token]}
result.hub.records.delete, result.hub.projects.delete, result.hub.tokens.revoke = {}
result.hub.schedules.list   = {schedules: [schedule]}                       # #870
result.hub.schedules.create = {schedule: schedule}                          # #870
result.hub.schedules.delete = {}                                            # #870

user     = {id: string, name: string}
record   = {session: string, owner: user, project: string | null, title: string,
            labels: [string], visibility: "private" | "hub", archived: bool,
            stored: bool, created_at: int | null, updated_at: int | null}
project  = {id: string, name: string, created_at: int}
token    = {id: string, name: string, created_at: int}
schedule = {id: string, session: string, at: int, every: int | null, prompt: string,
            pending: bool, last_at: int | null,
            last_outcome: "delivered" | "missed" | "refused" | "unconfirmed"
                        | null}                                              # #870
```

| `op` | errors, beyond `unknown_op`, `bad_params`, `busy`, `timeout`, `failed` | notes |
|---|---|---|
| `hub.me` | | the user of the connection |
| `hub.records.get` | `session_not_found` | a session with no row gives the derived record, `stored: false`, with null times; Hub does not check that the session exists: any id that the user may read has a record |
| `hub.records.update` | `session_not_found`, `forbidden`, `too_many_records`, `unknown_project`, `bad_params` | at least one field; `labels` replaces the set, duplicates removed; `project: null` clears it; the first update of a derived record writes the row |
| `hub.records.delete` | `session_not_found`, `forbidden` | the row goes; the session falls under decision 8; its schedules go at their next run (decision 11) |
| `hub.records.search` | `bad_params` | the stored records that the user may read (`mine: true`: only its own), newest `updated_at` first; `query` matches the title as a substring, ASCII case folded; `labels` must all be on the record; `after` is the `next` of the page before; `limit` 1 to 256, default 50. A derived record is not in a search: the default owner finds those sessions with `sessions.saved` |
| `hub.projects.*` | `too_many_projects`, `unknown_project`, `bad_params` | the projects of the user; a name taken by another project of the user is `bad_params`; a delete clears the project of its records |
| `hub.tokens.list` | | the tokens of the user, never a key or a text |
| `hub.tokens.revoke` | `unknown_token` | a token of the user; its connections close with `4403` |
| `hub.schedules.create` | `session_not_found`, `forbidden`, `too_many_schedules`, `text_too_large`, `bad_params` | the user owns the session; `at` from now to now + 31,622,400 s (366 days), and a past `at` is `bad_params`; `prompt` of 1 to 16,384 bytes |
| `hub.schedules.list` | `session_not_found` | the schedules of the user, of one session or all |
| `hub.schedules.delete` | `unknown_schedule` | the row and its pending wake-up go, and its Task is killed; a prompt that the session already took or queued still runs |

## Replaced mechanism

The authorization of a connection, when the transport has an authority. A transport with no authority keeps all of it, and its tests keep their properties.

1. **The proof of one server token at `hello`, then every operation and subscription open** (ADR 0008 §6, `Connection.proof?/3` in `plugins/bundled/lib/helyx/transport/web_socket/connection.ex`). Replaced by the `hello` callback, which proves a user (decision 3), and the `check` before every `req` and `subscribe` (decision 5). The `challenge`, the nonce, the HMAC, the constant-time compare, the close `4401`, the auth wait of 5,000 ms, and the rule that no frame holds a secret stay. The server token moves from the transport to Hub, in a closure.
2. **`sessions.live`, `sessions.saved`, and `resume` `{cwd}` over every session of the Core.** Under a Hub they reach only what the user may read or owns (decision 7). A client of one user under `helyx serve` sees no change: the default owner owns every session with no record.
3. **The deadlines of the operations.** They stay; the calls of the authority add their own bound around them (decision 5).
4. **The protocol number** goes from 3 to 4. A client of protocol 3 gets `refused` with `4426`, by ADR 0008 §7. The TUI of the same build speaks 4.
5. Tests: the tests of the proof, the auth wait, the secret in terms and logs (`plugins/bundled/test/helyx/transport/web_socket_test.exs`) keep their properties for a transport with no authority, and #869 runs the proof tests through the authority too: a `hello` with the server token, with a token id, with an unknown id, with a revoked token, with no proof.
6. Unbounded state: none new. Every table of the store has a row bound (Bounds).

## Bounds

| What | Bound | Over the bound | Where enforced |
|---|---|---|---|
| users of a Hub | 64 | `add_user/2` gives `{:error, :too_many_users}` | Hub |
| user name | 1 to 64 bytes of UTF-8, no control character, unique | `{:error, :invalid_name}` | Hub API |
| tokens of a user | 16 | `create_token/3` gives `{:error, :too_many_tokens}` | Hub |
| token name | 1 to 64 bytes of UTF-8, no control character | `{:error, :invalid_name}` | Hub API |
| `token` of `hello` | an id, 1 to 64 bytes (the frame rule); a stored id is 12 characters | an id of another shape, unknown, or revoked: close `4401` | transport (the shape), Hub (the lookup) |
| the `hello` callback | 5,000 ms, a call to the Hub process | close `4503` | transport |
| `check`, `result`, `run` | 5,000 ms each, a call to the Hub process | `timeout` | transport |
| the mailbox of the Hub process | the 1,024 calls of the admission count, the ends of at most 64 delivery Tasks, the poll timer and the expiry timers of the reserved places, and the `:DOWN` of at most 64 connections, 64 live sessions, and the callers of the reserved places: at most 4,096 places, 64 users at a cap of 64, also through `start_session/3` | n/a | Hub |
| reserved places | 64 per user, the cap of decision 14; each ends at `result`, `release`, the `:DOWN` of its caller, or 60,000 ms | a `check` over the cap gets `too_many_sessions` | Hub |
| records of a user | 10,000 stored rows, with the reserved places of the starts that `check` passed (decision 14) | `hub.records.update` of a derived record gives `too_many_records`; so does the `check` of a `start` of a user who is not the default owner, before Core starts anything | Hub |
| records of a Hub | 640,000: 64 users of 10,000 | as above | Hub |
| title | 0 to 256 bytes of UTF-8, no control character | `bad_params` | Hub |
| labels of a session | 16 | `bad_params` | Hub |
| label | 1 to 64 bytes of UTF-8, no control character | `bad_params` | Hub |
| projects of a user | 256 | `too_many_projects` | Hub |
| project name | 1 to 128 bytes of UTF-8, no control character | `bad_params` | Hub |
| search `query` | 0 to 256 bytes | `bad_params` | Hub |
| search page | 1 to 256 records, default 50; the scan reads at most the 640,000 rows of the Hub through the indexes on owner and visibility | `bad_params` | Hub |
| the ids of one `records/2` call | 256, the largest page of `sessions.saved`; `sessions.live` is at most 64 | n/a | Hub |
| `resume` `{cwd}` under a Hub | the 256 heads of the scan of `Helyx.Sessions.list_saved/2` | `not_found` when none of them is the user's | Hub, Core |
| live sessions of a user | `:max_live_sessions`, 1 to 64, default 64, with the reserved places of decision 14 | `too_many_sessions` | Hub |
| connections that Hub tracks | 64, the connection cap of the transport | n/a | the transport |
| schedules of a session | 16 | `too_many_schedules` | Hub (#870) |
| schedules of a user | 256 | `too_many_schedules` | Hub (#870) |
| pending wake-ups of a session | 16: one in each schedule row | n/a | Hub (#870) |
| pending wake-ups of a Hub | 16,384: 64 users of 256 schedules | n/a | Hub (#870) |
| schedule `prompt` | 1 to 16,384 bytes of UTF-8 | `text_too_large`; an empty one `bad_params` | Hub (#870) |
| schedule `at` | from now to now + 31,622,400 s (366 days) | `bad_params` | Hub (#870) |
| schedule `every` | null, or 300 to 2,678,400 s | `bad_params` | Hub (#870) |
| delivery Tasks | one per session; at most 4 in the resume and the check at once, so at most 64 + 4 | the others wait in the store, by `next_try_at` | Hub (#870) |
| the poll of due wake-ups | each 1,000 ms, at most 64 rows each | the rest at the next poll | Hub (#870) |
| the wait of a wake-up when its session is stopped | the resume, within its bound of 30,000 ms (`wire-protocol.md`, Deadlines: the lock and the load of a file of at most 64 MiB), in the delivery Task; a resume that fails with an error of decision 12, step 6, tries again after 30,000 ms | the wake-up waits | Hub (#870), Core |
| the wait of a wake-up when a turn runs | a try each 30,000 ms (`next_try_at`) | after 3,600 s from the due time: `missed` | Hub (#870) |
| the life of a wake-up | 3,600 s from its due time, a wait after a restart too; a confirmation ends there | `waiting`: `missed`; `sent`: one last check, then `delivered` or `unconfirmed`; a recurring schedule goes on | Hub (#870) |
| the prompt call of a delivery | the call timeout of `Helyx.Session.prompt/3`, 5,000 ms | the row stays `sent` (decision 12, step 4) | Core |
| the transcript check of a wake-up in `sent` | 1,000 messages: a tail snapshot of `tail: 1000`, then `history/4` pages; each holds at most 16,777,216 bytes of message content or the newest group alone (`wire-protocol.md`, Bounds), and the Task holds the snapshot and one page at a time | not found: sent again only in another instance (decision 12, step 3; Accepted holes) | Hub (#870), Core |
| events in the mailbox of a delivery Task | the credits of a subscription, 16,384 unacked events; the Task acks what it takes | the session ends the subscription with `:slow`: the row stays as it is, and the next try checks first | Core |
| a delivery Task in the resume and the check | 120,000 ms from its start (decision 12) | Hub kills it; the row stays as it was | Hub (#870) |
| a delivery Task in the confirmation | until the end of the life of its wake-up | Hub kills it and runs the last check | Hub (#870) |
| the admission count of Hub calls | 1,024 calls sent and not yet taken (decision 5) | the caller gets `busy` at once; a `hello` closes with `4503` | the callers, by a shared counter |
| a Hub call that Hub takes at or past its deadline | dropped before it reads or writes | n/a: its caller already answered `timeout` | Hub |
| webhook payload | 1,048,576 bytes; the prompt that a payload becomes stays under `Helyx.Session.max_text_bytes/0` | HTTP 413, no wake-up | the webhook endpoint, a later ticket (Out of scope) |
| the stop of Hub | 5,000 ms | the supervisor of the product kills it; a wake-up in `sent` is checked at the next start | Hub |
| SQLite busy wait | 5,000 ms (`busy_timeout`) | the query fails: the operation answers `failed` | the store |
| the open of the store | 5,000 ms: `BEGIN EXCLUSIVE` on a file that another connection holds fails after the busy wait | `{:error, :store_locked}` | the store |
| the store file | no bound of its own: the row bounds above, at most about 2 KB a record with its labels and 17 KB a schedule, give about 1.6 GB at every cap | n/a | Hub |

Every numeric limit gets tests at the limit, one under, one over, and, for the byte bounds of a text, a multibyte character at the edge.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
|---|---|---|---|---|---|
| the Hub process | the supervisor of the product | the supervisor of the product | the stop of Hub (decision 16) | the supervisor of the product starts it again; the store reopens | n/a |
| the SQLite connection and its file lock | `open/1` of the store in the Hub process | the Hub process | `close/1` at the stop | the NIF resource is freed with the process heap, and the lock with the connection; the OS frees the lock when the VM ends | n/a |
| the store file `hub.db` and its WAL files | the store, mode 0600 | the disk | stay | stay; SQLite recovers the WAL at the next open | n/a |
| a delivery Task | the Hub process, under the task supervisor of Hub | the task supervisor | it ends after its write: `delivered`, `waiting`, or an outcome | its row stays as it was in the store: a row in `sent` gets the check of decision 12, step 3, at the next try; a session that it resumed keeps running | Hub kills it at its deadlines (decision 12), and the stop of Hub kills it; the same recovery |
| an entry of the live set (decision 14) | `result` of a start or resume, and the read of `list_live/1` at the start of Hub | the Hub process, with a monitor of the session process | the `:DOWN` of the session | gone with Hub; the next start of Hub reads `list_live/1` again | n/a |
| the admission count (decision 5) | the start of Hub | the Hub process; the counter is shared with the callers | the stop of Hub | a new Hub makes a new counter at zero; a caller of the old one gets an exit, answered `timeout` | n/a |
| a session that a wake-up resumed | `Helyx.Sessions.resume/2` in a delivery Task | Core | runs until a client stops it or the server stops (`serve.md`, decision 11) | n/a: Core holds it | n/a |
| the subscription of a delivery Task | the delivery Task (`Helyx.Session.subscribe/2`) | the delivery Task | the end of the Task: the session drops it at its `:DOWN` of the Task (`Helyx.Session` has no public unsubscribe) | the same `:DOWN` | the kill of the Task at its deadline: the same `:DOWN` |
| a reserved place of a start (decision 14) | `check` of a `start` or `resume` | the Hub process, with a monitor of the caller | `result` | the `:DOWN` of the caller frees it; a crash of Hub frees every place with its state | n/a |
| the monitor of a connection (decision 13) | the `hello` callback | the Hub process | the `:DOWN` of the connection | gone with Hub; the connections keep running, and a change of access after the restart of Hub does not close a connection that proved itself before it (Accepted holes) | n/a |

## Accepted holes

- **Hub crash between a start and its record.** A `start` of a user who is not the default owner, whose `result` call times out or meets a crash of Hub, leaves a session with no row: the default owner owns it (decision 8), and the user gets `timeout` or `failed`. The default owner is the operator, who can read the file anyway.
- **A prompt that reaches a newer instance.** `Helyx.Session.prompt/3` acts on the id, not on one instance (the same hole as in `docs/features/agent-tool.md`, "The cleanup acts on the process of the call"). When the instance that the Task subscribed to ends, and a new instance of the id starts, between the subscribe and the prompt call, the new instance takes the prompt and the Task sees the end of the old one. The row names the old instance, so the next try checks the transcript of the new one: it finds the message when the new instance began its turn, and sends again only when the new instance queued it in a wait and has not run it yet; then both copies run. An exact fix needs a prompt bound to one instance in the session API, a Core change that waits for evidence.
- **A wake-up that the session never took ends `unconfirmed`.** A row in `sent` whose prompt never reached the session (Hub crashed after the write of `sent` and before the call, or the call exited before the session took it) waits in its instance until the end of its life and ends `unconfirmed`, not sent. The rule of decision 12 picks a lost wake-up over a doubled one; the outcome tells the user.
- **A wake-up whose message is older than the 1,000 newest messages** of a new instance when Hub checks it is sent again. The check runs at the next try, at most 30,000 ms after the end of the old instance or at the start of Hub, so more than 1,000 messages after the wake-up means that the session ran on for a long time while Hub was down.
- **Slow starts through the Elixir API.** A reserved place ends 60,000 ms after its `check`; a start of `start_session/3` that takes longer adds its session at its `result`, so the user can pass the cap by such starts. The Core cap still holds.
- **A resume that races a stop.** A `resume` whose `check` found the session running needs no place of the cap (decision 14); when the session stops before the resume, the resume starts a new instance with no place, and the user can pass the cap by the resumes in that window. The Core cap still holds.
- **Wake-ups fill the Core.** A session that a wake-up resumed stays running (decision 12, step 5). Within the cap of each user, the sessions of many schedules can hold the 64 places of the Core, and a start then gets `too_many_sessions` until a client stops one.
- **A session with `persisting: false`** (a failed write) loses its messages with the VM; a wake-up in it that the VM took before its stop is not in the file and is sent again after the restart, which is the right outcome: the turn was lost.
- **Daylight saving.** A period is in seconds of UTC, so a daily schedule moves by one hour in a zone with daylight saving. A rule of a calendar with a zone needs a time zone database that the BEAM does not bundle.
- **Children of another user.** On a Hub of several users, a child of the agent tool belongs to the default owner (decision 8, Consequences).
- **Monitors after a Hub restart.** Hub rebuilds no connection list after a crash: a connection that proved itself before keeps its open subscriptions after a later revoke or change of access until it closes. Its next `req` or `subscribe` meets the `check`: a revoked token or a removed user closes the connection with `4403`, and a session that it may no longer read answers `session_not_found`. Reason: the transport gives the authority each connection at its `hello` only and has no list of connections by user that Hub could read after a restart.
- **No folder isolation between users.** Every user of a Hub runs tools as the OS user of the server, in any folder that `start` admits (decision 1).

## Out of scope

- Executor assignment: after the ADR of remote hands (#856), ADR 0010, Consequences, item 4.
- Event subscriptions with their webhook endpoint, push notifications, routing across nodes, and OIDC: later tickets when a deployment needs them (ADR 0010, Consequences, item 5). The webhook payload bound above holds for that endpoint.
- Users made or removed over the wire, and a command of `helyx` that does it: a product ticket when a second user is needed.
- A migration of the store schema: the first build refuses another `user_version`.
- Several humans in one session, billing, and a web client (ADR 0010).
- A calendar rule with time zones for schedules (Accepted holes).
