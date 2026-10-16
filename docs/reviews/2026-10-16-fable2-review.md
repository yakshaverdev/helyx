# Third review of 2026-10-16: Fable again, on the result

Base: master at 7e8084a5, after the joint review (`2026-10-16-joint-review.md`) and the first Fable round (`2026-10-16-fable-review.md`).

## Process

1. Claude Fable ran the review prompt again on master, as an outside check of the first two rounds. It found no defect that reaches a user. It gave 5 "Act on" and 18 "Consider" items, all deletions or simplifications.
2. Codex gave its own verdict on each item, with probes and mutations. Claude checked the verdicts and disputed one (C6). The rule did not change: fix every finding unless the debate shows it is wrong.
3. Four agents made the changes in parallel: hands, session file and lock, providers and tools, and the product with the TUI. Codex reviewed each slice.

**Deviation from `/ship`:** one commit on the fast path, as in the earlier rounds. The Codex review of each slice took the place of the review round. The slow precommit ran on the precommit host.

## Earlier verdicts that were wrong

- `CodingAgent.cut/1` was kept as "same size". It was `Helyx.Reason.text/1` written a second time; a probe of 64 inputs gave the same output.
- The millisecond clause of the bash timeout text was kept for fast tests. The time-limit tests need a load margin of whole seconds anyway.
- `Background.live` was kept as "equal size". A prototype with the place in the task entry was smaller and removed a synchronization.
- The first round moved the "only a tool call can run in the background" text into `Helyx.Tool`. The cleaner fix was to delete the outer fallback: a call outside the hands now exits, as `hold/1` does.

## Changes and removed capabilities

| Change | Removed capability |
|---|---|
| Retry of unconfirmed handles deleted (`Hands.Release`, `Helyx.Watchdog.Group`, the `:retry` release mode) | Recovery from an unconfirmed handle without a session restart. The refusal of later tool calls and provider starts now lasts until the session stops. No run or issue showed a recovered handle. |
| Integer caps on a reason before `Helyx.Reason` deleted (provider `:DOWN` in the hands, prepare Task crash, provider error terminal) | An early cap replaced a whole struct that held a huge integer by the marker. The walk of `Helyx.Reason` now replaces only the integer field. The digit, text, and log bounds stay. |
| `Tool.background/0` and `Tool.started/1` call the hands directly | The error tuple and the `ArgumentError` for a caller outside the hands. Both exit with `:noproc`. |
| The background place is a field of the task entry | None. |
| Guards and heap floor of the test-only read limits deleted | Rejection of invalid test values. No production limit changes. |
| The repair newline no longer counts toward the file limit | A file of exactly the limit with no last newline resumes once more, then is rejected. |
| The lock reads perl with port line mode | A CR before a line end in a perl diagnostic. The answer still needs the exact nonce. |
| Strict list check of `cancelled` in the Claude Code interrupt | Waiting for a result after a malformed `cancelled` field. The provider stops. |
| `session_header/1` requires the session id | A direct test call with no session id. |
| The replay cut of tool names at 64 deleted | Coercion to an unverified length. A program that rejects a long name fails the replay through the generic path. |
| `CodingAgent.cut/1`, `Bash.max_output_bytes/0`, the bash millisecond text, a duplicate Read test, `bench/transcript.exs` | The ready-made command for the transcript measurement; Git keeps it at 7e8084a5. |

The Codex slice reviews found two P3 items, both fixed:

- At the limit of 16, a second `background/0` call from a Task that held a place got the full-cap error, though it needs no new place. This was older than this change. The hands now leave the caller's own place out of the count, and a test covers the case.
- A TUI test could leave the mount branch lookup open at teardown in one valid order. The test now waits for that reply too.

With the retry gone, Core makes one release call for each handle. Bash still calls its own release twice (`:cancel` at its time limit, then `:deliver` from the hands), so its release stays safe to call again; `tool-resource-release.md` states this.

Tests: the compaction test uses the shared `SessionCase.await/3`. The TUI tests wait for each branch lookup, so a run prints no `erl_child_setup` lines (before: 13 to 22 per run). `Message.t()` types `stop_reason` with the closed set.

## Kept after the debate

| Finding | Reason |
|---|---|
| Tolerant decode of a bad resume id entry | A damaged optional label would make a valid chat impossible to resume. |
| Catalog cache in the slim shape | A split file can pair the data of one fetch with the ETag of another; a full body re-encodes unchecked integers; an envelope breaks the exact 16 MB case. |
| `retry-after-ms` and the HTTP-date form | The official OpenAI client reads both (`docs/research/retry-after.md`), and RFC 9110 defines the date form. No gateway run shows them. |
| Usage pre-check in `Helyx.Provider.Loop` | Without it, an invalid done acknowledges a held steer before Core sees it, and the sum hides an invalid usage. |
| Header `cwd` check in the read | The read uses new bytes. Without it, a resume can join the history of one project to the working directory of another. |
| `Message.big_integer?/1` | Building the capped copy doubled the heap on a 3 MB argument map. |
| Envelope check of a request-shaped turn notification | Without it, a broken completion gets `-32601` and the turn stays open with no end. |
| Rejection of an answer with both `result` and `error` | Without it, an answer that reports a failure counts as a success. |
| The reader's assistant count | Deriving it at each label makes a linear read quadratic. |

## Residuals

- A long tool name in a Codex replay is not verified against a real program.
- Not done: a packaged release run and live provider runs.
