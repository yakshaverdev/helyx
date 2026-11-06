# Review: ADR 0012, remote hands (#856)

Base: `d31eda21` (merge base with origin/master). Change: `docs/adr/0012-remote-hands.md` (new), an update note in `docs/adr/0003-hands-process.md`, and one Out-of-scope line in `docs/features/wire-protocol.md`. Markdown only: no simplify and no standards axis. The Codex review ran because the change touches `docs/features/`. A spec agent checked the ADR against the ticket, the owner decision, the ADRs, and the code, because the orchestrator asked for it. No failure-path agent ran: the change has no code to probe.

Invariant: the session talks to its hands, local or remote, only through serializable terms. Every wait of the server on a remote hands is bounded. Every legal Core value either crosses or fails only its own operation. No session state lives on the runner.

## Bounds sensor

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (first round: spec and Codex)

| Axis | Reproduced defects | Other findings |
|---|---|---|
| Spec | 2: the lease pointed the wrong way (at least 45,000 ms, after the server takes the hands as lost); provider options described as data in one place and as runner config in another | protocol number wording; end reason `stopped` called "as today"; the runner choice overlaps #857 executor assignment; a tool result called a JSON object; the second `Stream.check/1` not named; the stop report as text; the revert for local hands goes beyond "for remote hands" |
| Codex | 3: a ping does not bound a remote request; `Helyx.Tool.Agent` needs the Core of the session; a joined limit of 25 MiB cannot carry a legal 8 MiB message event | none |

All fixed in the ADR. The revert for local hands was kept: the ticket says "the local hands become one implementation of the protocol", so the two kinds share one path. The owner should confirm it (see "Open").

## Round 2 (reduced: spec and Codex)

| Axis | Reproduced defects | Other findings |
|---|---|---|
| Spec | 5: no Core bound for the terms sent to the runner (each turn context, `transcript/0`); the value-count bound of the decoder not covered; the end reason of a deadline kill is `crashed`, against §4; a missed deadline left the connection open, so the runner never released; context files and skills read from the server's filesystem | the provider start options listed wrongly; atoms from network keys; one oversized event closes every session of the runner |
| Codex | 3: capability discovery has no deadline; the frame derivation misses terms with no Core bound and the decoder value limit (a probe: tool arguments of 65,536 zeros pass Core and close the frame decoder with `4400`); provider error reasons are any term | none |

The frame limit had three findings across two rounds, so the mechanism changed, not the path: the derived limit is gone, and the sender checks each term against stated limits and fails only that operation. The other findings were fixed in the ADR: deadlines armed with `:timer.exit_after/3` and a `{:shutdown, _}` reason, a close of the connection at a missed deadline, reasons as `Helyx.Reason.text/1`, reads of the folder through the hands, and the corrected start options.

## Round 3 (reduced: spec and Codex), the limit

| Axis | Reproduced defects | Other findings |
|---|---|---|
| Spec | 2: the stop of a provider process (`Process.exit/2`, then a wait for `provider_down`, `turn_loop.ex:385-388`) is not among the requests with a server deadline; a stand-in killed with its session (the supervisor kill after `Stop.shutdown_ms/0`) sends the runner no signal, so the hands of that session stay on the runner | §4 says the stop report gives every handle as unconfirmed "as today", but today a dead hands gives `:unknown` (`stop.ex:78-81`); one turn context can outgrow the term limit, a lasting difference from local hands; the 16 requests in flight have no stated direction on a hands connection |
| Codex | 1: §2 sends raw provider reasons to the runner log, against the rule of ADR 0006 (revision of 2026-10-19) that `Helyx.Reason.log/2` keeps: the log gets the kind only | none |

The first two spec defects are the third finding on the deadline mechanism (round 1 Codex, round 2 Codex, round 3). So no small-fix round: the rule stops the patching. The commit holds the text as round 3 reviewed it.

## Open

Not fixed in the committed text. The build ticket or the owner decides:

