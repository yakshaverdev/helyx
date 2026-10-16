# Joint codebase review and its changes, 2026-10-16

Tickets: #621 to #638 (done in this change), #639 to #644 (follow-ups, not done).

## Process

1. Two runners (Claude and Codex) reviewed the whole codebase on six lenses: the domain, the seams, too much concurrency handling, deletion, edge cases that no real input reaches, and reinvention.
2. The runners debated each finding until they agreed on one verdict. The rule: correctness first, then the fewest concepts, the least state and the fewest lines. A written rule (ADR, feature doc, checklist line) is a decision under review, not evidence. Each change names the capability that it removes.
3. Six agents made the changes in parallel, one slice each: session, withdraw, Core data, providers, tools, and TUI. Codex reviewed each slice diff against the agreed verdicts and the tickets, with its own probes.
4. Four agents scanned every test file for tautological tests. The runners debated the list, and Codex probed the disputed rows with mutations.

**Deviation from `/ship`:** the owner asked for one commit and a fast path. This change had no `/simplify` pass and no three-agent review round. The Codex review of each slice took the place of the review round. `mix precommit` ran with the slow tests.

## Slice reviews

All six slices: no findings. Author notes and their resolution:

| Slice | Note | Resolution |
|---|---|---|
| Withdraw (#630) | The MCP `notifications/cancelled` bookkeeping could shrink to the generic ack. | Keep. A tool request can be in transit to the session when the session handles an abort, and the program can then cancel before the late aborted result. The bookkeeping drops that result. |
| Withdraw (#630) | A provider that returns `{:cancel_tool, _}` now fails its turn. | Added to `docs/features/one-provider-path.md` as a removed capability. |
| Core (#634) | A file with an image block or a signature is rejected by the load rescue. | Correct. A probe showed that each case gives `:invalid_file` with no bytes changed and no partial result. |
| Providers (#636) | A tool call with an integer over the digit limit still gets a same-turn error result. | Correct. Item I removes only the raw-text continuation. The integer bound is a resource bound and stays. |
| Providers (#637) | Without `terminal(other)`, a bad enumerable gives `FunctionClauseError`. | Correct. A probe showed the generic failure: the provider stops, the turn fails, the session lives. |
| Providers (#628) | If the FIFO guard is removed, its test hangs the node instead of failing. | Accepted. The test is a direct regression check, not a bounded failure test. |
| Tools (#637) | A very long `workdir` now reaches the watchdog start. | Probed at 4,097 bytes to 1 MiB: each gives a bounded error result, and the command does not run. |
| TUI (#624) | The scrollback test after a failed turn now asserts that the view stays in the message. | Correct. With `message_end`, the open message becomes a cell at the same index. |
| TUI (#637) | A `tool_call` delta with no open message crashes in render, not in the fold. | Correct. The contract-break rule asks for a failure, not a failure at a given place. |
| Session (#629) | `persisting: false` shows the not-saved notice at mount for a session with no file. | Keep. The text is true in every case. A notice only on a change would miss a stop of saving before the first subscribe. The product always has a sessions directory. |
| Session (#629) | The lock-loss notice carries the running turn id. After a write failure, a lock loss gives no second notice. | Correct. Probed. |

## Tautological tests

Deleted or merged because the retained tests cover the same behavior: `message_test` tool output read-back, a duplicate Core boot test, a duplicate resume-not-found test, a duplicate provider stop test, two transcript and end-signal examples (merged), a duplicate OpenAI non-2xx test, a close-only Codex connect test, seven "one under the limit" cases, a UTF-8 cut test that the property covers, a duplicate stdin-cap test, a TUI notice read-back, a malformed-payload test (merged), two Read truncation copies of Text tests, and a TUI tool-call cut test (merged).

Strengthened: the Bash and Write missing-argument tests now assert the exact text. Before, a deleted validation clause still passed them, because the hands turn a crash into an error result.

Kept after a mutation probe:

- The `stop_reasons` set test: a value added to the set widens both the stream check and the file decoder, and only this test fails.
- The 30-minute idle default test: a changed default passes the other 108 tests of the module.
- The TUI rejection empty-cell assertion: a reject that also adds a notice fails only this assertion.

The checklist rule for numeric limits changed. Permanent tests cover the exact maximum and the first rejected value. A one-under case stays only when it covers a distinct case.

## Residuals

- A lock can die, and one append can happen, before the session handles the exit signal. The reader rejects a file broken in that window, and changes no byte.
- Hard-linked session files have separate lock paths, so two writers are still possible. The reader rejects the result.
- The stat-to-open race in Write and in the catalog cache read stays.
- Not done: a live harness approval run, an active-terminal resize failure, and a run on another OS.
