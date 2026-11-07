# Review: MCP client feature doc (#492, #473)

Scope: `docs/features/mcp-client.md` and `docs/research/mcp-client.md`, both new. Markdown only, so `/ship` skips simplify and the review agents. A feature doc and a research note get the Codex adversarial review (#548), with a brief that checks each claim against its source. Base: `540f8a94`, the merge base with origin/master.

## Round 1 (Codex, working tree)

| # | Finding | Check | Resolution |
| - | ------- | ----- | ---------- |
| 1 | The byte cap of the activated list was enforced only in `activate/1`. A re-list with larger schemas, or a group listed after a resume, could pass it | read the doc: true | the cap applies after each `put_tools/2` too, oldest first, with a `tools_change` entry and a nil turn id; tests named in slice 3 |
| 2 | The search answer listed every match as callable, even when the cap dropped some | true | `activate/1` takes the names in rank order and drops the lowest ranked of one call first; the answer lists only the names kept and names the dropped ones |
| 3 | A first search could run before the source published its groups, and so not wait | true | new `announce/1`: a source is pending until it names its groups, and `deferred/1` waits for pending sources |
| 4 | A re-list after `list_changed` had no deadline | true | a re-list has its own 30,000 ms bound and fails the server; test named in slice 8 |
| 5 | Research: the Gemini name clash and embedded blob facts were wrong | reproduced: `tool-registry.js:150-157` and `mcp-tool.js:182-194` of Gemini CLI 0.20.2 | both facts corrected |

## Round 2 (Codex, reduced: the only review of a Markdown change)

| # | Finding | Check | Resolution |
| - | ------- | ----- | ---------- |
| 1 | After a time limit or an abort, the server could still run the cancelled call while the next call starts: MCP gives no confirmation of a cancel | reproduced from the SDK source: `shared/protocol.js:169-175` only aborts a signal | decision 14: a call that ends with no response cancels, stops the server with its group, and starts it again; 3 restarts per session, then the server is failed; new accepted hole: the server loses its memory state |
| 2 | One port's `:epipe` exit could end the shared source process and take every server's tools | true: `watchdog.ex:291`, `harness_epipe_test.exs` | decision 15: the source traps exits; a port exit fails its server only, any other exit signal ends the source |
| 3 | A tool with `execution.taskSupport: "required"` would be listed but cannot be called with a plain `tools/call` | reproduced: SDK `server/mcp.js:116-118` | such tools are left out of a listing with a notice; the fact is in the research note |

## Round 3 (Codex, the last round)

| # | Finding | Check | Resolution |
| - | ------- | ----- | ---------- |
| 1 | `Helyx.Watchdog.start/4` waits with no timeout in its handshake (`read_marker/4`, `watchdog.ex:324-336`) and in its error read (`read_to_exit/2`, `watchdog.ex:216-220`). The source process calls it directly, so a stalled start blocks the source past the 30 s start bound, and killing the source to enforce the bound removes the tools of every server | reproduced by reading the code: both `receive` blocks have no `after` | fixed in a follow-up (below). The commit of round 3 kept it open at the round and time limits |

## Follow-up: the open round 3 finding (asked by the orchestrator)

Every wait of the start path in `watchdog.ex`: `Port.open/2` (an OS spawn), `hold/1` of the watchdog and of the command group and `unhold/1` (calls to the hands), `read_marker/4` and `read_to_exit/2` (no time limit), and the release of a failed start in `let_go/2` (`@gone_ms`, 100 ms). A `:deadline` on `start/4` alone bounds the two reads, but the call still blocks the source process, and the hands accept a hold only from one of their Tasks (`hands.ex:142-147`), so the launches cannot move to other processes. A stalled handshake would then hold the launch of every later server until its deadline. The orchestrator asked for a doc that says a stalled start does not hold the others. The question to the user got "No user can answer in this run. Decide yourself". Decision, as an assumption: slice 8 splits the start into `open/4` and `step/2`, which the source drives from its own loop with a 30 s timer per server, and `start/4` wraps them with the optional `:deadline` (default none). The hold and unhold waits stay outside every deadline, as for every hold today, and the doc says so.

## Round 4 (Codex, reduced, the one round that the orchestrator allowed)

| # | Finding | Check | Resolution |
| - | ------- | ----- | ---------- |
| 1 | The marker can come before the deadline and the command `hold/1` can wait past it; `handshake/3` sends the go-ahead right after the hold (`watchdog.ex:175-179`), and the source cannot handle its timer during the hold. So a server can start after its deadline, and a marker queued before the timer message wins | reproduced by reading the code | **open.** Fix for slice 8: the handshake state carries the absolute deadline; `step/2` checks it when it takes the marker and again after the command hold, before the go-ahead; past it, the port closes and the command never runs. Test: a hold that the hands answer after the deadline, and the command never runs |
| 2 | The release of a failed start (`let_go/2`) runs `Helyx.Watchdog.Group.release/4` in the caller; its deadline is checked only before each `kill(1)` run, and `kill_cmd/1` is `System.cmd/3` with no timeout (`watchdog/group.ex:108-116`). A stalled `kill` blocks the source loop and every other server's start | reproduced by reading the code; Codex also ran a local probe with the kill test hook of `Group.release/4` that stayed blocked past its deadline | **open.** Fix for slice 8: the release of a failed start runs outside the source loop with a deadline it enforces, keeps the handles it cannot confirm held for the hands' release, and reports the confirmed ones to the source as a message. Test: a stalled cleanup while another server completes its start |

The doc is committed as round 4 reviewed it; the two findings above stay open for slice 8.

No round was done by hand.

## Follow-up: the premise of the split start (no review round; the orchestrator's Codex gate follows)

Three findings in a row landed on the start of a server, so the mechanism was questioned before a fix. The split into `open/4` and `step/2` existed only because the launch had to run in the one source process: the hands keep a `hold/1` only from one of their Tasks (`lib/helyx/session/hands.ex:142-147`). Today the hands start Tasks only for the session: tool calls (`run/4`, `hands.ex:70`) and provider processes (`start_provider/3`, `hands.ex:82,241`). The source process is itself new Core of slice 2, so slice 2 also gives it `Helyx.Tool.launch/1`: a server Task of the hands per server, whose holds the hands keep and release at its end. Then `start/4` with its `:deadline` blocks only that Task, and the split is dropped.

- Round 4, finding 1 (late go-ahead): shrinks to one check in `start/4`, after the command hold and before the go-ahead; the doc names it and its test.
- Round 4, finding 2 (cleanup in the source loop): falls away. `let_go/2` runs in the server Task, and the source's 30 s timer kills a server Task that a stalled `kill(1)` holds; the hands release its handles with their release deadline.
- New bound: 16 live server Tasks per source, and one per server, since a new one starts only after the `:DOWN` of the old one.
- A server Task monitors its source and ends with it, so a source that dies leaves no running server.

The owner accepted the tool source inside the Tool interface and the restart after a cancelled call on #492 (2026-11-06); decisions 3 and 14 say so, and decision 14 no longer reads as "stops its server".

## Gate round 1 (the orchestrator's Codex gate), confirmed by the orchestrator

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | [high] `launch/1` returned a pid from the hands, and the hands run `Release.run/4` in their own process for up to `release_ms` (`hands.ex:302-308`): a launch during a release blocked the source, its call routing, and the timers of its other servers | `launch/1` is an asynchronous request with a reply message, as `start_provider/3` is (`hands.ex:82-86`). The source sets each server's timer and absolute deadline at the send of the request, so no wait in the hands moves them; a late `{:ok, pid}` after the timer gets its Task killed. Pending requests and live server Tasks of a source: 16 together, one per server. Tests named in slice 2 |
| 2 | [medium] `deferred/1` waited until no group was `:starting`, so a search for a ready server B waited up to 30 s for a stalled server A | `deferred/2` takes a registry version and answers at once when the registry changed; the search ranks the ready groups first and waits, one change at a time, only when it has no match while a group is starting or a source is pending. New accepted hole: a better match in a server still starting is not in an answer that a ready server gave. The slice 8 test: B is activated and called while A stays in its handshake |

## Gate round 2 (the orchestrator's Codex gate), judged by the orchestrator

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | [high] A slow release in the hands delays a search for a ready server: the hands start no call Task while they run `Release.run/4` (`hands.ex:302-305`) | the claim is narrowed, the hands do not change: the wait exists for every tool call today (ADR 0004). A stalled server never delays a search; a release in the hands can, at most `release_ms` per release that waits before the call. Stated as an accepted hole |
| 2 | [high] A restart could begin before the hands released the old Task: the source's `:DOWN` does not prove that the hands ran the release | the hands send the source `{ref, :released, outcome}` after the release of a server Task; the source launches a replacement only after it; `:unconfirmed` follows rule 6 of `docs/features/tool-resource-release.md`. Test in slice 2: the source gets the `:DOWN` before the hands run the release |
| 3 | [high] A server Task blocked in `let_go/2` cannot handle the source's `:DOWN`, and the source's kill timer dies with the source | the server Task links to its source as its first act and does not trap exits; the source traps exits, so a server Task's exit stays a message to it (decision 15); the hands end a returned `source/1` with `:shutdown`, so the link always passes the end on. Tests in slices 2 and 8: the source dies while a server Task is stalled in its cleanup |

## Gate round 3 and the owner's answer to the park (2026-11-06, #492, option 1)

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | A stalled MCP call delays the other calls and `tool_search`: source tools run alone in the tool queue | accepted by the owner as a hole: at most one call limit, 60,000 ms, as behind a stalled `bash` call today. The invariant is narrowed to "a stalled server never delays the start of other servers or the source"; `Helyx.Session.ToolQueue` does not change |
| 2 | [confirmed] `exit(:normal)` in `source/1` skipped the `:shutdown` end, so a linked server Task could outlive its source | the Core wrapper turns a `:normal` exit of `source/1` into `:shutdown`, as it does for a normal return. Test in slice 2: the source calls `exit(:normal)` while a server Task is blocked in its cleanup |

## The owner's answer to the second park (2026-11-06, #492, option 1)

- An abort during an MCP call returns only after that server's group is stopped, or after its release is unconfirmed, the one abort contract of `docs/features/tool-resource-release.md:20`; the hands do not change. The owner's note named the release message of the server Task as the thing the abort waits for. That wait cannot work: the abort runs in the hands' own process (`hands.ex:193-200`, `cancel/4` at `hands.ex:213-224`), and the release of the server Task's handles needs that process, so the wait would last until its deadline and end unconfirmed. The doc uses the same release in another form: the call Task holds `{:mcp_call, groups}`, the groups of its server, and its `release/3` with `:cancel` stops those groups before the abort returns. The server Task's later release finds them gone, and its release message still gates the restart. Test in slice 9: the server Task is paused before it handles the call Task's `:DOWN`, and the abort does not return before the group is gone.
- The start of another server may wait up to 20 s for each release before it in the hands: an accepted hole.
- The invariant is the owner's text, with the earlier clauses kept.

## Gate round 2 after the owner's answer

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | [high, confirmed by the orchestrator] Two owners held one process group: the call Task's `{:mcp_call, groups}` and the server Task's own handles. The abort stopped the group through the call handle; the server Task's later release signalled the same number, which the OS could have reused (`Group.release/4` checks only the number) | one release record per server start, an `:atomics` slot that both handles name: `{:mcp, record, handle}` for the server Task (a new `:wrap` option of `start/4`, default none) and `{:mcp_call, record, handles}` for the call Task. The release that wins the compare-exchange from 0 signals; one that finds the group released (1) or not confirmed (2, or 3 after a killed release) sends no signal. Chosen over a drop step in the hands because the hands do not change, and over a transfer by `unhold/1` because rule 9 allows an unhold only after the caller's own confirmed release. Rule 9 holds as written: no server group handle is unheld. Test in slice 9: a delayed server Task and a reused group id, whose later release sends no signal |

## The owner's answer to the third park (2026-11-06, #492, option 1)

- The release record moves to `Helyx.Watchdog`: one record per group that `start/4` makes, carried in its handles, and `Group.release/4` takes it before any signal on every path (`release/3` of `bash` and MCP, `let_go/2`, a failed start, the harness providers). The MCP doc drops its own `:atomics` record and the `:wrap` option of `start/4`.
- The helper change and its tests are slice 8 of the doc; the MCP start and the MCP calls are now slices 9 and 10 (the slice numbers in the sections above this one are the old ones). The slice names the test that a reused group number is never signalled on any path: the abort and the delayed server Task, the second release of one bash handle, and the failed-start cleanup that kills its Task between the release and `unhold/1`.
- `docs/features/tool-resource-release.md` gets the rule, "The release record", with its states. Added while writing it: one release that gets two handles with one record (the stop of the session, one release Task per module) takes it once and gives both one outcome; without it the second handle would find the record taken by the same release and stay unconfirmed.

## Gate after the owner's third answer

| # | Finding | Resolution |
| - | ------- | ---------- |
| 1 | [medium, confirmed by the orchestrator] `activate/1` appended its names best first and dropped from the front, so one call's names over the byte cap lost its best matches, against the stated order | the activated list is kept in drop order: `activate/1` appends its names in reverse rank, best last, and every cap, after `activate/1` and after `put_tools/2`, drops from the front. Older activations leave first, and within one activation the lowest ranked. Slice 3 test: one activation over the byte cap keeps its best matches |

The gate found no defect in the release record design.

## The slow recall test (2026-11-07), the condition of the merge

Owner decision of 2026-11-07 on #492 (option 1: measure, then decide). The test "recall over 100,000 log files ..." of `plugins/bundled/test/helyx/memory/markdown_test.exs` waits `@recall_ms + @load_ms`, with the orchestrator's measurement on the idle precommit host (69 to 85 ms) in its comment. Base `89d84792`. One reduced round (spec and failure path), as the orchestrator asked. Bounds sensor: `0 candidate functions, 0 flagged, 0 without an answer` (a test file only).

| # | Axis | Finding | Check | Resolution |
| - | ---- | ------- | ----- | ---------- |
| 1 | spec | The test name still said "ends within the default recall_ms" | true | renamed: "ends within the largest recall_ms" |
| 2 | spec | The factor "sixty" had no source: it mixed setup and removal on a loaded laptop with the setup alone on the idle host | true | the comment gives the measured slowdowns (4 to 6 times for a recall on a loaded laptop, more than 23 times in the gate runs, about 27 times for the setup, marked as an estimate across two machines) and calls the margin a judgement on them |
| 3 | spec | "Far above the delays that load makes" had no measurement: no loaded recall was timed to its end | true | stated in the comment |
| 4 | spec and failure path | The first margin, 8,000 ms, made a bound of 10,000 ms, above the largest `recall_ms` that Core accepts, 9,000 (`lib/helyx/core.ex:41-42`, `Helyx.Session.Recall.max_ms/0`): the test passed a recall that every Core setting would cut | read in the code | `@load_ms` is 7,000, so the bound is 9,000 ms, that limit: the wait that must not happen |
| 5 | spec | "three test suites and Dialyzer": the precommit alias runs the tests and Dialyzer of three projects and Credo (`mix.exs:55-60`) | true | wording fixed |

The failure-path agent reproduced no defect: a recall that hangs fails the match at about 10 s with the 8,000 ms margin, the kill leaves no process (20 kills inside a scan over 1,000 real files), Credo reports nothing, and the full test passed in 97.9 s. No finding was a reproduced defect, so the loop ends after this round; the fixes above are wording and judgement.
