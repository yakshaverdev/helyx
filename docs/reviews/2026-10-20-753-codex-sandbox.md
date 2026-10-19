# Review: the caller picks the Codex sandbox and approval policy (#753)

Scope: the working tree against the branch base `ad7e578b`. Files: `plugins/bundled/lib/helyx/provider/codex.ex`, `plugins/bundled/lib/helyx/provider/codex/program.ex`, `plugins/bundled/lib/helyx/provider/codex/state.ex`, `plugins/bundled/test/helyx/provider/codex/sandbox_test.exs`, `docs/features/long-lived-harness.md`, `docs/research/codex-app-server.md`, `docs/adr/0007-harness-process-per-session.md`.

Invariant: every Codex `thread/start` and `thread/resume`, also the resume in a new program after a prompt change, sends exactly the `sandbox` and `approvalPolicy` that `init/3` accepted from the `:provider_opts` keys `codex_sandbox` (`read-only`, `workspace-write`, `danger-full-access`; default `danger-full-access`) and `codex_approval_policy` (`untrusted`, `on-request`, `never`; default `never`), with `approvalsReviewer: "user"`. Any other value fails `init/3` with `{:invalid_option, key}`.

## Decision

- The triage comment of #753 holds the decision. The values are the strings of `SandboxMode` and `AskForApproval` in the schema of codex 0.163.0, probed with `codex app-server generate-json-schema` (no thread, no turn, no network request). The research note has the probe.
- The `granular` object of `AskForApproval` is refused: Helyx answers every approval request with an error, so a granular policy adds no case that the three strings do not give. Stated in "Out of scope" of the feature doc.
- The `codex_` prefix: the session gives `:provider_opts` to every provider, and the prefix names the provider that reads the key, as the `openai_` app env keys of `helyx_plugins` do.
- `approvalsReviewer: "user"` on every thread open: a user's `approvals_reviewer` config (`auto_review`) would get an approval request in place of Helyx and can accept it. The schema has the field in the stable `ThreadStartParams` and `ThreadResumeParams`, which have no `additionalProperties`. With the default policy `never` no approval request comes, so the default path does not change in what the program does.
- `Program.options/1` wraps `HarnessIO.options/1`, so `codex.ex` (Credo file length cap 481) does not grow.

## Proof (author)

- Red: the first run of `sandbox_test.exs` gave `3 tests, 3 failures`: `Helyx.Provider.Codex.Program.options/1 is undefined or private`; the `thread/start` params had no `approvalsReviewer`; and the prompt-change test waited for an `initialize` answer of run 2 that the test did not script (a test fault, fixed with `initialize(bin, 2)`).
- Green: `sandbox_test.exs`, `turns_test.exs`, `no_state_test.exs`, `env_test.exs`: `22 tests, 0 failures`. All of `test/helyx/provider/codex`, `conformance_test.exs`, and `harness_config_test.exs`: `111 tests, 0 failures (9 excluded)`.
- Mutation (after round 1): with `params/1` merging a fixed default map in place of `state.trust`, `sandbox_test.exs` gave `5 tests, 2 failures` (the prompt-change resume and the stored-id resume). Restored: `5 tests, 0 failures`.

## Simplify

One agent. It applied no change. Rejected ideas: a shared choice helper in `HarnessIO` (one user), module attributes for the two defaults (each used once), a default for the `trust` field (only `init/3` builds the struct), a shared `run/3` test helper (touches two other test files).

## Round 1 (full)

Bounds sensor (`--diff ad7e578b5e5b3601af80346830bd813c556cda57`):

```
bounds sensor: 2 candidate functions, 1 flagged, 0 without an answer
  plugins/bundled/lib/helyx/provider/codex.ex:221  SIZE  defp dispatch(%{"id" => rpc_id, "method" => "item/tool/call"
```

