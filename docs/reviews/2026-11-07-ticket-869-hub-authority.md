# Review: #869, slice C3a (the authority of a Hub)

Ticket #869, `docs/features/hub.md`, decisions 3, 4, 5, 7, 8. `Helyx.Hub.authority/1` gives `{Helyx.Hub.Access, hub}`: `Access` runs in the processes of the transport, `Rules` decides in the Hub process. In the slice: the proof of `hello` (the server token and the default owner, a token id and its user), the credential check before each `check`, `run`, and `result`, `hub.me`, `hub.tokens.list`, `hub.tokens.revoke`, the filter of `sessions.live`, the record write at the start of a user who is not the default owner, and the access of every session operation. Structure: `Helyx.Hub` keeps the API, the options, and the Hub call; `Helyx.Hub.Server` is the process; the SQLite helpers moved to `Helyx.Hub.Store.SQLite.Query` and the record queries to `Helyx.Hub.Store.SQLite.Records`, so each file stays under 400 lines. Base: `29003604`.

Not in the slice: `hub.records.*` and `hub.projects.*`, `sessions.saved` and `resume` `{cwd}` under a Hub (they refuse: `failed` and `not_found`), the existence check of decision 8, the reserved places of decision 14, the monitors of decision 13 (but the revoke of the token of the connection itself), protocol 4, `helyx serve`, and the Elixir API of the session (`start_session/3`, `authorize/4`, `owner/2`).

## Round 1 (full)

Bounds sensor: `9 candidate functions, 1 flagged`: `server.ex default_owner` (SIZE): it reads the users, at most 64; not a finding.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec, reproduced | A start of a user with `cwd: ""` was accepted and wrote a record with an empty `cwd` | Fixed: 1 to 4,096 bytes; tests |
| 2 | Spec and standards, reproduced | The server-token closure ran in the Hub process with no check: `fn -> nil end` crashed the Hub at the first `hello` | Fixed: the Hub call returns the closure, the caller runs it and needs a non-empty binary, else `4401`; test |
| 3 | Codex, spec, reproduced | `run` of `sessions.saved`, of `hub.*` with bad params, and of an unknown `hub.*` op made no Hub call: a revoked credential got an error and the connection stayed open | Fixed: each makes a credential Hub call first; test |
| 4 | Spec | The default model read (`Helyx.Core.config/2`) raises in the Hub process when the Core stopped | Fixed: `failed`; test |
| 5 | Standards | A store failure at the lookup of `hello` closed with `4401` | Fixed: `busy`, `4503` |
| 6 | Failure path, reproduced | Concurrent starts of a user at the records cap all pass `check`; Core starts each, and the record write of all but one fails, so the default owner owns those sessions | Open by plan: the reserved places of decision 14 (the next slice) hold a record place from `check` to `result` |
| 7 | Failure path | A revoke between the `check` and the `result` of a start: the user gets `4403` and the default owner owns the session | Open: the accepted hole "Hub crash between a start and its record" names a timeout and a crash; this case needs a line for the owner |
| 8 | Standards, spec | Wording: the comment of `cut/1` (the frame decode admits only UTF-8), of `put_record`, of the token key, of "one Hub call" (`release` makes none); the `busy` text of `hub.*` ops | Fixed |
| 9 | Standards, spec | Tests: the four missing session ops in refused versus missing, `resume` compared in full, the prompt cut at 1,024 and 1,025 bytes and with 3- and 4-byte characters at the edge, the records cap at the result, `resume` moving `active_at` | Added |
| 10 | Standards | `Records` holds no state of its own | Kept: it owns the record queries, which the next slice (`hub.records.*`, search) grows |

## Round 2 (reduced: spec, failure path)

Both agents re-ran the reproductions of round 1; each holds. 52 requests with a revoked token or a removed user closed with `4403`; refused and missing answered the same code and text for every session operation, also with params that Core checks before its lookup (for a user who is not the default owner). No reproduced defect ends the loop.

Fixed after round 2: the test of the revoke of the connection's own token reads the close as the first frame; a test of the default model read with a stopped Core.

Open:
- The SQLite query layer can answer `{:error, :busy}`, which `Rules` does not map; the exclusive lock of the store means the Hub's own queries never meet a held lock, so it cannot come today.
- `Hub.start_link(name: {:via, Registry, ...})` with a registry that does not run raises in the caller (the option check of slice 1, unchanged here).

The first precommit failed only on Credo strict: two `with` of one clause and an `else` in `Access.run`, and the nesting of `Records.put_record/4` and of the `{:started, ...}` handler of `Rules`. They became a `case` and helper clauses; a reduced review found each answer equal for every input (the cap boundary `n < max` is the old `not (n >= max)`, the same transaction).
