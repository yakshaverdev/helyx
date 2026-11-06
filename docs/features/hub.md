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

   Each callback runs in the process of the transport that calls it, never in the Hub process. It reads and writes the store through **Hub calls**: a call to the Hub process with a timeout of 5,000 ms. Each callback makes one Hub call. Before it, the `check` of a `start` or `resume` looks up whether the session runs (`Helyx.Session.pid/1`, a Registry lookup), and the `check` of a `resume` of a folder first scans the folder in the caller (decision 7). A Core call (`Helyx.Sessions.list_saved/2`, `list_live/1`) never runs in the Hub process, so a slow session stalls no other user. The **admission count** is derived from the live callers, not stored: before it sends, the caller reads the mailbox length of the Hub process (`Process.info(hub, :message_queue_len)`), and at 1,024 or more it gets `busy` at once and sends nothing. No counter exists, so a caller that dies leaves nothing behind: a call that it never sent never counted, and a call that it sent stays in the mailbox until Hub takes it, and drops it when it is late. Callers that read at the same moment can each send one call past 1,024, so the mailbox holds at most 1,024 calls plus one for each live caller: the 1,024 requests in flight and 64 `hello` of the transport, the 4 delivery Tasks (decision 12), and the callers of the Elixir API, which for the tools of #859 are at most the 8 calls at once of a turn in each of the 64 sessions of the Core, 512; at most 2,628 calls. A product that calls the Elixir API from processes of its own adds one call for each of them: the Elixir API is called by trusted code in the VM of the product, as every other Core API is, and the product bounds its own callers (decision of the owner of 2026-11-06 on #868; Accepted holes). The wire keeps its numbers, and Hub stores no count of callers. Each call carries its deadline; Hub drops a call that it takes at or past the deadline, before it reads or writes anything, as Core drops a late session call (`docs/features/session-lifecycle.md`, "Late calls"). So a client that got `timeout` gets no late change of state. The callbacks:

   - `hello(arg, hello)` with `%{nonce: binary, token: String.t() | nil, proof: String.t() | nil, connection: pid}`: `{:ok, auth}` or `:error`, where `auth` is the credential of the connection, `%{user: user_id, token: token_id | nil}` (nil for the server token), opaque to the transport, which passes it to every later callback as `user`. It runs in the connection process, after the protocol check and in place of the proof check of today. `:error` closes with `4401`. An exit of the Hub call (a timeout, a Hub that is down) and `busy` close with the new code `4503`: the client connects again later. Hub monitors the connection pid from `{:ok, auth}` on (decision 13).
   - `check(arg, user, op, params)`: `{:ok, params}`, `{:error, code}`, or `{:close, 4403}`. Its Hub call first checks that the credential still holds: the user exists, and its token, when it has one, is not revoked. A credential that no longer holds gives `{:close, 4403}`, and the transport closes the connection with that code instead of a reply; `run` and `result` check the credential the same way. So a revoke ends the use of a token at its next request, also after a restart of Hub, which loses the monitors of decision 13. It runs before every `req`, a `subscribe` too, in the worker of the request or in the subscription process, after the transport checked the params and before the Core call. `{:ok, params}` can give other params of the same operation: the `resume` of a folder becomes the `resume` of an id (decision 7). The transport does not check them again: the authority makes them from params that the transport checked, and a value that only Core checks still meets Core. `{:error, code}` is the reply of the request; an exit is `timeout`. `unsubscribe` gets no check: it acts on a subscription of the connection.
   - `run(arg, user, op, params)`: `{:ok, result}` or `{:error, code, text}`, for an `op` that starts with `hub.`. The transport checks only that `params` is an object and the decode bounds of the frame; Hub checks each param at its entry (decision 6, Bounds), so `bad_params` of a `hub.*` operation is Hub's answer.
   - **The order of the checks.** The params come first, the access second: the transport checks the params of a session operation before `check`, and Hub checks every param of a `hub.*` operation, its shape and its bounds, before it reads any session, record, project, token, or schedule that the params name. So `bad_params` depends only on the request, never on an object of another user, and an object that the user may not reach gets the answer of a missing one only after its params passed.
   - `result(arg, user, op, params, result)`: `{:ok, result}` or `{:error, code}`, after a Core call of `sessions.live`, `start`, or `resume` succeeded. It filters the list of `sessions.live` and writes the record of a started session.
   - `sessions.saved` under an authority goes to `run`, not to the Core call of the transport: the authority makes the page itself from the store, and for the default owner also from the scan of Core (decision 7). A page that Core made and that a filter then thinned would carry a cursor of a session that the user may not read, and the scan of Core takes the newest files of every user, so the sessions of one user would push the sessions of another out of its list.
   - `release(arg, user, op, params)`: `:ok`, after the Core call of a `start` or `resume` that `check` passed failed or exited, so the reserved place of decision 14 goes back at once.
   - `close(pid, code)`, a function of the transport, not a callback: the authority closes a connection with `4403` when the access of its user changes (decision 13). It sends the connection the message of a close that a writer decides, so the frames that the connection took before it run first (`wire-protocol.md`, Close codes).

   The deadline of an operation (`wire-protocol.md`, Deadlines) starts after `check` and ends with its Core call; `check` and `result` have their own bounds beside it: one Hub call each, 5,000 ms, and for the `check` of a `resume` of a folder the scan of `Helyx.Sessions.list_saved/2` first, 10,000 ms, the deadline of `sessions.saved`. The `run` of `sessions.saved` under an authority holds the same scan, 10,000 ms, and one Hub call, 5,000 ms, so it replies within 5,000 + 15,000 ms. So a `start` replies within 5,000 + 30,000 + 5,000 ms, a `resume` of a folder within 15,000 + 30,000 + 5,000 ms, and every other operation within 5,000 + its deadline + 5,000 ms. A `hub.*` operation has the deadline of 6,000 ms of "every other operation", which holds its one `run` call. Reason: the deadlines of protocol 3 are derived from Core bounds; a Hub call is a separate bound, stated once.

   The Elixir API of Hub for a product and for the tools of #859 (`start_session/3`, `authorize/4`, Interface changes) runs the same `check`, Core call, and `result` as the wire, so a start through a tool meets the same caps.