1. **Deadline mechanism.** A list of the requests that get a deadline keeps missing cases. Proposal for the next round: bound the runner as a whole, not each request. The stand-in sends a request through the runner's dispatcher at a fixed interval and needs an answer within a deadline, so it proves the dispatcher works, not only the socket. The runner arms every local deadline of today on its own node. Every wait of the server is then bounded by a local deadline on the runner plus the liveness deadline.
2. **Death of a stand-in.** Any end of the stand-in must reach the runner: the server closes the runner's connection, or sends a stop for that session instance. `Stop.shutdown_ms/0` must include the network margin.
3. **Runner log.** §2 "the raw term goes only to the runner's log" must read: the runner logs the reason with `Helyx.Reason.log/2`, the kind only.
4. **Stop report wording.** §4: the report of a lost remote hands names the hands as lost; the server cannot list handles that only the runner held.
5. **Owner confirmation.** The revert of the update of 2026-10-12 of ADR 0003 for local hands too, and a missed deadline that stops every session of a runner.
6. **Feature doc items.** A turn context over the term limit fails every turn on remote hands. Compaction is the way out, and the feature doc states this. It also gives the direction of the 16 requests in flight on a hands connection.

## Follow-up after the owner decision (2026-11-06)

The owner accepted the four choices of "Open" item 5 and added the key rule: a runner that the agent controls never holds a long-lived model key, and gets model access through a server-side proxy with a token for one session; a runner that its owner controls may hold the owner's keys. The follow-up states the key rule in §6 and fixes Open items 1 to 4:

1. Liveness through the request handler, local bounds on the runner, and a rule for a class of waits: each answer that the server waits for, the `provider_down` after a stop of a provider process included, has the local bound of the operation plus a network margin. The stop of a provider process becomes a request.
2. The connection process watches the stand-in. At any end of it, the connection sends the runner a stop of that session instance, or closes when the stop is not answered.
3. The runner logs with `Helyx.Reason.log/2`, the kind only.
4. The stop report of a lost hands gives `:unknown`, as `Helyx.Session.Server.Stop` does today.

It also moved one sentence back into the "Provider start" bullet, where a round-2 edit had put it in the wrong bullet.

### Round 4 (reduced: spec and failure path), base `9be5da87`

| Axis | Reproduced defects | Other findings |
|---|---|---|
| Spec | 0 | judgement: `@hands_stop_ms` (`stop.ex:22`), not only `Stop.shutdown_ms/0`, would need the network margin; wording: "tool arguments, or a credential" goes beyond ADR 0006, which names message text; wording: "a call of a tool into its session" is in the list of server waits, but the server answers it; wording: the liveness row of the bounds table does not say "past it the server closes the connection" |
| Failure path | 3, all in the deadline mechanism: (a) the hands run each release in their own process, each up to `release_ms` (`hands.ex:199,207,305`), so a cancel, a stop, or a liveness answer in the same queue waits for the sum of the releases ahead of it; "local bound plus margin" then closes the connection of a runner that is only slow; (b) the wait for the provider end in `Stop.run` (`stop.ex:45-49`, no `after`) does not watch the stand-in, so a session stop with a dead stand-in ends only at the supervisor kill, and the stop report is lost (a probe showed the receive stays blocked); `shutdown_ms` counts only `provider_close_ms` for that wait; (c) `Hands.stop/3` takes a monotonic deadline (`stop.ex:74`), which means nothing on another node | duplicate: the stop wait has two deadlines, the call timeout `@hands_stop_ms` and the stand-in deadline, with different values |

These are more defects in the deadline mechanism, which was already patched in rounds 1, 2, and 3 and in this follow-up. On the orchestrator's order they are not patched. The commit holds the text as round 4 reviewed it.

## Open after round 4

1. **Deadline mechanism** (round 4 failure path, a to c, and the duplicate). A per-operation bound on the server does not hold while the runner runs its releases one after another in one process. A design step decides it, not another patch. The question: is a server deadline per answer needed at all, or does the liveness answer (which shows that the handler works) plus the local bounds on the runner bound every wait, with one stop deadline and durations, not monotonic instants, on the protocol?
2. **Wording** (round 4 spec): `@hands_stop_ms`; the reason "tool arguments, or a credential"; a call of a tool into its session in the list of server waits; the liveness row of the bounds table.
3. **Not reached by the review:** whether a stand-in learns of the connection's death sooner than the liveness deadline; what `ProviderConn.pid`, the armed kill of `ProviderRequest.ask/3`, and the provider monitor (`turn_loop.ex:131`) become with a provider id; the replace cell with an old runner that is half open; the lease while liveness frames keep arriving but the request handler is stuck.
