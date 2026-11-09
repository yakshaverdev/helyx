# Review of #882: the approval gate

Change: `Helyx.Hook.Approval` (`plugins/bundled/lib/helyx/hook/approval.ex`), the TUI picker `Helyx.TUI.Approval` (`plugins/bundled/clients/tui/lib/helyx/tui/approval.ex`) in the slot of `Helyx.TUI.Question`, their tests, `docs/features/approval-gate.md`, and the `approval` entry of `docs/features/ui-blocks.md`. The ticket has no comments; the decisions come from ADR 0013 §7, ADR 0011 §4, and the owner comment on #503 (from #491).

## Round 1 (full)

Simplify: five edits (one ordered list of actions instead of an order map, `asked/1` for the reply of the ask, a `cut(nil, _)` clause, one `body/2` for the rows and the widgets, test cleanups). Then a repeat of a key only moves the picker's cursor and never sends an answer, as Enter of the form picker.

Bounds sensor (base `77d0751e`):

```text
bounds sensor: 5 candidate functions, 0 flagged, 0 without an answer
```

| # | Source | Finding | Reproduced | Resolution |
|---|---|---|---|---|
| 1 | failure path, spec (c3) | On a short screen the picker drops arguments rows to fit the room with no dim row (`widgets/2` decides the row before the room cut), and below 5 rows of room the options are cut too; the bounds row says "the rest is left out, with a dim row". At a height of 8 of an 80-column terminal, a `read` path of 150 `a` and `_TAIL_rm_rf` shows only its start, then Allow and Deny | yes, render probe at heights 7 to 12 | **Open** (time limit of `/ship` reached). Fix: decide the dim row after the room cut, and keep the dim row first, then the options, then the arguments rows: with `inner = height - 2`, show every row and no dim row only when the rows fit `min(8, inner - 2)` and `cut` is false; else the first `min(8, inner - 3)` rows, the dim row, and the options |
| 2 | Codex (high) | A config that turns invalid after Core start makes the hook raise; Codex itself says it still denies and needs no change | no defect: the failed-hook path gives the path-specific reason, tested by `approval_test.exs` "a broken config denies the call" | Rejected |
| 3 | spec (a1) | The #503 decision asks for "a flag, which this ticket's feature doc names", that allows all calls for sandboxed runs; the doc names `default: :allow` with no rule, or the gate left out, and says "No other flag" | n/a (text) | **Open**: the doc should name `default: :allow` with no rule as that flag, not deny that there is one; reported as an assumption for the owner |
| 4 | standards, spec (a2) | The 1,024-byte title cut of the picker is not in the bounds table, and has no test at 1,024 and 1,025; the 8-row bound has no test at exactly 8 rows with no dim row | n/a (doc, tests) | **Open** |
| 5 | standards, spec (a3) | The answer to `{:error, :not_running}` ("the call no longer runs") has no test | n/a (test) | **Open**: reachable when the result of the call joins the transcript while the gate asks (`docs/features/ui-blocks.md`, a taken steer) |
| 6 | spec (a4) | "Replaced mechanism" has no row for the change of `ui_blocks_test.exs`, whose unknown kind is now `confirm`, since the TUI knows `approval` | n/a (doc) | **Open** |
| 7 | spec (c1) | "No value (`nil`) is the default of each key" reads as a `nil` value; the code fails a `nil` value. It means an unset env key | n/a (doc) | **Open**: reword to "an unset env key" |
| 8 | spec (c2) | "wraps no more than that in a frame": a frame wraps the kept text twice, once for the rows and once for the draw | n/a (doc) | **Open**: reword to twice that |
| 9 | standards | Guarantees with no test: Escape over the approval picker, the dim row drawn for `cut: true`, a multibyte cut of the arguments | n/a (tests) | **Open** |
| 10 | standards (judgement) | `keyword?/2` and the shape of `limit/1` repeat `Helyx.Hook.Command`; the four `%Approval{}` clauses of `Question` delegate only; `Approval` calls `Question.reject/1`, whose closed text says "question"; the state field `question` holds either picker; the TUI test is `async: false` with no env change | n/a | Kept for now: a one-line helper and a rename of the state field touch modules outside the ticket. The TUI test can be async; open |
| 11 | standards (judgement) | `docs/research/coding-tools.md` has rows on permission prompts that the doc does not cite | n/a | Open |

Guarantee table (spec agent, round 1):

