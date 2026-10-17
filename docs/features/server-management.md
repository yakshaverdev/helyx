# Server management

## Goal

A public API to manage the sessions of one Core, so that a transport (#660) uses only public functions (ADR 0008 §1). Before this, a client listed the saved sessions with `Helyx.Session.File.Scan.list/2`, had no list of the running sessions, and a second resume of a running session in the same Core failed with `{:session_locked, id}`. Ticket #657.

User stories:

- A user opens the coding agent on the phone and sees the sessions that run now and the saved ones, and picks one.
- Two clients resume the same saved session at the same time. Both attach to one instance; the user never gets two writers or a lock error from their own server.
- A user stops a session that runs. Every client of it gets the end signal with `:stopped`, the session frees its place in the cap, and it can be resumed from its file.

Decisions:

- **One module, `Helyx.Sessions`.** The server-management API is a Core module next to `Helyx.Session`: it acts on the sessions of a Core, not on one session. `session.ex` is at the file limit, so `stop/1` goes here too (the ticket comment allows "the server-management equivalent"). Core names no wire construct: the functions return Core terms, and the transport builds the frames and the error codes of `docs/features/wire-protocol.md`.
- **The server configuration is the Core start options.** `Helyx.Core` takes `:plugins` already. It takes two more: `:sessions_dir`, the storage root, and `:model`, the default model ref. `Helyx.Sessions` reads them; `Helyx.Session` does not, so every caller of `Helyx.Session.start/2` keeps its behaviour. A Core with no `:sessions_dir` saves nothing and has no saved session. A "product profile" has no Helyx construct today: a product names its plugins and these options.
- **The rules hold for every caller.** The cap and the attach are in the start of the session process (`Helyx.Session.Server.Open.start/4`), so `Helyx.Session.start/2` and `resume/2` get them too, and the TUI in the node cannot pass them.
- **The cap counts sessions only.** A memory sync worker, also one that still drains after its session stopped, takes no place: it runs under a second `DynamicSupervisor` of Core, the sync supervisor, with no cap (`docs/features/memory.md`, Bounds; #707).
- **The cap is the session supervisor.** `max_children: 64` on the `DynamicSupervisor` of Core. The supervisor counts its children one request at a time, so concurrent starts cannot pass the cap. A session counts from its start request to its exit: in its open and in its stop too. Accepted hole: a kill of the supervisor starts a new one with no children while the old sessions close, so for at most their stop deadline more than 64 run. Nothing in Helyx kills that supervisor.
- **Attach.** The Registry rejects a second process of a running id before its `init/1`. The resume then waits for that process with a call, which the process takes after its open: a session that opened gives the attach, and one whose open failed exits with `{:shutdown, {:open_failed, reason}}`, so every waiter gets the `reason` that the first caller got. A kill at the deadline of the open gives `:open_timeout`, as to the first caller; so does a kill of a session that opened, during an attach call: only a Core stop past `Stop.shutdown_ms/0` kills one, and then no resume can run. Any other end of that process (its caller ended during the open, a stop, a crash) is not a result of the resume: the resume runs once more from the start, and that second result is the result. A resume at the cap whose id runs attaches too. When a second run also meets such an end, the result is `{:error, :session_not_found}`. Open, ticket #694: the supervisor can answer `{:already_started, pid}` and the process can exit before the attach call monitors it; the exit reason is then gone, and the resume runs its own open. For a cause that persists (the lock of another OS process, an unknown model, a bad file) that open gives the same error; for a cause that passed (a slow disk) it can open while the first caller got the error. No second writer results.
- **The live list asks each session.** The model and the status change while a session runs, and only the session process knows them, so `list_live/1` calls each running session, all in parallel, under one deadline of 5,000 ms (the call timeout of `Helyx.Session`). A session that does not answer in time, one in its open or its stop, is left out: no client can use it yet or any more.
- **The saved list pages by a key.** Each page scans again, so a file that changes between two pages moves no item of a later page. The cursor is the key of the last item, its modification time and id; the next page holds the items older than it in the order of the list. A plain offset would skip or repeat an item when a new session is saved between two pages.
- **Stop.** `stop/1` aborts as `Helyx.Session.abort/1` does, waits for its cleanup, then stops the session process with the reason `:normal`, so each subscriber gets its end signal and `Helyx.Session.end_reason/1` gives `:stopped`. The stop of the process releases the lock in its `terminate/2` (`docs/features/session-lock.md`). It goes to the session process, not through the supervisor, so a stop does not hold up the starts of other sessions.

## Interface changes

- `Helyx.Core.start_link/1` and `child_spec/1` take `:sessions_dir` (a path, default none) and `:model` (a model ref string, default none). A path that is not an absolute path of valid UTF-8 with no NUL byte (a relative folder would move with the working directory of the node), or a model that does not parse as a model ref, refuses the start with `{:invalid_option, key}`. Whether the provider of the model is registered is checked at each start, as for any model.
- `Helyx.Sessions` (new, Core):
  - `list_live(core)` returns `[%Helyx.Sessions.Live{id, instance_id, cwd, model, status}]`, at most 64. `model` is the current model ref as a string. `status` is `:idle` when the session has no turn and no wait, else `:running`. A Core that is not running gives `[]`. No order.
  - `list_saved(core, opts)` returns `{:ok, [%Helyx.Session.File.Scan.Summary{}], next}`, newest first. `:cwd` is a folder; without it, every folder. `:limit` is from 1 to 256, default 50. `:after` is the `next` of the page before. `next` is a string, or nil on the last page. Errors: `:invalid_cwd`, `:invalid_limit`, `:invalid_cursor`. The rules of the list are those of `Scan.list/2` (`docs/features/session-list.md`): an empty session is left out, and the model is the model of the header.
  - `start(core, opts)` is `Helyx.Session.start/2` with the `:sessions_dir` of the Core and, when `:model` is not given, the default model of the Core. With neither, the error is `{:invalid_model_ref, ""}`.
  - `resume(core, opts)` is `Helyx.Session.resume/2` with the `:sessions_dir` of the Core. With `:id` and no `:cwd`, the folder is the one that the header of the session names; `Helyx.Session.resume/2` has the same rule since #758. With `:cwd` and no `:id`, the newest session of that folder. A Core with no `:sessions_dir` gives `{:error, :not_found}`. The errors of the find are those of `Scan.find/2`: `:invalid_id`, `:not_found`, `:duplicate_id`, `{:invalid_file, text}`. A header folder that `Helyx.Session.Input.cwd/1` rejects gives `:invalid_cwd`.
  - `stop(session)` returns `:ok` after the session ended, or `{:error, :session_not_found}` when it is not running. A session, or its Core, that ends between the abort and the stop gives `{:error, :session_not_found}` too: `stop/1` looks up the pid after the abort and stops that pid. A session that ends for another reason during the stop, such as a Core stop, gives `:ok`: it ended.
- `Helyx.Session.start/2` and `resume/2` give `{:error, :session_not_found}` when an attach meets the end of the process twice (Decisions, "Attach").
- `Helyx.Session.start/2` and `resume/2`: a new error `:too_many_sessions` at the cap. `resume/2` of a session that runs in the same Core returns `{:ok, session}`, the running instance, in place of `{:error, {:session_locked, id}}`. A session that another Core or another OS process holds still gives `{:session_locked, id}`.
- The session process takes one new call, `:live`, which answers its `%Helyx.Sessions.Live{}`. The attach uses it too.

### Order of the checks

A start and a resume run their checks in one order, and the first failure is the result. Nothing touches the sessions directory before step 3 (#758).

1. The given `:cwd` (`Helyx.Session.Input.cwd/1`): `:invalid_cwd`.
2. The tools: the specs (`Helyx.Tool.specs/1`), each `check/0` (`Helyx.Tool.check_available/1`), and the `concurrent?/0` values (`Helyx.Tool.concurrent/1`).
3. A start resolves the model ref, then makes the folders (`Helyx.Session.File.mkdir/2`). A resume picks the file (`Helyx.Session.File.pick/3`): the find of the id, or the scan for the newest session. With `:id` and no `:cwd`, the folder of the header is checked here, as step 1 checks a given one.
4. The start of the session process (`Helyx.Session.Server.Open.start/4`): the cap; for a resume of an id that runs, the attach (Decisions, "Attach"). Then, in the open of the process, the lock, and for a start the create of the file, for a resume the load and its model ref.

The coding agent keeps this order for `--session <id>` (#765). The CLI makes no check of the id or the sessions directory of its own: it starts Core and resumes the id with no `:cwd`, so a failed tool check gives the line of a failed start, as a start does. Its own rule for the folder of the header, an absolute path to a directory, comes after step 4 (`session-list.md`, "Folder").

The errors that the transport maps to the codes of `start` and `resume` (`wire-protocol.md`, Operations): `:invalid_cwd`; `:not_found` and `:invalid_id`; `{:invalid_model_ref, ref}`; `{:unknown_provider, id}`; `:too_many_sessions`; any other term is `start_failed`.

## Replaced mechanism

1. **A second resume in the same Core.** `Server.start/3` gave `{:already_started, pid}` the shape of a held lock, `{:session_locked, id}` (`docs/features/session-lock.md`, Interface changes). It now attaches. The two writers that the lock prevents stay prevented: the second resume starts no process, takes no lock, and reads no file past the header of the pick.
2. **The stop of a session whose open failed.** It stopped with `:normal` after it sent the error to its caller. It now stops with `{:shutdown, {:open_failed, reason}}`, so an attach that waits gets the same error. The first caller still gets the error by its message, before the exit. No subscriber exists before the open, so no client sees the reason. A session whose caller ended stops with `:normal` as before.
3. Tests: "a session that another Core or the same Core holds does not open, and its file is unchanged" (`test/helyx/session/lock_test.exs`) becomes "a session that another Core holds does not open, the same Core attaches, and its file is unchanged": the property holds for another Core; for the same Core the resume attaches to the same process, and the file is still unchanged. "keeps no copy after a start and after a failed start" (`test/helyx/session/persistence_test.exs`) becomes "keeps no copy after a start and after a start that the Registry rejects": the second resume is still rejected in the supervisor before the `init/1`, and then attaches. "a failed resume shows the error and stays on the current session" (`plugins/bundled/test/helyx/tui/switch_test.exs`) keeps its name: a second Core now holds the lock, because a resume in the same Core attaches.
4. Clients see: a resume of a session that already runs in this Core gives the running session.
5. No state without a bound: see Bounds.
6. **The find of `--session` in the coding agent (#765).** `CodingAgent.CLI` found the id with `Scan.find/2` and checked the folder of the header before it started Core, so with no perl on `PATH` it printed `no session "<id>"` where a start printed the tool error. It now starts Core and resumes the id with no `:cwd`; `CodingAgent.run/1` reads the folder from `Helyx.Sessions.list_live/1` after the open and checks it there. Clients see: the tool error first; a header folder with a NUL byte gives the line of a failed start in place of `not a directory`. Test: "--session checks the id and the folder of its header" (`apps/coding_agent/test/coding_agent/cli_test.exs`) now uses a folder with a tab for the clean pass and has a NUL case; "--session with no perl on PATH prints the tool error of a start" is new.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| live sessions per Core | 64, from the start request to the exit of the process; a sync worker does not count | `{:error, :too_many_sessions}`; a resume of an id that runs attaches | the session supervisor, `max_children` |
| live list | 64 items, through the cap | n/a | the cap |
| wait of the live list | 5,000 ms for all sessions together: one call to each, in parallel, each with the call timeout | a session that does not answer in time is left out | `Helyx.Sessions.list_live/1` |
| saved page | `:limit` 1 to 256, default 50 | `{:error, :invalid_limit}` | `Helyx.Sessions.list_saved/2` |
| saved list over all pages | the 256 files of the scan bound (`Scan.list/2`) | older files are not listed | `Scan` |
| cursor | an integer, `:`, and a session id | `{:error, :invalid_cursor}` | `Helyx.Sessions.list_saved/2` |
| wait of an attach | no timeout of its own: the open of the running process ends at its deadline (`deadline_ms.open`, 25,000 ms, then a kill), and a stop ends when the waits of `Stop.run/1` end, each with its bound | a kill: `:open_timeout` | the kill of the open (`Server.Open.open_file/2`), `Stop.run/1` |
| runs of a resume | 2: the second run gives its result when the first one met an end of another process | n/a | `Helyx.Session.Server.Open.start/4` |
| wait of a stop | the wait of `abort/1` (no timeout, as `abort/1`), then the `terminate/2` of the session. `GenServer.stop/3` waits with no timeout and no supervisor kill backs it, so the bound is the waits of `Stop.run/1`: the armed close of a provider process, the stop of the hands with its kill, and the lock release, together under `Stop.shutdown_ms/0`, 31,000 ms. The wire deadline of `stop` was 47,000 ms, the abort deadline and the lock release only; it is 77,000 ms, the abort deadline and `Stop.shutdown_ms/0` (`wire-protocol.md`, Deadlines) | the wire answers `timeout` | `Stop.run/1` |

## Ownership

No new external resource. The calls of `list_live/1` run in Tasks under the task supervisor of Core, linked to the caller; a Task holds no resource, and a late answer goes to a Task that ended.

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| writer lock of an attached session | the first resume | the one session process | its `terminate/2` | the port closes with the process | n/a |
| the result of an open that failed, for an attach that reaches the process after its exit | the open | nobody: it goes with the process | n/a | n/a | open, ticket #694 |

## Out of scope

- The wire, the error codes, and the deadlines of the operations: #660.
- Authentication: #660.
- A list of the live sessions with no call to each session.
- A prompt that comes between the abort and the stop of `stop/1` starts a turn, and the stop ends it as a Core stop ends a turn: in `terminate/2`, which releases every resource of the turn (`Stop.run/1`), with no aborted results in the file; a resume gives its open calls interrupted results (`docs/features/interrupted-calls.md`). No resource is open in it, so it is a state of the session, not a race of ownership.
