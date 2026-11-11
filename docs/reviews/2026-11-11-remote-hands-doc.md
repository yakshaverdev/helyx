# Review: the feature doc of remote hands (#927)

Scope: `docs/features/remote-hands.md`, new. The change is Markdown only, a feature doc, so `/ship` runs only the Codex review of step 2 on it (the exemption of `/ship` for Markdown, with the exception for feature docs).

## Round 1: Codex adversarial review (working tree)

Verdict: needs-attention, four findings. Each was checked against the code at `ff10c88b` or ADR 0012.

| # | Finding | Check | Resolution |
| --- | --- | --- | --- |
| 1 | high: the inventory misses the `:start` gate of the provider process | confirmed: `ProviderProcess.run/1` waits for `:start`; the session sends it at `lib/helyx/session/server/turn_loop.ex:151` and `summary.ex:63`, and the summary path sends an exit in its place | added the term `hands.provider_go {id}`, and the summary abort as `hands.provider_stop {id, aborted}`; slice 3 names it |
| 2 | high: the inventory misses `Helyx.Tool.show/2` and the `:DOWN` of asker Tasks | confirmed: `show/2` calls the session by its Core and id (`lib/helyx/interfaces/tool.ex:208`, `Server.Calls.handle/3`); `Server.Asks` monitors each asker pid (`asks.ex:44`) and `Asks.down/3` ends its asks | added `hands.show` with its answers, and `hands.task_down`; slice 5 names them |
| 3 | medium: S→H terms with no answer mapped to `event`, against ADR 0012 §5 (and §2 makes the provider stop a request) | confirmed: §5 says the server sends `req` frames for the terms that the session sends | every S→H term is a `req`; a term with no answer today gets the `res` `{}`, on which the stand-in arms no deadline (§3) |
| 4 | medium: open decision 4(b) wrote a credential to disk, against §5a | confirmed: §5a keeps only the SHA-256 in memory and writes no disk | replaced (b) with a mint through an owner's client operation, which writes no disk, and stated it as the owner's call on §5a |

## Round 2: reduced round (Codex, working tree)

Invariant: the doc lists every message between the session and its hands with a data term, and changes no decision of ADR 0012.

Verdict: needs-attention, two findings.

| # | Finding | Check | Resolution |
| --- | --- | --- | --- |
| 1 | high: the context requests `{:need_context, turn_id}` and `{:need_context, turn_id, :overflow}` are missing, and `Stream.check/1` does not take them | confirmed: `ProviderProcess.action/2` sends them (`lib/helyx/session/provider_process.ex:173`, `:176`), and `Server.TurnLoop.handle/2` takes them (`turn_loop.ex:76-89`) | added `hands.need_context` with its own check; the provider event row now lists every send of `ProviderProcess.action/2` by shape (stream event, stream end, tool request, approval, resume id) |
| 2 | medium: open decision 4(b) still put the credential in a frame of the owner's client, which §5a forbids ("never in a frame") | confirmed against the Mint clause of §5a | replaced (b) with a mint on the server's command line, which changes a rule of `docs/features/serve.md` (decision 1), not the ADR, and stated that a frame is not an option |

## Round 3: reduced round (Codex, working tree)

Verdict: needs-attention, one finding.

| # | Finding | Check | Resolution |
| --- | --- | --- | --- |
| 1 | high: the provider `:DOWN` monitor is missing; `hands.provider_down` comes after the release, but the session takes the death earlier (`monitor_down/1`) | confirmed: `Process.monitor(pid)` at `lib/helyx/session/server/turn_loop.ex:150`; the provider Task has no asker (`Helyx.Session.Ask.asker(nil, _)`) | added `hands.provider_exit {id}`, sent before the release, with its order before `hands.provider_down` |

Three rounds each found one more message missing from the hand-built inventory: two findings on one mechanism. So the fix of round 3 also enumerated every site at once, in place of one more row: every `Process.monitor`, `Process.exit`, and `send` to a pid of the hands side in `lib/helyx/session/server.ex` and `lib/helyx/session/server/`, every `info/2` clause of `Helyx.Session.Server`, every `Server.Calls.handle/3` request, and every session call of `Helyx.Tool`, `Helyx.Hook`, and `Helyx.Session.Ask`. The enumeration found two more things, fixed in the same edit: the pid of a `started` result is used (`Asks.started/3` moves the asker record by it), so the term carries a task id; and `deferred/2` and `activate/1` are calls into the session from any tool call or hook, now named under open decision 2. The other sites stay on the server: the subscribers (`events.ex`), the open (`open.ex:120`), the prepare Task (`wait.ex:150`), the lock port, and the sync process.

The fix touches one file, Markdown only, with no code, so it is the small-fix round of `/ship` after round 3.

## Small-fix round: reduced round (Codex, working tree)

Verdict: needs-attention, one finding.

| # | Finding | Check | Resolution |
| --- | --- | --- | --- |
| 1 | medium: `hands.task_down` was stated after the release, but the session gets the `:DOWN` of an asker Task at its death (`Server.Asks`, `lib/helyx/session/server/asks.ex:44`, `Asks.down/3`), while the hands release before they deliver the result (`Hands.deliver_call/3`, `Hands.Hooks.deliver/3`) | confirmed by reading the code | the row now sends `hands.task_down` at the death, before the release, also while other releases wait. This fix had no review round |

The small-fix round reproduced a defect, so the loop ends here (`/ship`, step 2). No version of the doc passed a round without a finding, so nothing is committed; the doc and this record stay in the worktree for the owner.
