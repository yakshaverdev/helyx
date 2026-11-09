# Review: #869, slice C6 (the live set and the reserved places)

Ticket #869, `docs/features/hub.md`, decision 14: `Helyx.Hub.Live` keeps the live set (the session processes that a start or resume through Hub made or attached to, each with a monitor, and every live session of the Core at the start of Hub) and the reserved places (one for each process that ran a `check` of a `start`, or of a `resume` of a session that does not run, until its `result`, its `release`, its `:DOWN`, or 60,000 ms). A user whose live sessions plus places reach `:max_live_sessions` gets `too_many_sessions`; a start of a user who is not the default owner also needs a place among its records. `Helyx.Hub.Server` gives the caller pid to the requests that take or end a place; `Helyx.Hub.Access` sends whether a resumed session runs, the session pid at `result`, and makes a Hub call in `release`. Base: `ad3c5095`.

Not in the slice: the Elixir API of decision 5 (`start_session/3`, `authorize/4`, `owner/2`), the monitors of connections of decision 13, schedules (#870), protocol 4, `helyx serve`.

## Round 1 (full)

Bounds sensor: `1 candidate functions, 1 flagged`: `server.ex handle_continue(:live)` (SIZE): it reads `list_live/1` of one Core, at most 64 sessions; not a finding.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec, reproduced | A `resume` refused at the cap still moved `active_at` | Fixed: the place comes before the touch, for `resume {id}` and for the resume of a folder (the touch of its stored winner moved to the server); test with an old `active_at` |
| 2 | Spec, reproduced | The resume of a folder whose newest session runs outside the live set (a child of the agent tool, a session that a product starts) got `too_many_sessions` at the cap | Fixed: the Hub process asks the Registry (`Helyx.Session.pid/1`, a lookup that does not wait) for that one id; test |
| 3 | Standards | A store error in the count of the live sessions turned into a cap answer | Fixed: `failed` |
| 4 | Standards | The end of the read at the start could arrive after it, and tests that count the mailbox would see it; test polls with no bound; sleeper processes that leak | Fixed in round 3 (the read), `Helyx.Test.Events.wait_until/3`, `spawn_link` |
| 5 | Codex | (withdrew its own finding) | — |
| 6 | Spec and failure path, reproduced | A `result` that the Hub drops (busy, or taken past its deadline) leaves a running session out of the live set: its place ends at the `:DOWN` of its caller, and the user can pass its cap | Open for the owner (hole) |
| 7 | Failure path, reproduced | A restart of the Hub drops the places of the starts in flight | Open for the owner (hole): the Ownership row says that a crash of Hub frees every place; Accepted holes does not say that the cap can then be passed |

## Round 2 (reduced: spec, failure path)

The failure-path agent died at the usage limit of the account and was rerun.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec, reproduced with a stand-in Task | The read at the start could wait forever: a reply between the deadline and the kill left an unbounded `receive` of the `:EXIT` | Fixed in round 3 at the mechanism |
| 2 | Spec | A resume refused after it took its place (its touch failed) kept the place until its caller ended | Fixed: the place goes back |
| 3 | Failure path, reproduced | `hub.records.delete` of a running session of a user moves it off the user's count to the default owner, so a user can pass its cap and fill the cap of the default owner | Open for the owner: decisions 8 and 14 as written count a session by the owner of its record |
| 4 | Failure path, reproduced | A client that closes during a `start`, after the Core start and before `result`, leaves the session out of the live set | Open for the owner: the hole of item 6 of round 1, reached by an ordinary close |

Round 2 found a second defect on the read at the start, so round 3 fixed the mechanism: the read runs in a process with a monitor and no link (`spawn_monitor`) and gives its answer as its exit reason; past 5,000 ms it is killed and its `:DOWN` taken in `handle_continue`. The Hub gets one `:DOWN` and no `:EXIT`.

## Round 3 (full: simplify, sensor, Codex, spec, failure path)

Bounds sensor: `2 candidate functions, 1 flagged`: `records.ex handle({:newest, ...})`, as in slice C4.

No defect reproduced. A read past its deadline let the Hub start at about 5,000 ms with an empty set and no later message; a read that crashed started it at once; a resume refused at the cap, or whose touch failed, left no place and no touch.

| # | Source | Finding | State |
|---|---|---|---|
| 1 | Codex (high) | A `nil` pid from the read reaches `Process.monitor/1`; a session attached before the seed gets a stale monitor | Rejected: `pid = Helyx.Session.pid(...)` in the comprehension is a filter, so a `nil` drops the entry; `handle_continue` runs before the Hub takes any call, so no attach comes before the seed |
| 2 | Failure path | A start refused at its `result` (a revoked token, a failed record write) still enters the live set, counted for the default owner | Open for the owner: decision 8 gives a session with no record to the default owner |
| 3 | Failure path | A stop of the Hub during a slow read at its start is a kill after the shutdown of 5,000 ms, and the store is not closed by `terminate` | Open: the Bounds row "the stop of Hub" names the kill past 5,000 ms; SQLite frees the lock with the connection |
| 4 | Spec | The Ownership table has no row for the read process; for up to 5,000 ms at its start the Hub answers no call (a `hello` then gets 4503) | Open, wording for the owner |

## Holes for the owner

- A `result` that the Hub drops (busy, past its deadline, a client that closes during the start), and a restart of the Hub, leave running sessions out of the live set or drop places: a user can pass `:max_live_sessions` by them; the Core cap holds.
- A record delete, or a failed record write at a start, moves a running session to the count of the default owner.
