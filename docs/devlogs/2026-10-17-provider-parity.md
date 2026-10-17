# 2026-10-17 Provider parity (#651)

## Done

- Research runs on Claude Code 2.1.302 and codex-cli 0.163.0 (`docs/research/provider-parity.md`): the prompt flags, the isolation flag sets and their residuals, the resume behaviour of the prompt, the thread open times, and one edit-quality pair. Five real turns of the ten that the ticket allowed.
- ADR 0002 revision: the rule and the one list of trade-offs and limits. ADR 0007, the `Helyx.Provider` and `Helyx.Context` moduledocs, and `docs/features/long-lived-harness.md` follow it. The design is `docs/features/provider-parity.md`.
- Claude Code: `--tools=`, `--setting-sources=`, `--strict-mcp-config`, `--system-prompt=` with the snapshot off, and the prompt in the control request `initialize`. The program starts at the first turn. A new prompt at a turn start relaunches with a resume. `ClaudeCode.State` and `ClaudeCode.Program` are new modules, so `claude_code.ex` went down from 540 to 507 lines.
- Codex: the isolation flags and `baseInstructions`. The thread opens at the first turn. A new prompt starts a new program that resumes the thread. `Codex.Wire` and `Codex.Program` are new modules.
- The by-name filter of the file tools (`HarnessIO.harness_tools/1`) is gone. The stored id of both providers is `<id>#<digest>` of the fixed flags (and the Codex tools), in `HarnessIO.session_id/2`.
- A conformance test runs two `bash` calls, one with an error, on each harness fake and on the API fake, and compares the events and the snapshot. It found two parity bugs: a Codex `dynamicToolCall` gave the tool name `dynamicToolCall` and the item JSON as the result, and the Claude transcript had the `mcp__helyx__` name. Both are fixed.

- `/ship`: two review rounds (`docs/reviews/2026-10-17-provider-parity.md`). Round 1 found three defects: a prompt relaunch started the new program while the old one still ran (now `HarnessIO.finish/1` waits for the exit), a stored Claude id that is not resumed kept its cost mark, and a Codex interrupt of a compaction that opened a fresh thread got no answer. Round 2 found no defect.
- Gate finding after the rebase: the hands kept the handles of every replaced program. `HarnessIO` now releases the groups of the program before at each launch and drops the confirmed handles with the new `Helyx.Tool.unhold/1` (ADR 0004, revision of 2026-10-17).

## What broke

- A counter variable `a` in a fake script clashed with the fake's own `for a in "$@"` loop and ended the fake with status 1.
- A test that read `args.N` before the program wrote it: the close waits for the exit, so the test now closes first.
- A call of `precommit.sh --help` started a full run, because the script takes no options; the 120 s bound of the foreground command ended it.

## Next

- #649 and #652 were not merged when this work started; the orchestrator rebases at the gate.
