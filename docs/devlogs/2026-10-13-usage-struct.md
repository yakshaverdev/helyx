# 2026-10-13: The usage struct and the serving side (#557)

Step 1 of `docs/features/usage-and-limits.md`, "Delivery".

## Done

- Ran the probes of "Per provider" first, with small real model calls in temporary directories. Results are in `docs/research/codex-app-server.md` and `docs/research/claude-code-stream-json.md` (sections of 2026-10-13).
  - Codex cache writes: `cacheWriteInputTokens` was 0 in 3 turns, so the fact stays not verified. The cost is nil until #559 anyway.
  - Claude Code alias: `modelUsage` has one key, equal to `message.model`. The rule of the doc holds.
  - Codex sub-agent: the parent's `last` does not include the child's calls. This is the known ceiling of the doc.
  - OpenCode gateways: not run. The machine has no OpenCode API key. The mapping follows the doc.
- Added `Helyx.Usage` with `add/2`, `valid?/1`, and the wire guards. `Message.usage` is `Helyx.Usage.t() | nil`.
- `Stream.check/1` and the codec check the struct bound. A bad or old usage in a file decodes as the unknown usage; a missing key decodes as nil.
- `Loop` keeps the usage of a call with no `message_end` (a held steer) and adds it to the next message.
- Providers: OpenCode maps the usage chunk (a value outside the wire bound is a bad chunk). Codex sums `tokenUsage.last` since the last `done` and keeps the sum over a turn with no `done`. Claude Code has a new `Meter`: the sum of the `result` lines and the cost as the difference of `total_cost_usd`.
- Moved `ClaudeCode.Interrupt`, which owns its own struct, to its own file. `claude_code.ex` stays at 556 lines, the same as on master, and the `.credo.exs` entry does not change.

## What broke

- The first review round found that a resumed `claude` program reports `total_cost_usd` over the whole harness session. The rule "0 for a new process" of the feature doc did not hold, so the work stopped before the commit.
- Owner decision: derive the mark of a resumed program from the session file, and store nothing new. Core gives the provider the sum of the usages since the resume id (`:resume_usage`); a cost that is not known, or a total below the sum, gives cost nil. The feature doc and the research notes say so now, with the probe facts and the OpenCode probe that did not run.
- The second round found that a replayed line's `result` has an empty `modelUsage` (a new probe), and the round 1 fix made an empty map give cost nil. Every fresh program that replays history lost the cost of its first `done`. The fake's replay line had no usage, so no test saw it. Fixed: an empty map has no entry to price; the fake has the real shape.
- The third round found that a call cut by an interrupt while it streamed is in no total (`aborted_streaming`). By owner decision, `Meter` sets the flag for it; a fourth, reduced round reviewed the fix.
- The second round also found that a program turn that the session drops while it is busy (#240) is counted at the first `done` after a resume. A fix needs a record on disk, which the owner rule does not allow, so the feature doc states it next to the accepted limit.

## Assumptions

- The flag of "Per provider" (a turn with no `done` makes the next cost nil) is not built for Codex and the OpenCode `Loop`. Their cost is always nil until #559, so the flag has no effect yet. #559 adds it with the price math.
- A relaunch after a lost session starts a fresh harness session, so its meter starts at mark 0 (test: "a lost resume" in `meter_test.exs`).

## Next

- Open from review round 4: a sub-agent call cut by an interrupt (`aborted_tools`) is in no total, and the next `done` gets an exact cost. A rule needs a sign of a running sub-agent; every `aborted_tools` as cut would also mark a plain tool interrupt.
- #559: Codex and OpenCode cost, with the flag (the owner adds it to #559).
- A recorded OpenCode usage chunk of each gateway, when a key is available.
