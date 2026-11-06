# Review: #869, slice 1 (Hub store and the operator API)

Ticket #869, `docs/features/hub.md`. Slice 1 only: `Helyx.Hub.Store`, `Helyx.Hub.Store.SQLite` (decision 9, "Store schema"), and the `Helyx.Hub` process with its options and the operator API for users and tokens (decisions 1, 2), with the admission bound and the deadline drop of the Hub call (decision 5). The authority of the transport, the `hub.*` operations, records, projects, the live set, the monitors, protocol 4, the wiring of `helyx serve`, and the access tests are open (see "Open").

Base: `9c25ff2a`. The ticket has no triage comment; the feature doc holds the decisions of the owner.

## Round 1 (full)

Bounds sensor: `5 candidate functions, 0 flagged, 0 without an answer`.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Codex (high) | The store file was made with the umask mode, then set to 0600: another user could open it in that window | Fixed: the file is made in a private 0700 folder, set to 0600, then put in place |
| 2 | Failure path | A symlink as `:path` passed the folder check; the store was in a folder that others can write | Fixed: `lstat`, a regular file or nothing |
| 3 | Failure path | `chmod` ran through a link, a folder, or a FIFO at `:path`, also when the start failed | Fixed with 2 |
| 4 | Failure path | A dangling link gave `:enoent` as an exit of the caller | Fixed: `{:invalid_option, :path}`; `init/1` returns `{:error, reason}` |
| 5 | Spec | `:name`, `:store`, and `:core` (with a `:path`) were not checked | Fixed |
| 6 | Spec | Tokens were not listed oldest first within one second | Fixed: `ORDER BY created_at, rowid`, test |
| 7 | Spec | No test one under the admission bound, of the WAL journal, of the order of users | Tests added |
| 8 | Spec | The moduledoc said a caller that timed out gets no late change of state; Hub only drops a call that it takes late | Moduledoc narrowed. The feature doc says the same of decision 5; a call that Hub takes before its deadline and that ends after it can still write. Not changed here: a doc change for the owner |
| 9 | Standards | A stray comment; tests on `/tmp/x.db`; a port read that needed one message | Fixed |
| 10 | Standards | The ids of `remove_user/2`, `create_token/3`, `revoke_token/2` crash on a non-binary | Kept: the operator API is called by trusted product code; a non-binary is a bug of the caller |
| 11 | Standards | `:server_token`, `:max_live_sessions`, `:core` are stored but unused in this slice | Kept: they are options of the doc, used by the next slices |
| 12 | Standards | No devlog | The review record and the report stand for this slice |

## Round 2 (reduced: spec, failure path)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Failure path, reproduced | Two starts on one new path: the second replaced the file that the first held (rename), and both started | Fixed: `File.ln`, which refuses a name that exists; `:eexist` gives `:store_locked` |
| 2 | Spec, reproduced | An existing `-wal` of mode 0644 stayed 0644 | Fixed: the WAL, SHM, and journal files are checked and set to 0600 |
| 3 | Spec, reproduced | A hard link as `:path` was accepted and its other name set to 0600 | Fixed: `links: 1` |
| 4 | Spec, reproduced | `store: File` and `name: {:via, :nope, :x}` passed the option check | Fixed: the behaviour attribute; `register_name/2` |
| 5 | Spec | No test of the timeout of 5,000 ms and of `:failed` | Tests added (the timeout test is `:slow`) |
| 6 | Failure path | A kill between `mkdir` and the cleanup leaves a private folder (empty, or with a 0600 file) | Accepted hole |
| 7 | Spec | An unknown option key is ignored | Kept: the doc names no rule; `GenServer` options behave the same |

Round 2 found defects in the mechanism that round 1 patched (the preparation of the store file), so round 3 is a full round on the mechanism.

## Round 3 (full: simplify, sensor, Codex, spec, failure path)

Bounds sensor: `7 candidate functions, 0 flagged, 0 without an answer`.

Every reproduction of rounds 1 and 2 now holds (spec and failure path re-ran each one: links, a hard link, a folder, the WAL and SHM files, and two starts with the second held after its `lstat`, which now gives `:store_locked` with the inode kept).

