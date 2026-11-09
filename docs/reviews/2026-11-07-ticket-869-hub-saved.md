# Review: #869, slice C4 (sessions.saved and the resume of a folder under a Hub)

Ticket #869, `docs/features/hub.md`, decision 7: `sessions.saved` under a Hub goes to `run` and is made in the caller (`Helyx.Hub.Saved`) from two sources, each filtered by access before the page and the cursor: the stored records that the user may read (one Hub call, a query whose access is a column) and, for the default owner only, the scan of Core (`Helyx.Sessions.list_saved/2`, limit 256, in a Task killed after 10,000 ms) less the ids that have a row. The `resume` of a folder becomes the `resume` of the newest session of the folder that the user owns. Store queries `saved/5` and `newest/3`. Base: `5edb0efb`.

Not in the slice: the delete of a row whose file is gone at a resume, decision 14, the closes of decision 13, protocol 4, `helyx serve`, the Elixir API.

## Round 1 (full)

Bounds sensor: `5 candidate functions, 1 flagged`: `records.ex handle({:newest, ...})` (SIZE): the scan holds at most 256 ids; not a finding. The spec and failure-path agents died at the usage limit of the account and were rerun.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec and standards, reproduced | `invalid_cwd` and a scan timeout answered before any Hub call: a revoked token of the default owner got an answer, not `4403` | Fixed: such answers make the credential Hub call first; tests |
| 2 | Standards | A `cwd` that Core refuses (a NUL byte) was refused only in the scan of the default owner; another user got an empty page | Fixed: the caller checks the rule of Core for every user, `invalid_cwd` before any scan; test |
| 3 | Spec, reproduced | `{"after": null}` and `{"cwd": null}` were accepted | Fixed: a key that is present holds a value of its type; tests |
| 4 | Standards | A clause for a state that the params check excludes; stale comments of the authority arg | Fixed |
| 5 | Codex | The `resume` of a folder compares `active_at` of a stored record with the file mtime of a derived session | Rejected: decision 7 says newest is the order of `sessions.saved` under a Hub, which merges the sources by `{mtime, id}`, `active_at` being the `mtime` of a stored record; the spec agent of round 2 judged the rejection right |
| 6 | Spec and failure path, reproduced | The stored query reads every readable row and sorts it (a temp B-tree; about 300 ms at 640,000 rows) | Open for the owner: the schema of the doc has no index on `(owner, active_at)` or `(visibility, active_at)`, so the Bounds row "reads at most `limit` + 1 stored rows" holds with no `cwd` only with a schema change |
| 7 | Spec | Tests: the default owner over both sources at every limit, the item fields, `next` null on a page that is exactly full | Added |

## Round 2 (reduced: spec, failure path)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec, reproduced | A timeout of the Hub call itself matched the clause of a scan timeout, so a second Hub call followed (two credential checks, and past the run deadline) | Fixed in round 3 at the mechanism |
| 2 | Failure path | The transport answers `bad_params` for params that are not an object, or a `resume` with bad params, before the authority: a revoked token gets a reply and the connection stays open to its next request | Open for the owner: decision 5 sets this order (the transport checks the params of a session operation before `check`); code of slice C1 |

Round 2 found a second defect on the handling of early answers, so round 3 fixed the mechanism: `page/3` and `newest/3` check the credential themselves for an answer decided before the Hub call, with one credential-only Hub call; any other answer is the one of the Hub call that answered.

## Round 3 (full: simplify, sensor, Codex, spec, failure path)

| # | Source | Finding | State |
|---|---|---|---|
| 1 | Failure path, reproduced | A scan that crashes (the Core stopped: `Helyx.Core.config/2` raises in the linked Task) ends the worker of the request before any Hub call: a revoked token gets `failed`, and its connection stays open to its next request | **Open.** Fix: catch the end of the scan Task and send it through the credential call, as a scan timeout. The existence check of slice C3b runs its find in a linked Task the same way |
| 2 | Codex (high) | The stored source holds `limit` + 1 rows, so a page could lose stored rows behind newer derived ones | Rejected: the page is the first `limit` items of the union; a stored row past the first `limit` + 1 stored rows has `limit` + 1 newer stored rows ahead of it, so it is not in the page, and a fetch of `limit` + 1 stored rows makes the union longer than `limit`, so `next` is set |
| 3 | Spec | `sessions.saved` with a NUL `cwd` and a bad `limit` answers `bad_params` under a Hub and `invalid_cwd` without one: Core checks the `cwd` first | Open, judgement: every user gets the same answer |
| 4 | Spec | The credential call after a scan timeout has no run deadline; it can end after the 15,000 ms of the transport | Open: the call reads only |

Round 3 reproduced a defect on the mechanism that rounds 1 and 2 patched, so the small-fix round does not apply; the slice commits the code as reviewed in round 3.

The first precommit failed one test that the slice does not touch: `Helyx.Provider.Codex.PromptTest` "a compaction of a stored thread opens it with the empty prompt", `** (EXIT from ...) :epipe` on the precommit host. It passed 5 of 5 runs here; the next precommit ran in full.
