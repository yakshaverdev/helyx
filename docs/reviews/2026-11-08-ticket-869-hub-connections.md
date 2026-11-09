# Review: #869, slice C7 (the connections of each user and the closes of a change of access)

Ticket #869, `docs/features/hub.md`, decision 13: `Helyx.Hub.Connections` keeps the connections of each user from the Hub call of their `hello`, with a monitor, and drops one at its `:DOWN`. A revoke of a token (operator API or wire) closes the connections that proved it; a remove of a user closes its connections; a record update or delete that takes read access closes the connections of every user but the owner; each close is 4403 through `Helyx.Transport.WebSocket.close/2`. Base: `522d9f91`.

Not in the slice: protocol 4 and the `token` field in the schema, `helyx serve`, the Elixir API of decision 5, schedules (#870).

## Round 1 (full)

Bounds sensor: `0 candidate functions`.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec and failure path, reproduced | A remove of a user deletes its records by cascade; a deleted "hub" record takes read access from its readers, but only the removed user's connections closed, so a reader went on streaming | Fixed: a remove of a user who owns a "hub" record (store query `hub_records?/2`, before the remove), or whose query fails, also closes every user but the default owner; test |
| 2 | Codex (high) | The transport might call `hello` before its connection cap, so the Hub would track more than 64 | Rejected: the gate admits at most 64 connections before the upgrade (`Gate.enter`), `hello` runs only in an admitted connection, and an entry leaves at its `:DOWN`; the spec agent of round 2 judged the rejection right |
| 3 | Standards, spec | Tests: the revoke of the connection's own token (close before any reply), a failed proof leaving no entry; a test name; the wording of the bound of 64 | Added and fixed |

## Round 2 (reduced: spec, failure path)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec and failure path, reproduced | A store that failed the read of the record before a change from "hub" that then committed closed nothing, and a reader went on streaming | Fixed in round 3 at the mechanism |
| 2 | Spec and failure path, reproduced | The owner of a record who deletes it keeps its other connections, which go on streaming the session that the default owner now owns | Open for the owner: decision 13 closes "every user but the owner", and the Hub call does not know which connection sent the request, so the close of the owner's connections would also close the one that waits for its reply |

Round 2 found a second defect on the rule that decides which connections a change closes, so round 3 fixed the mechanism: a read that fails before a change that commits, or a store that fails after it (`{:error, :failed}`, which can come after a commit), closes every user but the one who made it.

## Round 3 (full: simplify, sensor, Codex, spec, failure path)

Bounds sensor: `1 candidate functions, 0 flagged`. The spec and failure-path agents died at the usage limit of the account and were rerun.

No defect reproduced. With a store that failed the nth call of any callback (`labels`, `users`, `user`, `token`, each of the four reads of a record) on an update or a delete, the reader closed every time; a change, or a remove, that raced a new `subscribe` closed it.

| # | Source | Finding | State |
|---|---|---|---|
| 1 | Codex (high) | A connection is registered at the Hub call of its `hello`, before its proof is checked in the caller | Rejected: a failed proof closes it at once with 4401 and it leaves at its `:DOWN`; registering at the Hub call means that a revoke between the token read and the proof check still closes it; both agents agreed |
| 2 | Spec | Two comments said that a change closes every user who could read before and cannot after; the owner before keeps its connections | Fixed |
| 3 | Spec | A refused delete of a "hub" record by a reader, with a credential read that fails, closes the owner | Open, judgement: only on a failing store, and closing is the safe direction |

## Holes for the owner

- The owner of a record who deletes it keeps its other connections until they reconnect (decision 13, "every user but the owner").
- After a restart of the Hub, the connections that proved themselves before are not tracked (Accepted holes, "Monitors after a Hub restart").

Two precommit runs did not finish: the first could not reach the precommit host (an ssh connect timeout), and the second lost its connection during the compile step. The third ran in full and passed.