| # | Source | Finding | State |
|---|---|---|---|
| 1 | Failure path, reproduced | A refused start still changes the disk: the main file is set to 0600 before a bad sidecar refuses the start, and a new file is linked into place before the sidecars are checked, so an empty 0600 file stays | **Open.** Only tightens a mode or leaves an empty private file; the fix is to check all four names before any `chmod` or create |
| 2 | Codex (high), read in the code | The private folder has the umask mode between `File.mkdir` and `File.chmod`: with umask 000, or 002 with a shared group, another user can put a `hub.db` link in it, and `touch` and `chmod` follow it | **Open.** Needs an atomic 0700 folder (`mkdtemp`), which `File` does not give, or a check with `lstat` after the `touch` |
| 3 | Codex (high) | `safe_folder/1` checks only the parent folder; a parent below a folder that others can write can be swapped | **Rejected for this slice:** the doc fixes the check of `helyx serve` (`mode &&& 0o022`, decision 9). A wider rule is for the owner |
| 4 | Spec | Between `File.ln` and the cleanup the new file has two names; a start that reads it then gets `{:invalid_option, :path}`, not `:store_locked` | Open, judgement (not seen in 200 rounds) |
| 5 | Spec | No test of two starts at once on a new path | Open: the probe of both agents covers it |
| 6 | Spec | `:path` of the store is not checked absolute: `:memory:` or a `file:` URI opens a database that the file checks did not see | Open, wording: Hub passes `Path.expand/1`, so no Hub path reaches it |
| 7 | Spec | `name: {:global, _}` is accepted; the admission check (`Process.info/2`) raises for a pid on another node | Open, judgement |

Round 3 reproduced a defect on the mechanism that rounds 1 and 2 patched, so the small-fix round does not apply (`/ship`). The code is committed as reviewed in round 3, with findings 1 and 2 open.

## Round 4 (reduced: spec, failure path)

The first precommit failed on Credo (`Refactoring.Nesting` in `add_user/3` and `add_token/3`). The `cond` of each moved into clause helpers (`insert_user/4`, `add_token/4`). Invariant briefed: the same answers in the same order, in one transaction, an error rolls back. Spec: equivalent, no defect. Failure path: the caps at 63, 64, 65 users and 15, 16, 17 tokens, unknown users, and a call after each refusal, all held; no defect. No reproduced defect ends the loop.

## Open

- The findings 1, 2, 4, 5, 6, and 7 of round 3. A question for the owner first (`/ship`, two findings on one mechanism): does the mechanism need to exist? A store folder of mode 0700 (no group or other access) would make the file mode and the create window irrelevant to other users, but decision 9 states a folder check of `0o022` and a file of 0600.
- The rest of #869: the authority behaviour and the `:authority` option of the transport, `hello`/`check`/`run`/`result`/`release`, the `hub.*` operations, records and projects, `sessions.saved` and `resume` `{cwd}` under a Hub, the live set and its caps, the connection monitors and `close/2`, protocol 4 and the schema of `wire-protocol.md`, the wiring of `helyx serve`, and the access tests with the mechanical check of a refused id against a missing id.

# Cycle 2: the owner's decisions A and B

The owner's judgement of slice 1 (2026-11-06, in the session): (A) the private folder of the create is the protection, not the file mode: chmod it to 0700, then check it is the server's, 0700, and empty; a refused start changes nothing on the disk; the lock comes before the classification, so a second start gets `:store_locked`; `{:global, _}` is refused. (B) decision 5 stays: the store checks the deadline before the commit and rolls back past it; the caller waits the deadline and a margin; one hole, a commit longer than the margin.

Scope: the fix passes 100 code lines (the new module `Helyx.Hub.Store.SQLite.Disk`, 140 lines, and the deadline argument of each write callback of the store, an arity change of `add_user`, `remove_user`, `add_token`, `revoke_token`). The deadline of a Hub call is 4,000 ms after the send and the caller waits 5,000 ms, so every sum of decision 5 keeps its numbers.

The ownership of the private folder is shown by the `chmod`: only the owner of a folder (or root) can change its mode. No uid compare: the BEAM gives no `getuid`.

## Round A1 (reduced, with Codex: the change edits the feature doc)

Bounds sensor: `10 candidate functions, 1 flagged`: `hub.ex default_owner` (SIZE): it reads the users, at most 64 rows; not a finding.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec and failure path, reproduced | A file of another `user_version` was set to 0600 and switched to WAL before the version check refused it | Fixed: the version is read under the lock before any change |
| 2 | Codex (high), read in the code | The `COMMIT` of the lock wrote the first page of an empty file with a second name before the link check refused it | Fixed: the lock is `BEGIN EXCLUSIVE` and `ROLLBACK`, with no write; the lock tests in this node and in another OS process pass |
| 3 | Failure path, reproduced | A start held more than 100 ms between its link and the removal of its folder made the other start answer `{:invalid_option, :path}` | Changed in round A2 (cleanup by the lock holder) |
| 4 | Spec | `{:via, :global, _}` was accepted | Fixed |
| 5 | Spec | Decision 9 does not describe the private folder or the order of the checks | Kept: the owner keeps decision 9 as written; the rules are in the moduledoc of `Helyx.Hub.Store.SQLite` and the comment of `Disk` |

