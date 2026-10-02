# Review: the Perl watchdog program in its own file (#326)

Date: 2026-10-03. Base: `origin/master` at `9defa53`. Scope: `plugins/bundled/lib/helyx/watchdog.ex`, the new `plugins/bundled/lib/helyx/watchdog/watchdog.pl`, and `.credo.exs`.

## Invariant

The `perl -e` program that `launcher/5` passes in the port args is byte for byte the same string as the old `~S` heredoc. `@watchdog` now reads it at compile time from `watchdog/watchdog.pl`, with `@external_resource`, so a change to the file recompiles the module. No behaviour of `start/4`, the handshake, the go-ahead, or `Helyx.Watchdog.Group` changes. No test file changes.

## Identity and size

- SHA-256 of the old `@watchdog` string (evaluated from the AST of `watchdog.ex` at `9defa53`): `e927896840e411ba10a054e0384e8010c37b39f0c1903fd70337b50c71d725e0`.
- SHA-256 of `watchdog.pl`, which `File.read!` gives to `@watchdog`: `e927896840e411ba10a054e0384e8010c37b39f0c1903fd70337b50c71d725e0`.
- `watchdog.ex`: 440 lines before, 370 after. `watchdog.pl`: 71 lines, 2578 bytes. The `.credo.exs` entry is removed.

## Round 1 (full)

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents): no findings.

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 1 judgement call | 0 | Not changed: a pointer comment from `watchdog.ex` to `watchdog.pl`. The protocol comment is directly above `@watchdog_path`, and the ticket forbids comments in the Perl file. |
| Spec | 0 | 0 | The hashes and the line counts were checked again by the agent. |
| Failure path | 0 | 0 | Byte comparison of the evaluated old heredoc and the file; watchdog tests pass. Not reached: the `:slow` watchdog test (precommit runs it), a recompile probe after an edit of `watchdog.pl`. |
| Codex adversarial | 0 | 0 | Approve. |

No round reproduced a defect, so the loop ends after round 1.