| Guarantee | Proof |
|---|---|
| Rules match tool and provider; strictest wins; default `:ask` | `hook/approval_test.exs` "the rules" tests |
| A broken config denies, naming the path of the bad value | `hook/approval_test.exs` "a broken config fails the hook…", "a broken config denies the call" |
| `limit/1` gives `limit_ms` as configured; Core refuses a bad one | `hook/approval_test.exs` "limit/1 …", "Core refuses a bad limit_ms at its start"; 600,000 passes and 600,001 fails: probe |
| Allow, deny, and any other answer is a deny | `hook/approval_test.exs` "the user allows…", "the user denies…" |
| No client: denied at once, with the reason | `hook/approval_test.exs` "with no client that can answer…" |
| `:not_running`: "the call no longer runs" | none (finding 5) |
| Past the limit: deny, the ask ends `ended` | `hook/approval_test.exs` "past its limit…" |
| An abort ends the hook and its ask | Core: `test/helyx/session/hooks_test.exs` (abort kills a running hook; the hook's end closes its ask); no gate test |
| Every answer is a `hook` entry | Core: `test/helyx/session/hooks_test.exs` |
| The request shape; the 256 and 16,384 cuts at a character boundary; `cut: true` | `hook/approval_test.exs` "the request" tests (the arguments cut is tested with ASCII only, finding 9) |
| The request is under 40,000 bytes | `hook/approval_test.exs` "the largest request…"; probe: 38,999 bytes |
| `default: :allow` with no rule allows every call | probe |
| The oldest form or readable approval gets the picker; an unreadable one shows its text | `tui/approval_test.exs` "the choice of the picker" tests |
| Up, Down, Enter, `y`, `n`; `answer sent` until `ask_end` | `tui/approval_test.exs` "in a session" tests |
| Escape aborts | the shared clause of `Helyx.TUI`; tested with a form only (finding 9) |
| The picker keeps 16,384 bytes; a dim row for `cut: true` | `tui/approval_test.exs` "the picker keeps…" (state only, finding 9) |
| At most 8 arguments rows and a dim row | `tui/approval_test.exs` "long arguments show 8 rows…" |
| The room of the screen | contradicted (finding 1) |

Not reached by the failure-path budget: harness approvals from the Codex or Claude Code fakes with a provider tool name of 4 KB or more, the limit kill while an answer is on its way, and a reconnect while an approval shows.

## State at the commit

The `/ship` limit of 45 minutes of work was reached after round 1. The commit holds the code as round 1 reviewed it; no fix after round 1 is in it. Findings 1 and 3 to 11 are open for the next worker.

## After round 1: the decisions of the orchestrator

The orchestrator decided the open items (logged for the owner), with no review round: the Codex gate of `/orchestrate` follows.

| # | Resolution |
|---|---|
| 1 | Fixed. `Helyx.TUI.Approval.body/3` gives the room first to the dim row and the options, then to the arguments rows, and decides the dim row after it cuts the rows to the room. `rows/3` asks for at least 5 rows. Where the layout of a short screen gives the picker fewer, the options share one line, and with one row inside the box the dim row joins it. Tests: `tui/approval_test.exs` "a short screen marks what it hides and shows both options" (the probe of round 1 at heights 5 to 12 of an 80-column screen, 80x8 included), "with 3 to 5 rows of room the picker takes 5…", "with fewer rows than 3 inside, the options share one line" |
| 3 | Fixed. The doc names `default: :allow` with no rule as the flag of a sandboxed run; "No other flag" is gone |
| 4 | Fixed. A bounds row for the title (1,024 bytes); tests at 1,024 and 1,025 bytes and with a split character; tests at exactly 8 and 9 rows |
| 5 | Fixed. `Helyx.Hook.Approval.asked/1` is public (`@doc false`), and a test checks the answer to each reply, `:not_running` included. The session reaches it when the result of the call joins the transcript while the gate asks; the provider that sends such a result in tests is a test plugin of the root project, which the bundled tests cannot use |
| 6 | Fixed. "Replaced mechanism", item 4 |
| 7 | Fixed. "An unset env key, and a key that the list leaves out, give the default" |
| 8 | Fixed. "at most twice that in a frame" |
| 9 | Fixed. Tests: Escape over the approval picker, the dim row drawn for `cut: true`, a cut of the arguments that splits a character |
| 10 | Kept, as round 1 says |
| 11 | Fixed. The doc cites `docs/research/coding-tools.md` |

One run of `mix test test/helyx/hook/ test/helyx/tui/` in `plugins/bundled` had one failure whose name the cut output did not keep; three more runs of those folders and six runs of the two approval test files had none.