6. **The `hub.*` operations.** One namespace on the same wire (ADR 0010 §3), protocol 5. The codec is under "Interface changes". Hub answers a session that the user may not read with `session_not_found`, as a session that does not exist, and a write to a session that the user may read but does not own with `forbidden`: such a user already sees the session, so the code tells nothing new. Records, projects, tokens, and the user are the ops of #869; schedules are the ops of #870.

7. **The session operations under a Hub.** They keep their codec. Access as decision 4:

   | Operation | Rule under a Hub |
   |---|---|
   | `sessions.live` | the live sessions that the user may read |
   | `sessions.saved` | made by the authority (decision 5, `run`), in the caller, from two sources, each filtered by access before the page and the cursor are made, so `items` and `next` hold only sessions that the user may read. **Stored records**, for every user: one Hub call reads the records that the user may read (its own, and the `"hub"` records of other users), of the folder `cwd` when the request names one, newest `active_at` first, then by session id, after the client's `after`, at most `limit` + 1 rows. The owner and the visibility are columns of the query, so the sessions of another user take no place in the page of a user and push none of its sessions out. An item of a stored record is its `cwd`, `model`, and `prompt` and its `active_at` as `mtime` (Store schema). **Derived records**, for the default owner only: one call of `Helyx.Sessions.list_saved/2` with the `cwd` of the request and `limit: 256`, the scan of Core, which covers the 256 newest files of the folder of `cwd`, or of the whole data folder with no `cwd` (`Helyx.Session.File.Scan`); the same Hub call drops the ids that have a row, and the rest are the derived records, with the fields of Core. The two lists merge newest first by `{mtime, id}`; the page is the first `limit` after `after`, and `next` is `<mtime>:<id>` of its last item, null when neither list holds more. An `after` of the client is parsed with the rule of Core (an integer, `:`, a session id; else `bad_params`) and only compared, so a cursor that a client makes tells it nothing. So the page of a user other than the default owner depends only on its own records and the `"hub"` records of others, and equals its page on a server where the private sessions of other users do not exist. The default owner finds its sessions with no record past the 256 files of the scan only by their id, as before Hub (Accepted holes). The transport gives this `run` the deadline of 15,000 ms (the scan of 10,000 ms and the Hub call of 5,000 ms), and it takes the encoder slot of the connection as `sessions.saved` does (`wire-protocol.md`, Bounds, "request results per connection") |
   | `start` | any user, within the caps (Bounds); `result` writes the record when the user is not the default owner (decision 8) |
   | `resume` `{id}` | the owner; any other user gets `not_found`, the answer of `resume` for a session that does not exist. A session that runs is attached, as today, also at the cap of decision 14 |
   | `resume` `{cwd}` | the `check`, in the caller, makes it the `resume` of the newest session of the folder that the user owns: one Hub call reads the stored record of the user with that `cwd` and the newest `active_at`; for the default owner, one call of `Helyx.Sessions.list_saved/2` for the folder with the limit 256 also gives the newest session of the folder with no row (dropped in the same Hub call), and the newer of the two by `{mtime, id}` wins. None gives `not_found`. Newest is the order of `sessions.saved` under a Hub, not the header time that the `resume` of a folder of Core uses (`Helyx.Session.File.Scan`) |
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

   Every operation can also answer `busy` when the mailbox of Hub is at its admission bound (decision 5); `busy` is in the list of every operation already.

8. **A session with no Hub record: the default owner.** A session that has no row in the store has a derived record: the default owner of the Hub, no project, no title, no labels, `"private"`, not archived. Hub writes a row only when the derived record is not the record: at the `start` of a user who is not the default owner, and at the first `hub.records.update`. This covers every start that does not go through Hub: a child of the agent tool (`Helyx.Sessions.start/2` with `:parent`, `docs/features/agent-tool.md`), a print run (`helyx -p`, which runs in its own node, `docs/features/tui-attach.md`, decision 12), a session that a product starts with the session API, and every session from before the Hub. Under `helyx serve` the default owner is its single user, so that user sees every session, as before Hub.

   Reason. The other rule, a record at every start, cannot hold: Hub sees only the starts that come through it, Core never names Hub (ADR 0010 §1), and Core gives no notice of a start, so a start by a tool, by print mode, or by a product writes no record. A rule that fails for these starts would leave their sessions invisible to everyone under deny by default. The derived record needs no write for them, so it has no write that can fail, race, or be lost in a crash. The default owner is the operator of the server, who can read every session file in the data folder anyway, so no session becomes visible to someone who could not read it before.

   **No derived record for a session that does not exist.** Before Hub derives a record for an id that has no row, a bounded check confirms that the session exists: it runs (`Helyx.Session.pid/1`, a Registry lookup), or `Helyx.Session.File.Scan.find/2` finds its file in the data folder of the Core. **One rule: before every operation on an id that has no row, Hub runs this check, and an id that it does not confirm gets the answer of a refused session before any Core call:** `session_not_found`, and `not_found` for `resume`. The check runs in the caller, in `check` (decision 5) for the session operations and before the Hub call for the `hub.*` operations, after the params check of the transport or of Hub and before any other step. Core is not relied on to answer a missing session first: some Core operations check a param before they look up the session (`Helyx.Session.set_model/2` checks the model ref first, `Helyx.Session.prompt/3` the origin), so a missing id would get the param error where a private session of another user gets `session_not_found`. The form of the check follows what the operation needs: an operation that needs a running session (`subscribe`, `history`, and the write operations of decision 7) confirms only that it runs, a Registry lookup, since a session that does not run gets `session_not_found` from Core too; `resume` `{id}`, `hub.records.get`, `hub.records.update`, `hub.records.delete`, and `hub.schedules.create` confirm that it runs or that its file exists. So for every user, the default owner too, an id with no session and a private session of another user give the same answer with the same text, whatever the other params hold.

   The check is one find, not one stat: an id with no row has no stored `cwd`, and the path of a session file depends on its `cwd` (`Helyx.Session.File.path/4`), so the find lists the folders of the data folder as the `resume` `{id}` of Core does, and matches the listed names, not a built path, which a filesystem that ignores case could match for another id. Core bounds neither the project folders nor the files in them, so the caller runs the find in a Task with a deadline of 5,000 ms and kills it past the deadline; a check that does not end in time answers `session_not_found`, and Hub derives nothing. A Core with no data folder has no file to find: only a running session exists. When Hub writes the row of a derived record (the first `hub.records.update`), it takes `cwd` and `model` from the header that the find returned, or, for a running session of a Core with no data folder, from `Helyx.Sessions.list_live/1`.

   **A record whose session file is gone.** The listings read the store and stat no file, so a stored record stays listed after its file was deleted, with its last `cwd`, `model`, `prompt`, and `active_at`. The first `resume` `{id}` of it that Core answers `not_found`, and the first resume of a wake-up that gets `not_found`, make Hub delete the row, as `hub.records.delete` does: the session then has no row, the check above finds no file, and every user gets `session_not_found`; its schedules end at their next run with `refused` (decision 11).

   Consequences. On a Hub of several users, a child that the agent tool starts in a session of another user is owned by the default owner: the other user reads the final text of the child in the tool result of the parent, but cannot subscribe to the child. A start of that user that Hub saw but whose record write failed (decision 5, `result`) goes to the default owner too (Accepted holes). `hub.records.delete` removes a row, and the session goes back to the default owner.

