# 2026-10-15: #566 A background sub-agent and the usage

## Done

- Three probes on `claude` 2.1.296 (haiku) with a background `Agent` call: an interrupt while the main loop's turn ran, an interrupt after the turn's `result`, and a sub-agent that ran to its end. Facts in `docs/research/claude-code-stream-json.md`, "A background sub-agent and the totals".
- `docs/features/usage-and-limits.md` states both gaps as known ceilings, accepted by the owner in the triage of #566.

## Found

- An interrupt that stops a background sub-agent cuts its call in flight, and that call is in no total. When the main loop's call did not stream at the interrupt (run B), the next cost is known and too low. When it streamed (run A), `aborted_streaming` makes the next cost nil anyway. No line carries the counts or the cost of the cut call. The sub-agent gets a `user` line `[Request interrupted by user]` with `parent_tool_use_id`, and no `stream_event` of a sub-agent comes.
- `modelUsage` holds the input counts of every call that ended, sub-agent calls included, added up over the process. Its output count grows with them, but no line gives a sub-agent call's final output count to check it (Codex, round 1). So the token sums of gap 2 are on the wire. A rule that takes them from the `modelUsage` difference is possible; the owner did not decide it.
- `task_notification` `usage.total_tokens` is near the context of the sub-agent's last call, not a sum.

## Next

- The owner decides whether the token sums take the `modelUsage` difference (gap 2).