The flag is on code that the diff does not change: the diff edits the comment of the next clause.

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | approve, no material findings ("Option validation and 36 local start/resume payload checks passed") | none needed |
| Failure path | no reproduced finding. Probes that passed: a bad value fails each turn with `{:provider_init, {:invalid_option, :codex_sandbox}}` and launches no program, and the error names no value; the values go out on `thread/start`, the prompt-change `thread/resume`, the lost-thread fallback, a compaction that opens a stored thread, and an ephemeral thread; a command and a file change approval request get -32601 and the turn ends `:done`; `%State{}` is built only in `init/3`, so `trust` is never nil. Not reached: a real program (forbidden) | none needed |
| Standards | no hard violation. Judgement: (1) "The sandbox binds the program's own tools" has no probe; (2) the `dispatch` comment claimed a decline for every approval request; (3) the moduledoc did not name the options; (4) no test for "Claude Code ignores both options" and for the order "after `HarnessIO.options/1`"; (5) `pick/4` name, inline defaults, `trust` a bare map; (6) the default test repeats `turns_test.exs` assertions | (1) the doc now says the sandbox is meant for the program's own tools and that a `read-only` run with `apply_patch` was not run on 0.163.0; (2) the comment now says codex 0.157.1 took it as the decline of an approval, with the path; (3) the moduledoc names both options and their defaults, rewrapped so the file keeps 481 lines; (4) a test for Claude Code, and the order claim is removed from the doc; (5) kept: `trust` is a wire params map as `params/1` builds, and each default is used once; (6) kept: it is the only test of the default `approvalsReviewer` |
| Spec | none missing. (1) `approvalsReviewer: "user"` was not asked for and changes the default request; (2) the sandbox claim (as Standards 1); (3) `granular` is refused although the schema accepts it; (4) "a command or a file change approval as a decline (verified)" overstates the research note, which does not name the kind; (5) no retained test for Claude Code ignoring the options, for the order after `HarnessIO.options/1`, and for a stored-id resume with other values | (1) kept, see "Decision"; the research note's "Not run" now lists a live thread open with `approvalsReviewer`, and the feature doc says so; (2) fixed as Standards 1; (3) kept, see "Decision"; (4) the feature doc now says the program took the error answer to an approval request as a decline on 0.157.1, and that the note does not name its kind; (5) tests for Claude Code and the stored-id resume; the order claim is removed |

Guarantee table (spec agent, with the round-1 fixes):

| Guarantee | Proof |
| --------- | ----- |
| The defaults are `danger-full-access` and `never` on start | `sandbox_test.exs:73`; `turns_test.exs:48` |
| A default resume sends both values | `turns_test.exs:124` |
| Start and prompt-change resume send both values and `approvalsReviewer` | `sandbox_test.exs:25` |
| A stored id resumes with the values of the new start (no digest of them) | `sandbox_test.exs:47` |
| Each of the 9 string pairs is taken | `sandbox_test.exs:85` |
| Any other value (nil, atom, case, space, empty, `granular`) fails `init/3` with `{:invalid_option, key}` | `sandbox_test.exs:85` |
| The turn fails when `init/3` fails | the generic path, `test/helyx/session/provider_process_test.exs:297`; failure-path probe through `Session.start` |
| Claude Code ignores both options | `sandbox_test.exs:68` |
| Every server request gets -32601, an approval request too | `turns_test.exs:260` |
| The program takes the error answer to an approval request as a decline | research note, codex 0.157.1 only; no test (a real program) |
| The program does not keep the sandbox and the policy over a resume | research note, 0.157.1 |
| A user's config can name another reviewer | schema probe (`Config.approvals_reviewer`) |
| A Helyx tool runs outside the sandbox | by construction: the hands run it in the session |
| Not checked: the values that the program reports in its answer | no code reads them |

Round 1 reproduced no defect, so the loop ends. The fixes are doc text, a code comment, the moduledoc, and two tests.

## Precommit

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh`: passed on the first run. Root 783 tests, `apps/coding_agent` 113 tests, `plugins/bundled` 1,100 tests and 4 properties (1 excluded), 0 failures; Credo found no issues; Dialyzer 0 errors in each project. The `apps/coding_agent` test output has one log line `[warning] the session lock is lost, persistence off: :normal` with no failed test; that project has no change here.

## Accepted holes

- No run against a real `codex` program: the 0.163.0 facts are from the schema, and the approval and resume behaviour from the 0.157.1 runs.
- The provider does not check the `approvalPolicy` and `sandbox` that the program reports in its answer.
- The answer of the program to an error for `item/permissions/requestApproval`, `item/tool/requestUserInput`, and `mcpServer/elicitation/request` was not run.
- Helyx tools run in the session, outside the sandbox; Claude Code ignores both options.