9. **The store.** `Helyx.Hub.Store` is a behaviour of Hub; `Helyx.Hub.Store.SQLite` is the first implementation, with the library `exqlite`, a new dependency of `helyx_plugins`. The Hub process is the only caller of the store: every read and every write runs in it, so a cap check and its insert are one step, and no lock of Hub spans two processes. The file:

   - **Under `helyx serve`**: `<data folder>/hub.db`, where the data folder is the `:sessions_dir` of Core. The server lock makes one server per data folder (`serve.md`, decision 4), so one Hub opens the file.
   - **Outside `helyx serve`** (a product that starts Hub itself): the option `:path`, default `<sessions_dir>/hub.db`. Hub refuses a folder of the file that its group or other users can write, with the check of `helyx serve` (`mode &&& 0o022 == 0`), and makes the file with mode 0600. The store owns its file by the lock of SQLite: it opens the file with `PRAGMA locking_mode = EXCLUSIVE` and takes the write lock at the open (`BEGIN EXCLUSIVE`, then `COMMIT`), and the lock stays until the connection closes. A second Hub on the same file, in the same node or in another OS process, fails its start with `{:error, :store_locked}`; a test of #869 checks both. The lock ends with the OS process, so a killed VM leaves no stale lock.
   - **A Core with no data folder** (`:sessions_dir` nil, and no `:path`): the store is a SQLite database in memory, which ends with the Hub process. Reason: such a Core persists no session and resumes none (`Helyx.Sessions.resume/2` gives `{:error, :not_found}`), so records and schedules that outlive it would name sessions that no longer exist. A product that wants lasting users gives `:path`.

   The store sets `PRAGMA journal_mode = WAL` for a file, `foreign_keys = ON`, and a busy timeout of 5,000 ms. The schema version is in `PRAGMA user_version`; a file of another version stops the start with `{:error, {:store_version, n}}`, with no migration in the first build.

10. **Routing.** A Hub serves one Core, its option `:core`, and every session id routes to that Core. A product with several Cores in one node starts one Hub and one transport for each, each Hub with its own store: two Cores can hold one id with two instances (`CONTEXT.md`, "Session instance"), and one record over two instances would give one owner to two sessions. A client reaches one Core through the transport that it connects to. The map across nodes waits for a deployment with more than one node (ADR 0010 §2).

