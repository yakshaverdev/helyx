# Review: the connected Claude Code provider (#200)

Base: `origin/master` at `da46d28`. Rounds: the first and complete round, then full rounds after each fix (see each round for the counts).

## Change

`Helyx.Provider.ClaudeCode` is now a connected harness provider (ADR 0007). `harness_init/3` starts one `claude` for the session, with no `-p`, with `--session-id=<new uuid>` or `--resume=<id>`, under the watchdog with open input and a TERM grace of 5,000 ms. A turn is one user line with a `uuid`, and it ends at a `result` with `queued_turn_count` 0. An interrupt is the control request `interrupt` with `cancel_queued: true`. A close is the end of input, then the exit. `stream/3` answers `{:error, :connected}`. The decisions are in `docs/features/long-lived-harness.md`, section "Built in #200".

Invariant: one `claude` program serves the session and is never started again by a close; an interrupt answers `:ok` only when the turn is over in the program (the success response and the turn's `result`, or a response whose `cancelled` list holds the turn's `uuid`), and any other answer or a missed bound stops the program through the Core loop. The interrupt waits for the program's first `init`, and after a replay for `started` of the turn's line; before that `started`, a `result` is of a replay line and does not end the turn. A `result` with `queued_turn_count` above 0 does not end a turn, also with a pending interrupt, by the rule of the ticket; a count that is not a non-negative integer stops the program with `{:error, :no_queued_turn_count}`. The wait for a count of 0 has no bound of its own (the row "submitted: unbounded"), and an abort ends it. Entry points: `harness_init/3`, `harness_request/3` (turn, interrupt, close), and `harness_info/2` (program stdout and exit). Documented exceptions: stderr is dropped (row "stderr"); after an abort that left no assistant message, the next prompt holds the aborted user message again, as before #200. Open: none found.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

