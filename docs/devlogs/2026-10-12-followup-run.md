# 2026-10-12: Follow-up run after the domain review

The second part of the 2026-10-12 run (`2026-10-12-domain-review-run.md` has the first part). It covers the tickets that the owner's answers and the process-limit incident made.

## Merged

| Ticket | PR | What changed |
|---|---|---|
| #533 | #534 | The docs give Helyx reasons for each decision and name no outside harness. |
| #532 | #536 | An edit of a recalled prompt survives Up and Down: a key that leaves the shown prompt makes the edit the draft. |
| #509 | #537 | One bounded walk puts `:stacktrace` in place of every stacktrace in a failed turn's reason before Core writes the error text (at most 4000 bytes). The full reason goes to a bounded log. |
| #540 | #542 | After an accepted send of a recalled prompt, the draft that waited comes back with its pastes. Ctrl+C still clears everything. |
| #539 | #543 | A new stop reason `:refused` for OpenAI `content_filter` and a Claude Code `refusal`. The TUI shows one line for `:max_tokens` and `:refused`. |
| #538 | #544 | `.claude/skills/ship/codex-reap.sh` sends SIGTERM to each Codex review broker whose `--cwd` directory is proved gone. `/orchestrate` runs it after each worktree removal and at the end of the run. |
| #535 | #545 | `Helyx.Reason` is the one owner of reason text. Tool results, turn errors and CLI errors carry no stacktrace, including the stack that an Elixir message or `Inspect` fallback writes. The CLI line has at most 4000 bytes. |

## Decisions

By the owner:

- **#509:** option 1, one cleaning rule (one walk) over a list of crash shapes.
- **#518:** the late resume id that arrives after the wait has ended stays dropped. No provider is known to send it there.
- **#539:** one stop reason, `:refused`, for a filter stop and a refusal. The next step of the user is the same in both cases.
- **#540:** the waiting draft comes back after a send.

Mine:

- **#539:** a stop reason that arrives while a steer waits is lost in two cases (an empty `done` in `Helyx.Provider.Loop`, and a Claude Code result held at a steer). I accepted this as a stated limit and did not change the steer protocol. The user has already sent new input at that point.
- **#535:** a pid in a thrown or exited value shows as text. A TUI crash during a run reads as "could not start the agent". A string that plugin code builds stays plugin text, a stack in it included. A lone stack frame outside a list stays (#509 rule).
- **#538:** a worktree that moves away from its path counts as gone. `/orchestrate` never moves a worktree. The pid-reuse race is in #541.

## Escapes

| Ticket | Codex gate | System change |
|---|---|---|
| #540, #539, #538 | r1: 0 | none |
| #535 | r1: 1, r2: 1, r3: 0 | The #509 class for the second time: an exception message or a safe `inspect` writes a stack after a `Stacktrace:` label. Tests through the tool boundary now cover it. Gate r2: the CLI line had no length cap; one cap at the end of `CodingAgent.error_text/1` now covers every clause. |

## What broke

- **Process limit.** `git` could not fork ("resource temporarily unavailable"). The per-user limit is 2,666. An orphaned `erl_child_setup` of Oct 4 held 957 zombies, and 193 leaked Codex broker trees from Sep 19 to Oct 11 held 1,222 processes. I killed both, and the count fell to 767. #538 removes the cause of the broker leak.
- **#539 merge.** A merge chain failed without a clear error, and the cleanup after it ran because I had joined it with `;`. The worktree and the local branch were removed while nothing was pushed. I made the branch again from its commit and merged it. `/orchestrate` step 5.5 already asks for `&&`; I broke that rule.
- **#538 probe.** A mutation probe of the worker removed the scope guard in a copy of the script and ran over all brokers of the user. The existence check still held, so only brokers of removed directories could get the signal.

## Open

- #541 (`needs-triage`): the races between the process read and the signal in `codex-reap.sh`.
- `codex-reap-test.sh` does not run in `mix precommit`.
- `Helyx.Tool.check_available/1` does not cap the reason that a tool's check returns. A 20 MB reason costs about 2 s in the clean pass of the CLI line, once, at exit.