## Round A2 (reduced, with Codex)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Failure path and Codex, reproduced | A version-0 database of another program was set to 0600 and switched to WAL before its schema failed | Fixed: version 0 with any schema object is refused as `{:store_version, 0}` before any change; test |
| 2 | Spec, failure path, Codex, reproduced | SQLite replays the crash log (a WAL with frames, a hot journal) of a file that the version check then refuses, and checkpoints at the close | Accepted hole in `hub.md`: SQLite recovery on open, as any SQLite program does; refusing such a file would also refuse the crash recovery of this Hub's own store |
| 3 | Failure path, reproduced | A start refused by the default owner step (a store of 64 users) leaves the store at 0600 and in WAL | Accepted hole in `hub.md`: the file is this Hub's own store |
| 4 | Failure path, reproduced | A start killed after its link left a second name, and every later start got `:store_locked` | Fixed: under the lock, the holder removes a `.hub-*` folder whose `hub.db` is the store file |

Round A2 found a second defect on the mechanism, so round A3 is the last of the cycle.

## Round A3 (reduced, with Codex)

Bounds sensor: `11 candidate functions, 2 flagged`: `hub.ex default_owner` (as above) and `disk.ex left_create` (SIZE): it lists the folder of the store once, only when a second name stays; the data folder has no bound of its count (as the existence check of decision 8).

Every reproduction of rounds A1 and A2 passes; 40 rounds of 4 starts with one killed gave at most one start each.

| # | Source | Finding | State |
|---|---|---|---|
| 1 | Failure path and Codex (high), reproduced | `left_create/2` removes a whole `.hub-*` folder whose `hub.db` is the store file, with other files in it; with a third name elsewhere it then refuses after the removal | **Open.** Fix: remove only a folder of mode 0700 that holds only `hub.db`, with `File.rm` and `File.rmdir`, and refuse any other layout before a removal |
| 2 | Failure path and Codex, reproduced | A `.hub-*` folder that the server cannot empty (mode 0500) makes `left_create/2` and `one_name/2` call each other with no end while the start holds the lock | **Open.** Fix: one cleanup pass, then one link check; a failed removal refuses |
| 3 | Spec | A kill between the `touch` and the link leaves a private folder with a file of one name, which stays | Open, wording of the hole |
| 4 | Spec | The `deadline` typedoc says "ends at or past it"; the code checks when the write reaches its commit | Open, wording |
| 5 | Spec | No test of the check of the private folder (0700, empty) | Open: the window is a race of another OS user |

Both open defects need a folder named `.hub-*` in the folder of the store that the server's OS user made by hand: the folder of the store refuses group and other write, so no other user can make one. Round A3 is the last round of the cycle and the fix does not meet the small-fix rule (a second finding on the mechanism, more than 10 lines), so the cycle commits the reviewed code with them open.

# Fix after cycle 2: the lock at the open

The precommit of slice C1, on the Linux host, failed the slow test of cycle 2 "starts at once on a new path": all four starts got `:store_locked`. Cause: the lock was `locking_mode = EXCLUSIVE` and `BEGIN EXCLUSIVE` under the busy wait of 5,000 ms in one connection, and in the exclusive locking mode a connection keeps the shared lock of a failed try, so concurrent starts held each other off until every wait ended (a raw probe of round 1 confirmed that a failed try keeps the lock until the close). Fix: each try of the lock runs on a new connection with no busy wait; a try that fails closes its connection and tries again after a random pause of 1 to 20 ms, until 5,000 ms after the start of the open; a query after the lock has the busy wait of 5,000 ms again.

## Round L1 (reduced: spec, failure path)

No reproduced defect. Probes: 2, 8, 16, and 32 starts at once, on a new and an existing file, starts in 4 other VMs with starts in this node, a holder that keeps the lock, a holder that keeps only a shared lock, a holder that lets go at 2,000 ms and near 5,000 ms, and kills of waiting starts: one winner in every round, `:store_locked` at 5,000 to 5,040 ms, no livelock, descriptors back to the base after the holder closes.

| # | Finding | Resolution |
|---|---|---|
| 1 | The 8-start test does not fail on the old code on macOS | Added a test that does: a writer holds the file, two opens wait, the writer lets go after 200 ms; the old code failed both |
| 2 | The moduledoc said "after the busy wait of 5,000 ms" | Fixed: the open tries the lock until 5,000 ms after its start |
| 3 | The Bounds row of `hub.md` ("`BEGIN EXCLUSIVE` ... fails after the busy wait") and decision 9 ("then `COMMIT`") describe the old lock; the value, 5,000 ms, holds | Open, wording for the owner: decision 9 stays as the owner wrote it |
| 4 | The answer can come up to one pause and one try (about 40 ms) after 5,000 ms | Accepted: the check of the deadline comes before the pause |

The second precommit failed only on Credo: `sqlite.ex` had 413 lines. The schema text and its version moved to `Helyx.Hub.Store.SQLite.Schema`, the module that owns the schema of `user_version` 1. A reduced review compared the moved SQL with the committed text: the same 2,154 bytes, the same 22 rows of `sqlite_schema`, version 1.
