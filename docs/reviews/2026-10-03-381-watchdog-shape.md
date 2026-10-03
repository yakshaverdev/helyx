# Review: one watchdog failure shape, one cut helper, no composer UTF-8 gate (#381)

Date: 2026-10-03. Base: `origin/master` at the branch point (`591fb5d`). Scope: `plugins/bundled/lib/helyx/watchdog.ex` (`start/4` result), `tool/bash.ex` (start result), `harness_io.ex` (the watchdog start result and `cap_error/1` only; `keep_port/1` unchanged), `text.ex` (`cap/3`), `tui/view_model.ex` (`cut_line/1`), `tui/composer.ex` and `tui.ex` (the UTF-8 gate), one comment in `provider/claude_code.ex`, their tests, `docs/features/coding-agent.md`, and `docs/features/multiline-composer.md`.

## Invariant

`Helyx.Watchdog.start/4` (entry points: the bash tool's `run/2` and `Helyx.HarnessIO.start/5`) returns `{:started, port, pre}` or `{:error, reason}` with the port closed. `reason` is valid UTF-8 of at most `Helyx.Provider.max_notice_bytes/0` bytes: the tail of the reason of a watchdog that did not fork, the head of a no-marker text that names perl. Both callers use the reason as it is, and `HarnessIO` keeps no port. `Helyx.Text.cap/3` always returns valid UTF-8; `HarnessIO.cap_error/1` and `ViewModel.cut_line/1` call it. The composer trusts event text, because ExRatatui gives it as a Rust `String` (`native/ex_ratatui/src/events.rs`, `Key(String, ...)`, `Paste(String)`).

Accepted holes:

- `read_to_exit/2` has no byte cap; the cwd argument bounds it (row "bash working directory at command start", unchanged).
- The cut of a start reason is silent. A reason of a working directory over about 1,950 bytes loses its `cannot enter the working directory` head; the bash tool already lost it at 51,200 bytes, the harness providers kept the head before.
- `Text.cap/3` now drops invalid bytes of uncut text too. An OpenAI error body of 16 KiB or less does not go through `Text.cap/3`, so it is unchanged (Codex gate note).

## Removed, and the tests deleted with it

| Removed | Origin | Deleted tests |
|----|----|----|
| `{:not_started, port, reason}` and `{:failed, text}` results of `Watchdog.start/4`, and the port of a not-started program in the `HarnessIO` state | the split of #52 and #340 | none; the bash and harness tests of a failed start still pass on `{:error, reason}` |
| Three copies of the cut (`binary_slice` and `replace_invalid` in `cap_error/1` and `cut_line/1`, `Text.truncate` of the not-started reason in bash) | #51, #52 | none; `text_test.exs` "cap/3 keeps at most max bytes" now expects `""` for an uncut invalid byte |
| Composer UTF-8 gate (`Composer.edit/3` returned `{:error, :invalid_utf8}`; `Helyx.TUI` showed `input rejected: not valid UTF-8`) | review only (#74, #46); no source sends such text | `tui_test.exs` "invalid UTF-8 is rejected with a reason and leaves the composer unchanged" |

Kept: the marker and the hold before the go-ahead (ADR 0004), the group kill and release tests, `read_to_exit` (#340), `keep_port/1`, `cap_error/1` with its clause for a value that is not text (four callers pass program JSON values).

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

Simplify (2 agents, covering the four angles): `Text.cap/3` lost its uncut special case. Not changed: one name for the two attributes of the notice bound (the watchdog must not call `HarnessIO`), the stale comment in Core `provider.ex` (outside the diff, and Core must not name the harness), and a tail buffer in `read_to_exit/2` (unchanged code, accepted hole).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 2 called hard, 5 judgement calls | 0 | The "Harness error text" row of `coding-agent.md` now gives the side of each watchdog cut. The `tui.ex` comment on `:invalid_utf8` names ExRatatui, not `Composer.edit/3`. `cap/3` is back to one clause for each end (pattern matching over `if`). Not taken: `Composer.edit/3` as a middle man (three clauses, small gain), the repair in `cap/3` (every caller wants valid text), the Core comment (outside the diff). |
| Spec | 1 partial, 2 stale doc statements, 1 scope note | 0 | The `tui.ex` comment as above. The "tool result text" row names both start errors. The OpenAI error body note is corrected above. |
| Failure path | 0 | 0 | Probed through `Bash.run/2`, `Codex.init/3`, `ClaudeCode.init/3`: a missing cwd, a cwd of 1,500 "é" (2,027 bytes, valid, ends with the OS reason), a fake perl with a `0` marker, invalid bytes and 5,000 bytes (1,999-byte valid tail, no open port, empty mailbox). Not reached: a real perl locale warning before a `0` marker, a `0` marker with no exit, runs after a successful start. |
| Codex adversarial | 0 | 0 | Approve. |

No reproduced defect, so the loop ends. The fixes are doc, comment, and judgement fixes of a round with no defect, so they get no further round.
