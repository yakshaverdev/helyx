# 2026-10-17 Review of #651, provider parity

The `/ship` review of the working tree on `ticket/651-provider-parity` (base 490b4413).

## Simplify

Four agents: reuse, simplification, efficiency, altitude.

- Fixed: `Codex.Tools.storable?/1` uses `HarnessIO.session_id/2`; the public `digest_hex/0` is gone. `Codex.Program` has one `fixed/1` for the digest input. `ClaudeCode.Program.stored_id/1` takes the id. The `mcp__helyx__` prefix is in `Mcp.helyx_name/1`. The `fresh?` test in the Codex compaction guard repeated `opened/1`. Dead defaults of a test helper.
- Not taken: a launch in `init/3` (orchestrator decision 1 moves it to the first turn); the prefix in the replay (decision 2: no rewrite of historical calls); the prompt in `{:compact, ...}` (a Core change); a digest of the isolation flags only; small test duplication.

## Round 1 (full)

Bounds sensor (base `origin/master`):

```text
bounds sensor: 28 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/codex.ex:58  WAIT  defp handshake(%State{port: port} = state) do
```

The failure-path agent probed `handshake/1`: it returns only when `due` is empty, an `initialize` error ends it, and an answer that is not due is dropped. No finding.

| # | Source | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Codex (high) | A prompt relaunch closed the old program and started the new one at once; the watchdog gives the old one up to 5 s, so two programs could run one harness session. Reproduced by Codex with a local probe. | Fixed: `HarnessIO.finish/1` ends the input and waits up to 1,000 ms for the exit; over the wait the program is stopped and the turn fails with `:program_not_ended`. Tests: `claude_code/prompt_test.exs` and `codex/prompt_test.exs`, "the new program starts only after the old one exited" (both fail without the fix), and the slow "an old program that does not exit fails the turn". |
| 2 | Codex (medium) | A stored Claude id with another digest is not resumed, but its `resume_usage` was still the cost mark of the fresh session. Reproduced by Codex. | Fixed: the mark is nil when the id is not resumed. Test: "the usage of a stored session that is not resumed is no cost mark". |
| 3 | Failure path | An interrupt of a compaction whose stored thread was lost (the fresh thread answers `no_history`) stayed pending; the next turn's end answered it, and the abort hung until the armed kill. Reproduced with a scratch test. | Fixed: `interrupted/1` answers a pending or sent interrupt at both ends. Test: "an interrupt of a compaction that opens a fresh thread is answered". |
| 4 | Standards, spec | The `Helyx.Provider` and `Helyx.Context` moduledocs named a program and claimed exactly the session's tools, which Codex does not give. | Fixed: every provider gives the model the turn's `system` and the session's tools within the named limits of ADR 0002. |
| 5 | Standards, spec | The feature doc named a `digest_hex/0` that simplify removed. | Fixed. |
| 6 | Standards | `content_item/1` had clauses for item shapes that Helyx never writes. | Fixed: only `inputText` items give text. |
| 7 | Spec | The Claude moduledoc said the user's config is off; managed settings stay. | Fixed. |
| 8 | Standards | `Items.tool_call/1` keeps the generic item mapping for a `dynamicToolCall` with a name that is not a string or arguments that are not an object. | Not changed: the generic mapping is the existing path of every item type, not a new fallback; the `item/tool/call` of such a call fails the Core check. |
| 9 | Standards | `Mcp.helyx_name/1` keeps a name without the prefix. | Not changed: the line comes from the program, a boundary; a crash there is not the generic failure path. |
| 10 | Spec | The research note did not check a hook before each model call for Codex. | Accepted: decision 4 is research only; the note says "Not checked". |
| 11 | Spec | The branch is not rebased on #649 (merged as e7543466), and #652 is open. | Accepted: the orchestrator rebases at the gate (decision 8). |

The spec agent judged the deviation from decision 2 justified: both programs take a new prompt on a resume (research note), so the prompt is not a fixed value of the harness session; an in-process check at each turn start replaces the program, and the flag digest rejects the old stored ids.

The fix of round 1 touches more than one code file and adds functions, so round 2 is a full round.

## Round 2 (full)