11. **Schedules** (#870). A schedule belongs to a user and a session that the user owns, and holds a prompt of at most 16,384 bytes, the next time `at` (POSIX seconds, UTC), and `every`: null for one run, or a period of 300 to 2,678,400 seconds (31 days). After each run the next time is `at + every`, then again until it is past now, so a stop of the server that spans several periods gives one run, not one for each. A period is in seconds of UTC: "each day at 08:00" in a zone with daylight saving moves by one hour twice a year (Accepted holes). A schedule of a session that the user no longer owns (a record delete, a user removed) is deleted at its next run, with the outcome `refused`.

12. **Wake-ups** (#870): at most once (decision of the owner of 2026-11-06 on #868). A wake-up is the run of one schedule at one time. Its delivery id is a random id that Hub makes for each pending wake-up, the base64url of 9 random bytes (12 characters), kept in the schedule row; it is the `id` of the product origin of its prompt, `origin: %{kind: :product, id: delivery_id}` of `Helyx.Session.prompt/3`. The delivery id names no schedule and no run: Core keeps the origin in the message, and the wire sends it in events and `history` to every reader of the session (decision 4), so an id made of the schedule id and the run number would show a reader of a `"hub"` session the private schedule of its owner and its run count. Hub sends a wake-up into its session at most once and never sends it again. A wake-up in doubt, whose prompt call went out with no answer that says the session took nothing, ends with the outcome `unconfirmed`; the user reads the outcome in `hub.schedules.list` and sends the prompt again by hand. Reason: the first three rounds of the review found a new double or lost send in each design that tried to learn after a crash whether an earlier send could still run (a prompt in the queue of a wait, a newer instance of the session, a subscription that ended); at most once needs no such knowledge, and a doubled prompt can repeat work that changes files, which a lost one cannot.

    The schedule row holds the one pending wake-up of its schedule: its run number, its delivery id, its due time `due_at`, and `next_try_at`, when the next try may start. Each new pending wake-up gets a new delivery id; a write-back (step 3) keeps the one it had. The pending wake-ups of a session are so at most its 16 schedules. A new schedule, and each schedule after an outcome, gets `due_at` and `next_try_at` equal to its next time `at`; a schedule with `every` null has no next time after its run, so its row keeps its outcome with no pending wake-up (`pending: false`) and counts toward the caps until the user deletes it.

    Hub reads the rows whose `next_try_at` has come, each 1,000 ms (at most 64 rows each read) and at its start. A row past its life, 3,600 seconds after `due_at`, ends with the outcome `missed`. For any other row, when its session has no delivery Task and fewer than 4 Tasks run, Hub writes `next_try_at` to the start plus 150,000 ms, the deadline of the Task and one try more, and starts a delivery Task under the task supervisor of Hub, linked to the Hub process, so a crash of Hub ends its Tasks. A Task that dies or is killed before its send so leaves a row that comes due again by itself. The Task:

    1. When the session does not run, resumes it with `Helyx.Sessions.resume(core, id: id)`, after a place of the live set of the owner (decision 14). At the cap, and at the resume errors `too_many_sessions`, `{:session_locked, id}`, `{:lock_failed, text}`, and `:open_timeout`, it writes `next_try_at` 30,000 ms later and ends. Any other error (`not_found`, a session that the owner may no longer write) ends the wake-up with the outcome `refused`.
    2. **The send is decided.** It writes, in one Hub call, the outcome `unconfirmed` of this run and the next pending wake-up of the schedule (the next run, or none). The write applies only when the row still holds the run number and the `next_try_at` that Hub wrote when it started this Task; else the Task sends nothing and ends. The link to Hub (below) ends the Tasks of a Hub that crashed; this condition is a second guard, so that only the Task whose start is the last write of the row can send. Only after the reply of that write does it call `Helyx.Session.prompt/3` with the origin. When the write gets `busy`, `timeout`, or an exit, the Task sends nothing and ends: either the write did not happen and the row comes due again at its `next_try_at`, or it happened and the run ends `unconfirmed` with no send. The send never comes before a write that forbids a second one.
    3. **The answer.** `:ok`: the session took the prompt; the Task writes the outcome `delivered` of this run and ends. `{:error, :turn_running}` and `{:error, :queue_full}`, the only answers that prove it: the session took nothing, so the Task writes back the row as it read it before step 2 (the pending wake-up, its run number, its `due_at`, and the outcome of the run before it), with `next_try_at` 30,000 ms later, when the row still exists; the wake-up runs as its own turn after the running one, and Hub does not steer and does not queue a follow-up itself. `{:error, :text_too_large}`: the outcome `refused`. `{:error, :invalid_utf8}` and `{:error, :invalid_origin}` cannot come: the prompt is checked UTF-8 of at most 16,384 bytes, and the delivery id is a product origin id of 12 bytes; they would be a bug, and the Task crashes, which leaves `unconfirmed`. `{:error, :session_not_found}` leaves `unconfirmed`: `Helyx.Session.Call` gives it both when no process had the id and when the session process went down during the call (`lib/helyx/session/call.ex`), and an idle session writes the user message to its transcript when it takes the prompt, before its reply (`TurnLoop.admit/3`), so a session that died in the call may have taken it. An exit of the call (its timeout of 5,000 ms) leaves `unconfirmed` too. When one of these writes fails, the run keeps `unconfirmed`.

    `delivered` means that the session took the prompt, not that its turn ran: during a wait of the session, `prompt/3` queues the text as a follow-up and answers `:ok` (`Helyx.Session.Server.TurnLoop.admit/3`), and an abort or a failure of the turn can then drop it, which the clients see as a `queue_dropped` event (Accepted holes). The session stays running after the turn, as a session that a client resumed (`serve.md`, decision 11).

    **Bounds of a Task.** Hub kills a delivery Task 120,000 ms after its start: the resume, the open in the session process at most 30,000 ms by the bounds of `wire-protocol.md` (Deadlines) after the tool checks, which have no timeout in Core; at most four Hub calls of 5,000 ms (the place of the live set, its `result`, the write of step 2, the write of step 3); and the prompt call of 5,000 ms. A kill before the write of step 2 sends nothing and leaves the row due at its `next_try_at`; a kill after it leaves `unconfirmed`. The Task holds no subscription and no buffer of the session: it holds the prompt of its row, at most 16,384 bytes. It can resume a session; the template flags a Task as a holder, and here Core holds the session and the store holds the state of the wake-up, so a dead Task loses nothing that a later try needs.

    Hub runs at most one delivery Task for each session and at most 4 in all; the others wait in the store, in order of their `next_try_at`. A restart of Hub needs no recovery step: a row is pending, with its `next_try_at`, or its run has an outcome.

13. **Access that changes.** Hub keeps the connections of each user, from the `hello` callback, with a monitor: at most 64, the connection cap of the transport. A revoke of a token closes the connections that proved it, a remove of a user closes its connections, and a record change that takes read access from a user (a change to `"private"`, a delete) closes the connections of every user but the owner that may no longer read it, each with `4403`. A revoke of the token of the connection that sends it closes that connection too: the close comes before the reply, so the client sees `4403` and no `res`. The client connects again; its next `subscribe` to that session gets `session_not_found`. Reason: the check runs before each `req` and `subscribe`, so an open subscription would go on streaming a session that its user may no longer read. A close covers it with no list of subscriptions in Hub; a change of access is rare.

14. **Caps for the coordinator** (#859). Hub keeps the **live set**: the session processes that a start or resume through Hub made or attached to, each with a monitor, and at the start of Hub every live session of its Core, read once with `Helyx.Sessions.list_live/1` in a Task (5,000 ms; past it the set starts empty). At most 64 entries, the Core cap. The live sessions of a user are the entries of the live set whose record, derived or stored, names that user as owner; Hub reads the owners of at most 64 ids in one query at the count, so a record change moves the count with it. A `start`, or a `resume` of a session that does not run (decision 5: the `check` looks it up), of a user at the cap answers `too_many_sessions`, as the Core cap does. A `resume` of a session that runs attaches and needs no place. The cap is the option `:max_live_sessions`, 1 to 64, default 64, the Core cap: under `helyx serve`, the single user keeps the bound of today. Hub counts a `start` or `resume` that `check` passed and whose `result` has not come as a reserved place, so two starts at the same moment cannot both pass the last place; Hub frees the place at `result`, which adds the session to the live set, at `release`, at the `:DOWN` of the process that called `check` (Hub monitors it), or 60,000 ms after `check`, whichever comes first. The last bound holds for a caller of `start_session/3` that lives on and never comes back: the wire deadline of a `start` is 30,000 ms, and a start through the Elixir API that is still open after 60,000 ms adds its session at its `result`, so the count can pass the cap by such slow starts (Accepted holes). The same rule bounds the records: a `start` of a user who is not the default owner reserves a record place too. A session that the agent tool, print mode, or a product starts without Hub after the start of Hub is not in the live set: the Core cap bounds it, and a child counts against no user. The other caps that #859 names are the records of a user (10,000) and the schedules of a session (16), in "Bounds".

15. **`helyx serve` starts Hub** (#869). The order in the serve process: Core, Hub with `core:`, `default_owner: "owner"`, and `server_token:` the closure of the server token, then the transport with `authority: Helyx.Hub.authority(hub)` in place of `token:`. The stop runs the other way: the transport, then Hub (decision 16), then Core. The server file, its token, and the connect of the TUI do not change (decision 3).

16. **The stop of Hub.** Hub kills its delivery Tasks (decision 12: a Task killed before its send leaves a pending row, one killed after the write of step 2 leaves `unconfirmed`), closes the store, and ends within 5,000 ms. Reason: the transport stopped first, so no request waits for Hub, and the store holds the state of every wake-up.

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
  cwd TEXT NOT NULL,                 -- the folder of the session, 1 to 4,096 bytes
  model TEXT NOT NULL,               -- the model ref of the start, at most 256 bytes (Helyx.ModelRef)
  prompt TEXT NOT NULL DEFAULT '',   -- the first user text that Hub authorized or sent, cut to 1,024 bytes
  active_at INTEGER NOT NULL,        -- the last start, resume, or user text that Hub authorized or sent
  visibility TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'hub')),
  archived INTEGER NOT NULL DEFAULT 0 CHECK (archived IN (0, 1)),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
) STRICT;
CREATE INDEX records_owner ON records (owner, updated_at);
CREATE INDEX records_visibility ON records (visibility, updated_at);
CREATE INDEX records_owner_active ON records (owner, cwd, active_at);
CREATE INDEX records_visibility_active ON records (visibility, cwd, active_at);

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
  run INTEGER NOT NULL DEFAULT 0,    -- the number of the pending run
  delivery_id TEXT,                  -- the origin id of the pending wake-up, 12 random characters, null when none
  due_at INTEGER,                    -- the due time of the pending wake-up, null when none; its life ends 3,600 s later
  next_try_at INTEGER,               -- when the next try of the pending wake-up may start, null when none
  last_at INTEGER,
  last_outcome TEXT CHECK (last_outcome IN ('delivered', 'missed', 'refused', 'unconfirmed')),
  created_at INTEGER NOT NULL
) STRICT;
CREATE INDEX schedules_at ON schedules (at);
CREATE INDEX schedules_next_try ON schedules (next_try_at);
CREATE INDEX schedules_session ON schedules (session_id);
```

The columns of a listing (decision 7): the `result` of a `start` writes `cwd` (the param), `model` (the param, or the default model of the Core, `Helyx.Core.config/2`), an empty `prompt`, and `active_at`; the first `hub.records.update` of a derived record writes them from the check of decision 8. The Hub call of the `check` of `resume`, `prompt`, `steer`, and `follow_up` of a session with a row, and the write of a delivered wake-up, set `active_at` to the time of the call, and set `prompt` when it is empty: the caller cuts the text to 1,024 bytes on a UTF-8 boundary before the Hub call, so no Hub call carries more of a text. A session with no row gets no write. So `mtime` and `prompt` of a stored record are the times and the text that Hub saw, not the file time and the head of the file that Core reads; a text that reached the session around Hub (a tool, print mode) does not move them.

A user removed takes its tokens, projects, records, labels, and schedules with it; its sessions go back to the default owner (decision 8).

### Transport

- `Helyx.Transport.WebSocket`: the option `:authority`, and `close/2` (decision 5). With an authority, `sessions.saved` goes to `run` with the deadline of 15,000 ms in place of the 10,000 ms of the Core call (decision 7), and takes the encoder slot as before. The protocol number goes to 5, and the schema of `wire-protocol.md` gets the lines below.
- `Helyx.Transport.WebSocket.Authority` (new): the behaviour of decision 5.
- New close codes: `4403`, the access of the user changed (decision 13), also a credential that no longer holds at a `check`, `run`, or `result`; `4503`, the authority gave no answer to the `hello`: its Hub call exited (5,000 ms, or a Hub that is down) or got `busy`.

### Wire schema additions (protocol 5)

#869 puts these lines in the schema of `wire-protocol.md`, with its SHA-256, but the lines and the alternatives marked `#870`: the three `hub.schedules.*` ops, the codes `too_many_schedules` and `unknown_schedule`, their params and results, and `schedule`. #870 adds them with protocol 6, by the rule of ADR 0008 §7.

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
# project: null for a user who does not own the record (the project is the owner's)
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
| `hub.records.get` | `session_not_found` | `project` of a record is null for a user who does not own the record (a project belongs to the owner of its records), here and in `hub.records.search`, so a shared record does not show the project id of its owner; a session with no row gives the derived record, `stored: false`, with null times, only after the check of decision 8 confirmed that the session exists; an id with no session gives `session_not_found`, as a private session of another user |
| `hub.records.update` | `session_not_found`, `forbidden`, `too_many_records`, `unknown_project`, `bad_params` | at least one field; `labels` replaces the set, duplicates removed; `project: null` clears it; the first update of a derived record writes the row |
| `hub.records.delete` | `session_not_found`, `forbidden` | the row goes; the session falls under decision 8; its schedules go at their next run (decision 11) |
| `hub.records.search` | `unknown_project`, `bad_params` | the stored records that the user may read (`mine: true`: only its own), newest `updated_at` first, then by session id; `query` matches the title as a substring, ASCII case folded; `labels` must all be on the record; `project` is a project of the user, else `unknown_project`; `limit` 1 to 256, default 50. The query filters by access before it pages, so `next` is `<updated_at>:<session id>` of the last record of the page, a readable one, null on the last page; `after` is that `next`, parsed and only compared. A derived record is not in a search: the default owner finds those sessions with `sessions.saved` |
| `hub.projects.*` | `too_many_projects`, `unknown_project`, `bad_params` | the projects of the user; a project id of another user gives `unknown_project`, as a missing one, here and in `hub.records.update`; a name taken by another project of the user is `bad_params`; a delete clears the project of its records |
| `hub.tokens.list` | | the tokens of the user, never a key or a text |
| `hub.tokens.revoke` | `unknown_token` | a token of the user; a token of another user gives `unknown_token`, as a missing one; its connections close with `4403` |
| `hub.schedules.create` | `session_not_found`, `forbidden`, `too_many_schedules`, `text_too_large`, `bad_params` | the user owns the session; `at` from now to now + 31,622,400 s (366 days), and a past `at` is `bad_params`; `prompt` of 1 to 16,384 bytes |
| `hub.schedules.list` | `session_not_found` | the schedules of the user, of one session or all |
| `hub.schedules.delete` | `unknown_schedule` | a schedule of the user; one of another user gives `unknown_schedule`, as a missing one; the row and its pending wake-up go, and its Task is killed; a prompt that the session already took or queued still runs; `pending` of a schedule is true while it has a pending wake-up |

