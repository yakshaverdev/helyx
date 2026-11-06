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
