# 2026-10-03: simplification and file splits run

An orchestrate run in roll-forward mode, over the night of 2026-10-02. The owner asked for two things: build the open simplification tickets, and split every `lib` file over 400 lines. The orchestrator decided alone and capped the loops. This log records each decision it made.

## Merged

The core simplification plan (#297 to #308), before the night:

| Ticket | PR | Change |
|---|---|---|
| #305 | #309 | One set of cell rules for the live fold and the snapshot of the TUI. |
| #308 | #310 | A simpler `WallClockUpperBound` Credo check with the same reports. |
| #302 | #311 | Tables for the written-out malformed-input tests. |
| #297 | #312 | The session holds its subscribers. |
| #298 | #313 | The connected path is renamed from harness to provider. |
| #306 | #314 | The moduledocs of session, hands, and file are cut to a contract and a link. |
| #299 | #315 | The context request, and no normal exit of the provider process. |
| #300 | #317 | `Helyx.Provider.Loop`, OpenAI on it, and one turn path. |

The night:

| Ticket | PR | Change |
|---|---|---|
| #303 | #333 | The near-twin test plugins are folded. |
| #318 | #334 | The steer test waits for the steer answer before the gate releases the call (the race that PR 316 exposed). |
| #326 | #335 | The Perl program of the watchdog is in its own file. |
| #328 | #336 | The SSE parser is in `OpenAI.Events`. |
| #319 | #337 | The provider process drops a `:turn_start` during a live turn. |
| #323 | #338 | The codec and branch rules are out of `file.ex`. |
| #307 | #341 | The moduledoc of `provider.ex` is a contract and a link. The provider protocol is in `one-provider-path.md`. |
| #330 | #342 | Precommit runs on the host wait for each other (a host-wide `flock` inside the PID namespace). |
| #322 | #343 | The subscription state is in `Session.Subscription`. |
| #324 | #344 | `codex.ex` is split along its sub-protocols. |
| #332 | #346 | The OpenAI parser rejects a null or non-integer tool-call index. |
| #320 | #347 | `server.ex` split, part 1: structs, record, message order. |
| #327 | #348 | `tui.ex` is split into `Wrap`, `Composer` and `Transcript`. |
| #329 | #349 | The tool-call comment of the provider process is cut to its contract. |
| #331 | #350 | The test "steers during a tool run" uses a gate tool, not a 200 ms window. |
| #325 | #352 | `claude_code.ex` is split into `Mcp`, `Replay` and `Turn`. One tool-call admission, `HarnessIO.admit/4`, serves both harnesses. |
| #340 | #353 | The watchdog reads the not-started reason up to its exit status. On macOS a pipe read gives at most 512 bytes, so the reason was cut. |
| #345 | #354 | One id per OpenAI tool call, and Core rejects an empty tool-call id. |
| #339 | #355 | A program turn that the session drops ends in the provider process. |
| #321 | #356 | `server.ex` split, part 2: steering, stop, provider connection. |

## Closed without a merge

- #301 (one contract suite for the two harness providers): the shared suite saved no lines (+11), because the two fake programs speak different protocols.
- #304 (move the identical HarnessIO operations): already done by 8d5832e.

## Files over 400 lines

| File | Before | After |
|---|---|---|
| `lib/helyx/session/server.ex` | 1027 | 642 |
| `plugins/bundled/lib/helyx/provider/codex.ex` | 1145 | 608 |
| `plugins/bundled/lib/helyx/provider/claude_code.ex` | 1000 | 572 |
| `plugins/bundled/lib/helyx/tui.ex` | 841 | 396 |
| `lib/helyx/session/file.ex` | 643 | 385 |
| `plugins/bundled/lib/helyx/provider/openai.ex` | 485 | 198 |
| `lib/helyx/session.ex` | 453 | 381 |
| `plugins/bundled/lib/helyx/watchdog.ex` | 440 | 381 |
| `lib/helyx/session/provider_process.ex` | 416 | 398 |

Three files stay over 400 lines, at the targets their tickets set. Each has its `.credo.exs` entry. To bring `server.ex` below 400 lines, #321 says a person must decide on a `TurnLoop` module.

## Decisions taken alone

- **At most 3 workers.** The #303 merge precommit timed out twice at a host load of 125 on 8 cores. The orchestrator then capped the workers at 3, made the merge wait for a host load below 12, and filed #330 for a host-wide precommit queue.
- **#339 before #321.** Both change `server.ex`. The fix went first, so the second split moved fixed code.
- **#332 rejects a null index.** A null index took the implied index and lost a call. A missing index still takes it.
- **Codex at its usage limit.** At about 02:15 on 2026-10-03, Codex stopped until 2026-10-04 01:42. The gates of #327, #329, #331, #325, #340, #345, #339 and #321 ran as a fresh Claude Opus agent, read-only, with the same invariant sentence. The workers used the same stand-in inside `/ship`. Each review record says so.
- **#345: a harness `tool_request` with an empty id stops the provider process.** Before, the tool ran. Codex cannot reach it, and Claude Code reaches it only with a broken harness. AGENTS.md permits a larger failure for missing identity. A smaller unit, an "unmapped" answer in `HarnessIO.admit/4`, is a one-line change if the owner wants it.
- **#339: a reused program turn id is an accepted hole.** A late drop can end a new turn that uses the id of a dropped one. The contract already requires a new id, only the provider that breaks it is hurt, and the bundled provider makes a UUID. `one-provider-path.md` states the hole. The worker's other option (an interrupt in place of the drop) was not taken: the provider would get an interrupt for a turn that the session never showed.
- **#331: the switch test in `boundary_test.exs` keeps its 200 ms window.** Traced: both orders of the tool end and the model switch pass.
- **#340: the Codex provider drops the events of the whole chunk that holds a stop.** That is a behaviour decision, filed as #351 with `needs-triage`.

## PR 316 (owned by another agent, not changed)

PR 316 conflicts with master in `test/helyx/session/loop_test.exs`: it uses `Helyx.Test.Gated.Local`, which #300 removed. Its `ERL_FLAGS +sbwt none` exposed a steer race that was on master too. #318 fixed that race. The findings are a comment on PR 316. After #325, its overlap in `claude_code.ex` and `harness_io.ex` is small.

## Escapes

| Ticket | Gate | System change |
|---|---|---|
| #306 | round 1: 1 (a trim removed the connected steer rules) | review-checklist.md: a doc trim checks each kept sentence without the removed text |
| #307 | round 1: 1 (the context rule missed the message that a taken steer closes) | review-checklist.md: a doc sentence about a state change is checked against every writer of that state |
| #329 | round 1: 1 (the live turn had a third end, the next turn request) | none: the same class as #307 |

The #329 escape is the second of its class. The skill asks for a mechanical check on a repeat, but no test or Credo check can test a prose sentence against code. The checklist rule stays, and this log records the repeat. Every other ticket of the run had zero gate findings in round 1. The full rows are in `docs/reviews/escapes.md`.

## Process

- **Merge script.** `merge.sh` rebases, adds the escape row, waits for the host load, runs precommit with the slow tests (two attempts), checks that master did not move, and merges.
- **`.credo.exs` conflicts.** Almost every split changed the `allowed` map, so a resolver merges it by path key. Its first version read only the conflict hunks. On #325 a hunk split a key from its value, and the result did not parse. Precommit caught it, and nothing reached master. The resolver now merges the full staged versions, formats the map, and evaluates the file.
- **Two tests that failed only on macOS** were one code bug (#340) and one test that depended on the chunk boundary.

## Next

- #351: decide the drop unit of the Codex provider.
- `server.ex`: decide whether a `TurnLoop` module is worth it.
- #296 and PR 316: their owner.