## Replaced mechanism

The authorization of a connection, when the transport has an authority. A transport with no authority keeps all of it, and its tests keep their properties.

1. **The proof of one server token at `hello`, then every operation and subscription open** (ADR 0008 §6, `Connection.proof?/3` in `plugins/bundled/lib/helyx/transport/web_socket/connection.ex`). Replaced by the `hello` callback, which proves a user (decision 3), and the `check` before every `req` and `subscribe` (decision 5). The `challenge`, the nonce, the HMAC, the constant-time compare, the close `4401`, the auth wait of 5,000 ms, and the rule that no frame holds a secret stay. The server token moves from the transport to Hub, in a closure.
2. **`sessions.live`, `sessions.saved`, and `resume` `{cwd}` over every session of the Core.** Under a Hub they reach only what the user may read or owns (decision 7). A client of one user under `helyx serve` sees no change: the default owner owns every session with no record.
3. **The deadlines of the operations.** They stay; the calls of the authority add their own bound around them (decision 5).
4. **The protocol number** goes from 4 to 5. A client of protocol 4 gets `refused` with `4426`, by ADR 0008 §7. The TUI of the same build speaks 5.
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
| the `hello` callback | 5,000 ms, a Hub call | an exit or `busy`: close `4503` | transport |
| `check`, `result`, `run` | 5,000 ms each, a call to the Hub process; the `run` of `sessions.saved` 15,000 ms, its scan of 10,000 ms and its Hub call (decisions 5 and 7) | `timeout` | transport |
| the mailbox of the Hub process | the Hub calls: at most 2,628 by the admission bound of decision 5; the ends of at most 4 delivery Tasks; the poll timer and the expiry timers of at most 4,096 reserved places; the `:DOWN` of at most 64 connections, 64 live sessions, and the callers of the reserved places, at most 4,096 places, 64 users at a cap of 64, also through `start_session/3` | n/a | Hub |
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
| the ids of one `records/2` call | 256, the scan of `sessions.saved` for the default owner; `sessions.live` is at most 64 | n/a | Hub |
| the page of `sessions.saved` under a Hub | `limit`, 1 to 256: one Hub call that reads at most `limit` + 1 stored rows through the indexes on owner and visibility, 5,000 ms; for the default owner also the scan of Core, 256 heads of 64 KiB, 10,000 ms; the `run` 15,000 ms in all | `bad_params`; `timeout` | Hub, Core, the transport |
| the existence check before an operation on an id with no row (decision 8) | a Registry lookup for an operation that needs a running session; else the lookup, then one `Helyx.Session.File.Scan.find/2` in a Task: the listing of the folders of the data folder, whose count Core does not bound, with a deadline of 5,000 ms | the Task is killed; `session_not_found`, and no record is derived | the caller |
| `cwd` of a stored record | 1 to 4,096 bytes; Core puts no length bound on a `cwd` (`Helyx.Session.Input.cwd/1`), but a folder that exists has a path under the `PATH_MAX` of the OS, 4,096 bytes on Linux and 1,024 on macOS | the `check` of a `start` of a user who is not the default owner: `bad_params` | Hub |
| `model` of a stored record | 256 bytes, the bound of a model ref (`Helyx.ModelRef`) | n/a: Core refuses a longer ref | Core |
| `prompt` of a stored record | 1,024 bytes, cut on a UTF-8 boundary in the caller | cut | Hub |
| `resume` `{cwd}` under a Hub | one Hub call that reads one row; for the default owner also the 256 heads of the scan of `Helyx.Sessions.list_saved/2` (10,000 ms) | `not_found` when the user owns none in the folder | Hub, Core |
| live sessions of a user | `:max_live_sessions`, 1 to 64, default 64, with the reserved places of decision 14 | `too_many_sessions` | Hub |
| connections that Hub tracks | 64, the connection cap of the transport | n/a | the transport |
| schedules of a session | 16 | `too_many_schedules` | Hub (#870) |
| schedules of a user | 256 | `too_many_schedules` | Hub (#870) |
| pending wake-ups of a session | 16: one in each schedule row | n/a | Hub (#870) |
| pending wake-ups of a Hub | 16,384: 64 users of 256 schedules | n/a | Hub (#870) |
| schedule `prompt` | 1 to 16,384 bytes of UTF-8 | `text_too_large`; an empty one `bad_params` | Hub (#870) |
| schedule `at` | from now to now + 31,622,400 s (366 days) | `bad_params` | Hub (#870) |
| schedule `every` | null, or 300 to 2,678,400 s | `bad_params` | Hub (#870) |
| delivery Tasks | one per session, and at most 4 in all | the others wait in the store, by `next_try_at` | Hub (#870) |
| the poll of due wake-ups | each 1,000 ms, at most 64 rows each | the rest at the next poll | Hub (#870) |
| the wait of a wake-up when its session is stopped | the resume, within its bound of 30,000 ms (`wire-protocol.md`, Deadlines: the lock and the load of a file of at most 64 MiB), in the delivery Task, inside its 120,000 ms; a resume that fails with an error of decision 12, step 1, tries again after 30,000 ms, within the life of the wake-up | the wake-up waits; past its life, `missed` | Hub (#870), Core |
| the wait of a wake-up when a turn runs | a try each 30,000 ms (`next_try_at`), within its life | after 3,600 s from `due_at`: `missed` | Hub (#870) |
| the life of a wake-up | 3,600 s from `due_at`, a wait after a restart too | a pending wake-up past it: `missed`; a recurring schedule goes on | Hub (#870) |
| the prompt call of a delivery | the call timeout of `Helyx.Session.prompt/3`, 5,000 ms | an exit: the run stays `unconfirmed` (decision 12, step 3) | Core |
| a delivery Task | 120,000 ms from its start (decision 12); it holds one prompt of at most 16,384 bytes and no subscription | Hub kills it: before the write of step 2 the row comes due again at its `next_try_at`, the start plus 150,000 ms; after it the run stays `unconfirmed` | Hub (#870) |
| the admission bound of Hub calls | a caller sends only when the mailbox of Hub holds fewer than 1,024 messages (`message_queue_len`), so at most 1,024 plus one for each caller at that moment: 2,628 with the transport and the tools of #859; a product adds one for each process of its own that calls the Elixir API, and bounds them itself (Accepted holes); no stored count | `busy` at once; a `hello` closes with `4503` | the callers |
| a Hub call that Hub takes at or past its deadline | dropped before it reads or writes | n/a: its caller already answered `timeout` | Hub |
| webhook payload | 1,048,576 bytes; the prompt that a payload becomes stays under `Helyx.Session.max_text_bytes/0` | HTTP 413, no wake-up | the webhook endpoint, a later ticket (Out of scope) |
| the stop of Hub | 5,000 ms | the supervisor of the product kills it; each wake-up keeps its row (decision 16) | Hub |
| SQLite busy wait | 5,000 ms (`busy_timeout`) | the query fails: the operation answers `failed` | the store |
| the open of the store | 5,000 ms: `BEGIN EXCLUSIVE` on a file that another connection holds fails after the busy wait | `{:error, :store_locked}` | the store |
| the store file | no bound of its own: the row bounds above, at most about 2 KB a record with its labels and 17 KB a schedule, give about 1.6 GB at every cap | n/a | Hub |

Every numeric limit gets tests at the limit, one under, one over, and, for the byte bounds of a text, a multibyte character at the edge.

### Access tests (#869)

A refusal looks the same as a missing session, so the tests of #869 run each operation as two users, A and B, with private sessions of A, and check what B gets. Each test runs once with B a user who is not the default owner and once with B the default owner, but for the first item, whose equality holds for a user who is not the default owner (decision 7; for the default owner, Accepted holes):

- `sessions.saved` with every `limit` from 1 to 256, following `next` to the end, with and without `cwd`: no item and no cursor holds the id or the `mtime` of a private session of A, and the pages of B are equal to the pages of B on a server without A's sessions. The same with 256 sessions of B and one newer private session of A, with A's sessions among the newest files of the data folder and of B's folder, and with more than 256 sessions of A newer than every session of B: B still sees each of its sessions. And for the default owner: no item and no cursor of a private session of A.
- `resume` `{cwd}` of a folder where A has newer sessions than B: B resumes its own newest session of the folder.
- `sessions.live`: no line of it.
- `hub.records.search`, following `next`: no record and no cursor of it, also with `mine: false` and with a `project` id of A.
- `subscribe`, `history`, `hub.records.get`, `hub.records.update`, `hub.records.delete`, `hub.schedules.create`, and the write operations of decision 7: `session_not_found`, the same answer, code and text, as for a valid session id with no session and no file, also when B is the default owner (decision 8: the existence check before every operation on an id with no row); a check that passes its deadline answers the same;
- For B the default owner, every operation of the session namespace (`subscribe`, `history`, `prompt`, `steer`, `follow_up`, `abort`, `set_model`, `compact`, `answer`, `stop`, `resume` `{id}`) on a missing id and on a private session of A, running and stopped, with valid params and with params that Core checks before its lookup: an invalid model ref for `set_model`, an empty product origin id and one over 256 bytes for `prompt`, `steer`, and `follow_up`, a text over `Helyx.Session.max_text_bytes/0`, and an invalid answer: the same error, code and text, for the two ids in each case; `resume` `{id}`: `not_found`, as for one that does not exist; `resume` `{cwd}` of A's folder: B resumes none of A's sessions.
- A project, a token, and a schedule of A, named by B: `unknown_project`, `unknown_token`, `unknown_schedule`, as for missing ones.
- `forbidden` comes only for a session that B may read (`"hub"`).
- A scheduled prompt of A in a `"hub"` session of A, read by B through `subscribe` (its events) and `history`: its origin id holds no schedule id of A and no run count, and two runs of one schedule have unrelated ids.
- The same request with bad params, for an object of A and for a missing one: the same `bad_params`.
- A stored record of B whose session file was deleted: `resume` `{id}` gets `not_found` and deletes the row; then `hub.records.get` of the id gets `session_not_found` for B and for the default owner.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
|---|---|---|---|---|---|
| the Hub process | the supervisor of the product | the supervisor of the product | the stop of Hub (decision 16) | the supervisor of the product starts it again; the store reopens | n/a |
| the SQLite connection and its file lock | `open/1` of the store in the Hub process | the Hub process | `close/1` at the stop | the NIF resource is freed with the process heap, and the lock with the connection; the OS frees the lock when the VM ends | n/a |
| the store file `hub.db` and its WAL files | the store, mode 0600 | the disk | stay | stay; SQLite recovers the WAL at the next open | n/a |
| a delivery Task | the Hub process, under the task supervisor of Hub, linked to the Hub process | the task supervisor | it ends after its last write | its row stays as the last write left it: pending, due again at its `next_try_at`, or with an outcome; a session that it resumed keeps running | Hub kills it at 120,000 ms, and the stop of Hub kills it; the same |
| an entry of the live set (decision 14) | `result` of a start or resume, and the read of `list_live/1` at the start of Hub | the Hub process, with a monitor of the session process | the `:DOWN` of the session | gone with Hub; the next start of Hub reads `list_live/1` again | n/a |
| the Task of an existence check (decision 8) | the caller, linked | the caller | it ends with its answer | it dies with the caller by the link | the caller kills it at 5,000 ms |
| a session that a wake-up resumed | `Helyx.Sessions.resume/2` in a delivery Task | Core | runs until a client stops it or the server stops (`serve.md`, decision 11) | n/a: Core holds it | n/a |
| a reserved place of a start (decision 14) | `check` of a `start` or `resume` | the Hub process, with a monitor of the caller and a timer of 60,000 ms | `result` or `release` | the `:DOWN` of the caller or the timer frees it; a crash of Hub frees every place with its state | n/a |
| the monitor of a connection (decision 13) | the `hello` callback | the Hub process | the `:DOWN` of the connection | gone with Hub; the connections keep running, and a change of access after the restart of Hub does not close a connection that proved itself before it (Accepted holes) | n/a |

## Accepted holes

- **Hub crash between a start and its record.** A `start` of a user who is not the default owner, whose `result` call times out or meets a crash of Hub, leaves a session with no row: the default owner owns it (decision 8), and the user gets `timeout` or `failed`. The default owner is the operator, who can read the file anyway.
- **A run that ends `unconfirmed` is not sent again, and its outcome can be wrong either way.** Once the write of step 2 applied, the run keeps `unconfirmed` unless a later write of the Task changes it, and Hub never sends it again; the user sends it by hand (decision of the owner of 2026-11-06). The causes: Hub crashed or stopped, or the Task was killed, between that write and the last write of the Task; the prompt call exited on its timeout or answered `session_not_found`; the write of step 2 applied but its reply came after its 5,000 ms, so the Task sent nothing; the write of `delivered` after `:ok` failed, so a prompt that the session took shows `unconfirmed`; the write-back after `turn_running` or `queue_full` failed, so a prompt that the session did not take shows `unconfirmed`. In each case the session got the prompt at most once.
- **Slow starts through the Elixir API.** A reserved place ends 60,000 ms after its `check`; a start of `start_session/3` that takes longer adds its session at its `result`, so the user can pass the cap by such starts. The Core cap still holds.
- **A resume that races a stop.** A `resume` whose `check` found the session running needs no place of the cap (decision 14); when the session stops before the resume, the resume starts a new instance with no place, and the user can pass the cap by the resumes in that window. The Core cap still holds.
- **Wake-ups fill the Core.** A session that a wake-up resumed stays running (decision 12). Within the cap of each user, the sessions of many schedules can hold the 64 places of the Core, and a start then gets `too_many_sessions` until a client stops one.
- **A Task killed in its resume.** A delivery Task that Hub kills while `Helyx.Sessions.resume/2` runs can leave a session that starts after the kill and is not in the live set of decision 14, so the owner can pass the cap by it until the next start of Hub reads `list_live/1` again. The Core cap still holds.
- **A wake-up that the session queued and then dropped shows `delivered`.** During a wait of the session, `prompt/3` queues the text as a follow-up and answers `:ok`; an abort or a failure of the turn before it gives it back to the clients in a `queue_dropped` event, and Hub does not send it again. The clients show the dropped text, as for any follow-up.
- **Daylight saving.** A period is in seconds of UTC, so a daily schedule moves by one hour in a zone with daylight saving. A rule of a calendar with a zone needs a time zone database that the BEAM does not bundle.
- **Children of another user.** On a Hub of several users, a child of the agent tool belongs to the default owner (decision 8, Consequences).
- **Monitors after a Hub restart.** Hub rebuilds no connection list after a crash: a connection that proved itself before keeps its open subscriptions after a later revoke or change of access until it closes. Its next `req` or `subscribe` meets the `check`: a revoked token or a removed user closes the connection with `4403`, and a session that it may no longer read answers `session_not_found`. Reason: the transport gives the authority each connection at its `hello` only and has no list of connections by user that Hub could read after a restart.
- **A product bounds its own callers of the Elixir API** (decision of the owner of 2026-11-06 on #868). The admission bound of decision 5 is 2,628 calls for the transport and the tools of #859; each process of the product that calls the Elixir API at the same moment can add one call past it. The Elixir API is called by trusted code in the VM of the product, as every other Core API is. The wire keeps its numbers, and Hub stores no count of callers.
- **The cap of Core is shared.** A `start` at the 64 live sessions of the Core gets `too_many_sessions` whoever holds them, so a user learns that the server is full, not which sessions run or whose. The cap of each user (decision 14) is the user's own.
- **The default owner's sessions with no record come from the scan of Core** (decision of the owner of 2026-11-06 on #868: only the derived records of the default owner come from the scan). The scan covers the 256 newest files of every user, so newer sessions of other users can push an old session with no record of the default owner out of its `sessions.saved` and its `resume` `{cwd}`; the default owner reaches it by its id, as before Hub. The default owner is the operator, who reads the data folder.
- **The existence check has a deadline, not a size bound.** `Helyx.Session.File.Scan.find/2` lists every project folder of the data folder, whose count Core does not bound; the check stops at 5,000 ms and then answers `session_not_found`, so on a data folder too large to list in that time the default owner gets `session_not_found` for a derived record of a session that exists. Its memory is the names that the listing read before the deadline. One stat cannot replace it: an id with no row has no stored `cwd`, and the path of its file depends on the `cwd`.
- **A stored record outlives its deleted file until a resume.** The listings stat no file, so a record whose file was deleted stays in `sessions.saved` and `hub.records.search` until a `resume` `{id}` or a wake-up gets `not_found` from Core and Hub deletes the row.
- **No folder isolation between users.** Every user of a Hub runs tools as the OS user of the server, in any folder that `start` admits (decision 1).

## Out of scope

- Executor assignment: after the ADR of remote hands (#856), ADR 0010, Consequences, item 4.
- Event subscriptions with their webhook endpoint, push notifications, routing across nodes, and OIDC: later tickets when a deployment needs them (ADR 0010, Consequences, item 5). The webhook payload bound above holds for that endpoint.
- Users made or removed over the wire, and a command of `helyx` that does it: a product ticket when a second user is needed.
- A migration of the store schema: the first build refuses another `user_version`.
- Several humans in one session, billing, and a web client (ADR 0010).
- A calendar rule with time zones for schedules (Accepted holes).
