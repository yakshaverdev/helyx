# Review: #869, slice C3b (records, projects, and the existence check)

Ticket #869, `docs/features/hub.md`: `hub.records.get`, `update`, `delete`, `search`, `hub.projects.list`, `create`, `update`, `delete`, and the existence check of decision 8 in the caller (`Helyx.Hub.Access`). `Helyx.Hub.authority/1` is now a Hub call that gives the Core and the data folder. New modules: `Helyx.Hub.Records` (the operations in the Hub process), `Helyx.Hub.Params` (the params in the caller), `Helyx.Hub.Store.SQLite.Projects`. Base: `bbf4eeef`.

Not in the slice: `sessions.saved` and `resume` `{cwd}` under a Hub (they refuse), the reserved places of decision 14, the closes of decision 13, the delete of a row whose file is gone at a resume, protocol 4, `helyx serve`, the Elixir API of decision 5.

## Round 1 (full)

Bounds sensor: `6 candidate functions, 1 flagged`: `records.ex labels` (SIZE): a page of at most 257 ids, or one; not a finding.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Codex, standards, spec, failure path, reproduced | A search cursor whose time passes 2^63 - 1 crashed the Hub process in the SQLite bind | Fixed: the cursor time is 0 to 2^63 - 1, else `bad_params`; tests at both |
| 2 | Codex, standards, spec, reproduced | A session file header whose `model` is not a text crashed the Hub at the first update of a derived record; the row took the current model of a running session, not the model of its start | Fixed in round 2 and round 3 (one check of every value) |
| 3 | Codex (high), reproduced by its probe | The existence check ran before the Hub call, whose deadline started later: a record write could commit after the wire answered `timeout` | Fixed: a `hub.*` run carries one deadline from its start, 6,000 ms less 500 ms, and `Helyx.Hub.call/3` uses the earlier of it and its own; test |
| 4 | Failure path, reproduced | A running private session answered in 0 to 2 ms and a missing id after the find of the whole data folder | Fixed: a Core with a data folder runs the find for every id |
| 5 | Standards | `authority/1` raises on a Hub that does not answer | Documented: the product starts the transport after the Hub, with a registered name |
| 6 | Spec, standards | Tests at the edges: titles, labels, project names, queries, limits, the cap of 10,000 at the first update of a derived record | Added |
| 7 | Spec | The deadline of a `hub.*` op, 6,000 ms, does not hold the find (5,000 ms) and a Hub call (5,000 ms) | Open, see the holes below |

## Round 2 (reduced: spec, failure path)

The failure-path agent died at the usage limit of the account and was rerun (#784: a stalled agent is rerun).

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec, reproduced | A running session whose file was deleted counted as missing | Fixed in round 3 |
| 2 | Spec, reproduced | The header check took a model with a control character | Fixed in round 3 |
| 3 | Failure path, reproduced | A Core with no data folder stored a `cwd` from `list_live` with no check (0 or 10,001 bytes) | Fixed in round 3 |
| 4 | Spec | The margin before the wire timeout of a `hub.*` op is 500 ms, not the 1,000 ms of decision 5 | Open, see the holes below |

Round 2 found defects on the mechanism that round 1 patched, so round 3 fixed the mechanism: a Core with a data folder takes `cwd` and `model` from the header of the find for every id, and from `list_live` only for a session that runs with no file; a Core with none takes them from `list_live` for every id; every value, from either source, passes one check (`cwd` UTF-8 of 1 to 4,096 bytes, `model` a text of 1 to 256 bytes), else the session counts as missing.

## Round 3 (full: simplify, sensor, Codex, spec, failure path)

Bounds sensor: `9 candidate functions, 1 flagged`: `records.ex labels`, as above.

Every reproduction of rounds 1 and 2 holds; no input of a client, a session file (FIFOs, links, devices, damaged headers), or the live list crashed the Hub; 300 generated params over the seven ops gave refused equal to missing; a write held past the run deadline did not commit.

| # | Source | Finding | State |
|---|---|---|---|
| 1 | Spec, reproduced | `resume {id}` of a session with a `cwd` over 4,096 bytes answers `not_found`: the value check of the existence check also applies to `resume`, which only needs the session to exist | **Open.** A `cwd` that exists has a path under `PATH_MAX` (4,096 bytes on Linux), so only a Core given such a `cwd` meets it. Fix: `resume` uses the existence of a source, not the check of its values |
| 2 | Codex (high), not reproduced | A session file name that is not UTF-8 could make `Scan.find/2` raise in the linked Task and end the worker of the request (`failed` in place of `session_not_found`) | **Open, unverified**: APFS refuses such a name (`eilseq`), so the probe could not make one here; a Linux host can |
| 3 | Codex, failure path | The `check` of `resume {id}` now runs the find, and `list_live` for a session that runs with no file, before its Hub call: the bound of `check` in decision 5 ("one Hub call, 5,000 ms") and the Bounds row of the existence check leave them out | Open, wording for the owner; no wire deadline runs during `check`, so no late write |

Round 3 reproduced a defect on the mechanism that rounds 1 and 2 patched, so the small-fix round does not apply; the slice commits the code as reviewed in round 3.

## Holes for the owner

- The margin before the wire timeout of a `hub.*` op is 500 ms: the find of the existence check takes up to 5,000 ms of the deadline of 6,000 ms. Decision 5 states 1,000 ms; the numbers of decision 5 do not hold a find and a Hub call in 6,000 ms.
- A running session whose `cwd` a record cannot hold counts as missing for its record operations (and, open item 1, for `resume`).
- A text over `Helyx.Session.max_text_bytes/0` needs the parts of the wire; the refused-equals-missing test does not send one.