Fix of round 1: 98 code lines (`lib/`, added plus removed) in six code files, with new functions, so a full round. Simplify on the fix: `HarnessIO.finish/1` and `close/2` share `end_input/1`; `ClaudeCode.Program.ensure/2` has a clause for no program. Not taken: launching the new Codex program while the old one exits (two programs at once is the defect of round 1); a shorter sleep in the order tests (a shorter one shows less).

Bounds sensor (base `origin/master`, which now holds #649, so the files of #649 show as changed): `codex.ex:58 WAIT handshake/1` again; `session/file/reader.ex:62`, `model_info/catalog.ex:61`, and `openai.ex:189` are #649 code, not this change. Codex reviewed against 490b4413.

| # | Source | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Codex | Approve; no material finding. | — |
| 2 | Failure path | No finding. Probes: a Codex old program that ignores the end of input fails the turn with `:program_not_ended` after 1,001 ms and starts no second program; an interrupt during a Codex relaunch gets one answer. | — |
| 3 | Spec | ADR 0002 said program work ends at the prompt restart; an old program finishes a running program turn after the end of input and can exceed the wait. | Fixed: the row names the wait and `:program_not_ended`. With exact tools the program has no background work, the main cause of program turns. |
| 4 | Standards, spec | The comment and the feature doc cited "Claude exited 0.65 s after the end of input"; the note measures that from a `result`. | Fixed: they cite the close times 615 and 628 ms of the "Processes" section, and state that Codex is not measured, and that the wait is part of the reply bound. |
| 5 | Standards, spec | The Codex `:program_not_ended` path had no test. | Fixed: slow test in `codex/prompt_test.exs`. |
| 6 | Standards | Two comments were not wrapped; the Claude `finish/1` error match took any value. | Fixed. |

Round 2 reproduced no defect, so the loop ends.

## Precommit

The first run failed on two Credo findings: the complexity of `Items.tool_result/1` (10, max 9) and the nesting of `messages/1` in the conformance test. Fixed: `failed?/1` and `block/2` are new functions, with no change of behaviour. Every test and Dialyzer passed in that run.

## Gate finding (Fable review, after the rebase on #649, #652, #551, #620)

[medium, reproduced] The handles of a replaced program stayed held until the provider process ended: each launch holds `{:watchdog, pid}` and `{:command, group}`, and nothing dropped them at a relaunch. A probe with three prompts gave six held handles and one live watchdog. The same held for the lost-session relaunch on master.

Fixed at the one point that every relaunch passes: `HarnessIO` releases the groups of the program before at each launch, with the provider's own `release/3` and a 500 ms deadline, and drops the confirmed handles with `Helyx.Tool.unhold/1`, new in Core. A handle that the release does not confirm stays held. Tests: "the hands hold the handles of one program across relaunches" in `claude_code/prompt_test.exs` and `codex/prompt_test.exs` (both fail without the fix with six handles), the lost-session assertion in `claude_code/compact_test.exs`, and "a handle that the tool let go of gets no release" in `test/helyx/session/hands_test.exs`. The three deletion notes of the review are not taken: the first changes the resume of a program that was never written to, and the other two need a check that is not part of the fix.

### Reduced round (spec, failure path)

| # | Source | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Spec (medium) | `unhold/1` took an improper list, and the hands crashed at `--` (`[1] -- [:a \| :b]` raises). | Fixed: `unhold/1` matches `false = List.improper?(handles)`, so the caller fails. |
| 2 | Spec (low) | The 500 ms row did not name the lost-session relaunch, which runs in a turn with no reply bound, or the rest of the 2,000 ms bound. | Fixed: the row and the comment name both. |
| 3 | Failure path | No defect. Probes: a group that ignores TERM stays held and the launch took 531 ms; a failed launch after the release leaves its watchdog held until the provider stops; 20 lost-session relaunches took at most 99 ms. | — |
| 4 | Failure path (nit) | An `unhold([])` call when nothing was confirmed. | Fixed: no call. |
| 5 | Failure path (note) | An unconfirmed command group gets a TERM again at each later launch, not only at the end. | Accepted: it needs a group that ignores TERM and a reused id. |

Precommit after the fix failed on two Credo findings: `length/1` in the guard of `unhold/1` (now `List.improper?/1` in the body), and `claude_code.ex` at 508 lines over its 507, because the format split the `with` line of the rebase (a comment is now one line). Every test and Dialyzer passed in that run.