The sensor gave the same line in every round.

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Fixed: `relaunch/2` builds a new `State` instead of a reset of eight fields by hand.
- Fixed: one `errors/1` helper for `lost?/2` and `terminal/2`.
- Fixed: `uuid/0` uses one binary match.
- Fixed: the failed start returns the error and does not close the port by hand; the keeper of `HarnessIO.keep_port/1` closes it.
- Fixed: a comment on the `State` fields `deadline` and `done?`, which only `Helyx.HarnessIO` writes.
- Fixed (tests): `run_direct/2` returns the actions; `stop_of/2` is gone.
- Skipped: a shared release helper with Codex (Codex must not change in #200); a lazy replay encode (off the hot path); a shorter TERM grace in the test (the ticket asks for the 5,000 ms grace under test); `split_prompt/1` per turn (O(n) and shared).

### Standards

- Fixed: the interrupt state is a struct, `Interrupt`, not a bare map.
- Fixed: the review record did not exist yet (this file).
- Skipped (judgement calls): the name `@lost`; the `<<0>>` end of input shared with Codex; the poll of the session state in `wait_for_no_harness/2` (no event exists for it).

### Spec

- Fixed: an interrupt before `started` answered `{:error, :not_started}`, which stopped the program (see rounds 2 to 4 for the final mechanism).
- Fixed: a `can_use_tool` request gets `allow`, as the row "the harness's own requests" says.
- Fixed: a replay result is `success`, `num_turns` 0, and no `terminal_reason`; a turn result with `num_turns` 0 still ends the turn.
- Fixed (docs): the stderr drop and the time of `{:harness_session, ...}` are stated.
- Reported: the interrupt does not require `terminal_reason` `aborted_*` (see "Decisions").

### Failure path

- Fixed: a close while a resumed program reported its session lost started a new program and never answered the close. Now a `:lost` terminal during a close waits for the exit, which answers the close. Test: "a close while a resumed program reports its session lost starts no program".

## Round 2 (full)

Fix diff: 80 code lines in one file; it added the `Interrupt` module and functions.

- Simplify: fixed a test that built a result by string replace, a fixed sleep replaced by a gate file, and the moduledoc wording. Skipped: one close path for all terminals (a line over the cap during a close still stops at once, which is faster than the close bound).
- Standards: fixed the Claude Code section line that still required `aborted_*`, the `%Interrupt{}` pattern in the response clause, the name `resume_interrupt/1`, and STE wording.
- Spec: fixed the stderr row of Bounds, a doc claim with no research fact ("`started` comes at once"), and a response whose `cancelled` holds the turn's `uuid`: no `result` comes for it, so the interrupt waited until the armed kill.
- Failure path: 1 finding, fixed. The interrupt used the capabilities of an earlier `init` and was written before the turn's own query started; the program could cancel the line and write no `result`. Second finding on the interrupt mechanism: round 3 changed the mechanism.

## Round 3 (full)

Fix diff: 52 code lines in one file; it added `cancelled?/2` and removed the wait for `started`. Mechanism: the interrupt writes at once when the capabilities are known, and it ends on the response and the `result`, or on a response that cancelled the turn's line.

- Simplify: no required cleanup; four nits skipped.
- Standards: STE wording fixed. Skipped: a test helper for the started check.
- Spec: fixed a pending interrupt that could wait for the armed kill when the turn's `result` came before the interrupt was written; fixed the moduledoc. The review record (this file) was still missing then.
- Failure path: 1 finding, fixed. After a replay, `cancel_queued` could drop queued replay lines (inferred, not observed), and the program would keep a harness session with part of the history, and the next turn would go to that live program. The interrupt now waits for `started` of the turn's line after a replay. Test: "after a replay waits for the start of the turn's line".

## Round 4 (full)

Fix diff: 33 code lines in one file; it added the field `replay?` to `Turn`.

- Simplify: fixed `lines != []` in place of an `IO.iodata_length/1` check, and the moduledoc wrap. Skipped: a derived `replay?` (it needs the replay lines kept in the state), a wait for `started` in every turn (a behaviour change), and a gate helper in the tests.
- Standards: no hard violation. Fixed: STE of a comment, the Claude text of the stderr row moved out of the overflow column, and a long sentence in "Built in #200" split and marked as inferred.
- Spec: 1 code finding, fixed. A `result` of a replay line that the replay skip does not match (for example an error result) ended the turn, or answered a waiting interrupt with `:ok`, while the program still held the turn's line (inferred, not observed). Now a `result` before `started` of the turn's line after a replay is skipped. Test: "a result before the start of the turn's line after a replay does not end the turn". Docs fixed: the moduledoc listed only one `:ok` case; the `init` wait is for any program, not only a fresh one; "`started` comes after the whole replay" is marked as inferred; the risk is the next turn on the live program, not a resume; the Claude Code section lists the result-before-write `:ok`. The record now states the code revision of the manual run.
- Failure path: no findings. Three throwaway tests: an interrupt in the middle of a replay, a lost session with a pending interrupt, and a replay cut by the cap. All held.

## Round 5 (full)

Fix diff: about 16 lines in one code file (4 code lines, the rest moduledoc and a comment), counted as full because the count is near the limit.

- Simplify: reuse and efficiency clean. Simplification and altitude: the shape skip of a replay `result` (`success`, `num_turns` 0, no `terminal_reason`) and the new skip before `started` were two rules for one fact. A run of the real program showed the replay `result` before `started` of the turn's line (research note, #200 section), so the shape clause is deleted (6 lines). The `:ok` case for a result before the interrupt write is now stated once in "Built in #200".

- Standards: no hard violation. Fixed: STE of the moduledoc and two comments, "(inferred)" on the comment of the replay wait, and STE of two doc lines.
- Spec: no new path that breaks the invariant. Fixed: a test for a waiting interrupt and a failed replay `result` before `started` (the test "after a replay waits for the start of the turn's line" now sends it, and checks that the interrupt is written). The manual run was made again on the final code (see "Manual run"). Recorded: a `result` of the turn's own line before its `started` is skipped too (inferred risk, see "Decisions").
- Failure path: 1 finding, fixed. After a replay, a program that writes no `command_lifecycle` lines never ended the turn: the skip of replay results waits for `started`. This is the second finding on the replay wait, so the fix is in the mechanism: the skip and the interrupt wait both need `started`, and after a replay an `init` without `msg_lifecycle_v1` stops the program with `:no_msg_lifecycle`. Test: "a replay to a program without msg_lifecycle_v1 stops it".

## Round 6 (full)

Fix diff: about 12 code lines in one file: the `init` clause of `translate/2` and a new `after_init/1`. Full because of the two-findings rule.

- Simplify: reuse and efficiency clean. Fixed: the `if` with a nil check became `after_init/1` with a `%Turn{replay?: true}` clause; the test history and the failed replay result are helpers (`replay_history/0`, `replay_failed/0`). Skipped: the altitude proposal to require `msg_lifecycle_v1` at every `init`, also with no replay. In #200 only the replay needs `started`; the steer (#202) decides its own need.

- Standards: no hard violation. Fixed: STE of the moduledoc and comments (actors named, a long line wrapped), the comment of the skip now names the turn's own `result` too, and the link from `msg_lifecycle_v1` to the lifecycle lines is marked as inferred. Skipped: an inline `replay_history()` call.
- Spec: no path that breaks the invariant. Fixed: two doc lines. The Claude Code section said a `result` before the interrupt write always gives `:ok` (not after a replay), and "Built in #200" said the interrupt writes "at once". Recorded again: an older `claude` without `msg_lifecycle_v1` can no longer replay (see "Decisions").
- Failure path: 1 finding, fixed. After a replay, a program that writes no `init` line never ran the capability check, and the skip dropped every `result`, the turn's own too. This is the third finding on the replay skip, so the check moved into the skip itself: while `replay?` is true, a `result` is skipped only when an earlier `init` listed `msg_lifecycle_v1`; any other `result` stops the program with `:no_msg_lifecycle`. `after_init/1` is gone. Test: "a replay to a program with no init line stops it". The fake of the test "a lost harness session starts a fresh program with the transcript replayed" wrote the replay `result` before any `init`; the real program writes the `init` first (research note, #200 section), so the fake now does too.

## Round 7 (full)

Fix diff: one code file; `after_init/1` removed, the check moved into the `result` clause. Full because of the two-findings rule.

- Simplify: reuse, efficiency, and altitude clean. Fixed: the two `replay?` branches are one branch with `state.caps || []`. Skipped: a `lifecycle?` field in place of the list scan (the list is short), and an inline `replay_history()` call.
- Standards: no hard violation. Fixed: STE of three comment and moduledoc lines, a blank line before the close paragraph of the moduledoc, a test name that matches its setup, and a long bullet of "Built in #200" split in three. Skipped: the `if` inside the `cond` branch (the simplify merge chose it), and an inline `replay_history()` call.
- Spec: no path that breaks the invariant. Fixed: the order of replay results before `started` is observed for one replay line only; the docs and a comment now mark it as inferred for more lines.
- Failure path: no findings. The three named reproductions and two more cells through the fake program held. Open design edge, not reproduced: a program that lists `msg_lifecycle_v1` and never sends `started` for the turn's line leaves the turn open until an abort (see "Decisions").

## Round 8 (reduced)

Fix diff: 7 lines in one code file, all in comments and the moduledoc; one test renamed. No function, arity, or return shape changed, and no finding on a mechanism. Reduced: spec and failure path.

- Spec: no path that breaks the invariant through a replay result. Fixed (docs): only replay user lines get a `result`, and the observed order is for one replay user line. Reported: a `result` with `queued_turn_count` above 0 ends the turn when an interrupt is pending, and does not end it otherwise (see "Decisions").
- Failure path: 1 finding, not changed in code. A `result` with `queued_turn_count` above 0 after `started` does not end the turn when no interrupt is pending, so the turn waits for an abort. The ticket states this rule: "The turn ends at `result` with `queued_turn_count` 0". Every observed `result` had `queued_turn_count` 0 (research note, section "Verify before implementation"), and no test sends another value. A change of the rule is a design decision for the owner, so it is in "Decisions". The invariant of this record now states the rule.

This round changed only Markdown, so no further round is needed.

## Precommit

`mix precommit` failed in the root at Credo strict: `translate/2` for `result` has cyclomatic complexity 10 (max 9), `plugins/bundled/lib/helyx/provider/claude_code.ex`. A fix moves the replay skip into its own `translate/2` clause for `%Turn{replay?: true}` (a resumed program never replays, so the lost-session check need not come first). With it, the two provider test files pass (39 tests) and Credo finds no issues in the file. The fix is not reviewed: the owner's new limit of three review rounds ended the loop. So it is not in this commit. It was open after the first commit.

## Round 9 (reduced)

After the owner's decisions on #200, the fix is applied. Fix diff: 22 lines in one code file; the replay skip moved from a `cond` branch into its own `translate/2` clause, and `stream/3` answers `{:error, :connected}` as the Codex provider of #201 does. Reduced by the owner's order: spec and failure path.

- Spec: no code defect. Fixed: the record still named `:connected_only`, and the test count now names the two test files.
- Failure path: no findings. The replay clause runs before `lost?/2`, but `replay?` is true only for a program with no `resume`, and `lost?/2` needs one, so no `result` matches both. Four probes held: a lost session then a program without `msg_lifecycle_v1`, a lost session then a failed replay `result`, a replay `result` with the lost text, and an interrupt pending across the relaunch.

No defect was reproduced, so the loop ends.

## Codex round 1

1 finding, confirmed and fixed. A success response to the interrupt with `still_queued` missing, `null`, or of another type was read as an empty queue, so the interrupt could answer `:ok` and keep the program. ADR 0007 says that Helyx stops the program when the program cannot confirm that no queued work remains. Now only `still_queued` exactly `[]` goes on; any other value answers `{:error, :still_queued}`. Tests: a missing value, `null`, a non-list value, a missing `response` object, and a non-empty list. The failure-path axis should have caught this: the program output is a boundary, and the checklist asks for every input shape at it.

## Round 10 (reduced)

Fix diff: 8 lines in one code file, in the `control_response` clause of `translate/2`. Reduced by the owner's order: spec and failure path.

- Spec: 1 defect, fixed. A `result` with `queued_turn_count` missing, `null`, a string, or a float ended the turn, as if the count were 0.
- Failure path: 2 defects, reproduced and fixed. The first is the same as the spec defect. The second: a pending interrupt that was not written yet answered `:ok` on a `result` with `queued_turn_count` 2, because the interrupt branch came before the count check. Both are on the check of `queued_turn_count`, so the fix is in one place: `turn_result/2` ends the turn only at exactly 0, keeps it open at a positive integer, and stops the program with `{:error, :no_queued_turn_count}` on any other value. The count comes before the interrupt. Tests: a missing, `null`, string, and float count; a pending interrupt and a count of 2. The fake error result of the error-cap test now has `queued_turn_count` 0, as the real program writes (research note, section "Verify before implementation").
- Other fields checked, fail safe: `cancelled` that is not a list, `init.capabilities` that is not a list, an unmatched `request_id` or `command_uuid`, and a `subtype` or `is_error` other than success.

## Round 11 (reduced)

Fix diff: about 25 lines in one code file; `turn_result/2` added. Reduced by the owner's order: spec and failure path.

- Spec: 1 doc defect, fixed. The invariant of this record did not state the round 10 rule for `queued_turn_count`. No code defect.
- Failure path: no findings. Checked for another field whose absence reads as a safe state: `cancelled`, `init.capabilities`, `terminal_reason`, `lost?`, `parent_tool_use_id`, `request_id`, `command_uuid`, `subtype`, `is_error`, and chunk order. All fail safe.
- Not verified, not a defect: a missing `parent_tool_use_id` reads as the main loop. A sub-agent `result` with count 0 and without that field would end the turn. The research note marks this field "not verified" for sub-agents.
- The loop ends: no code defect was reproduced.

## Manual run with the real program

2026-09-27, `claude` 2.1.283, model `haiku`, through a Helyx session (`Helyx.Core` with `Helyx.Provider.ClaudeCode`, `Session.prompt/2`, `Session.abort/1`). Script: `.scratch/manual_claude.exs` (not committed). Code: commit `0bcff46`, the code of round 8, which changed only comments after this run. This run replaces an earlier run on older code of this branch, which gave the same kind of results.

- Turn 1, "Reply with just OK1.": 3,452 ms, answer "OK1", stop reason `end_turn`.
- Turn 2, "Reply with just OK2.": 1,268 ms, answer "OK2", on the same harness process. The `claude` pids of this session (42858, 42859) were the same before and after.
- Turn 3 asked the model to run `python3 -c "import time; time.sleep(37)"` with `Bash` in the foreground. When the sleep ran, `Session.abort/1` returned after 7 ms, and the turn ended with `aborted`. 1 s later the sleep processes were gone, and the harness process and the `claude` pids were the same.
- Turn 4, "What did I ask you to reply in my first message?": the answer was "You asked me to reply with just OK1.", on the same harness process and pids.
- At the session end the pids 42858 and 42859 were gone. The two other pids that the `pgrep` pattern matched (30917, 46534) stayed; they are programs of other sessions on the machine.

The `Bash` tool refused a standalone `sleep 37`, so the run used the python sleep (research note, #200 section).

## Decisions

The owner decided each item below on #200. The feature doc states them (Claude Code section).

- Kept: a `result` with `queued_turn_count` above 0 does not end a turn (the ticket rule). With no pending interrupt, such a turn waits until an abort, and the abort's interrupt then waits until the interrupt bound, because an idle program writes no `result`. Since round 10, this holds also with a pending interrupt. No run showed a count above 0. The other choice is to end the turn at any `result` after `started`.
- The interrupt answers `:ok` on the turn's `result` with any `terminal_reason`, not only `aborted_*`. The ticket names `terminal_reason`. A turn that ended just before the interrupt gives `completed`, and an idle program writes no other `result`, so a check for `aborted_*` would wait until the armed kill and stop the program.
- `stream/3` of the Claude Code provider is gone; it answers `{:error, :connected}`, as the Codex provider of #201 does.
- A program that lists `msg_lifecycle_v1` and never sends `started` for the turn's line (for example, it rejects the line) leaves the turn open until an abort; the interrupt then waits for `started`, and the interrupt bound stops the program. Not observed.
- After a replay the provider needs `msg_lifecycle_v1`, and it skips every `result` before `started` of the turn's line. A `result` of the turn's own line before its `started` was not observed; if it comes, only an abort ends the turn, and the interrupt bound stops the program.
- After a replay the interrupt waits for `started` of the turn's line; a replay that takes longer than the 2,000 ms interrupt bound stops the program (the fresh harness session is then not resumed).
