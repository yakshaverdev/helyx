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
