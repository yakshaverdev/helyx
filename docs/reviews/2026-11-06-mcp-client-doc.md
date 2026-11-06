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
| 1 | `Helyx.Watchdog.start/4` waits with no timeout in its handshake (`read_marker/4`, `watchdog.ex:324-336`) and in its error read (`read_to_exit/2`, `watchdog.ex:216-220`). The source process calls it directly, so a stalled start blocks the source past the 30 s start bound, and killing the source to enforce the bound removes the tools of every server | reproduced by reading the code: both `receive` blocks have no `after` | **open.** The round limit of `/ship` and its 45 minute limit are reached, so the doc is committed as round 3 reviewed it. The fix for the build: slice 8 adds an absolute deadline to the handshake and the error read of `Helyx.Watchdog.start/4` (an option, default none, so the bash tool and the harness providers do not change); at the deadline that launch closes its port and returns an error, and only that server fails. Slice 8 adds a test with a start that stalls before its marker while another server starts. The doc's "Bounds" row "server start" and slice 8 should name it when the slice starts. |

The loop ended at the round limit with one open finding. No round was done by hand.
