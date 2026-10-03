# Review: #446, session-lifecycle.md holds the Core turn contract

Invariant: every sentence of `docs/features/session-lifecycle.md` (the Core turn contract) and of `docs/features/long-lived-harness.md` (only what the Claude Code and Codex plugins and `Helyx.HarnessIO` own) is true of the code, every bound row names the attribute or function that holds its value, and every changed link points at a doc that states what it is linked for. Accepted holes, stated as current limits: a cut with no block stores no message, so a later turn can resume an older provider session; an abort with a tool call joins as `:tool_use` and resumes; an armed kill of an old request can fail the next turn; a provider end after the context is prepared fails the turn in `submitting`; a session stop in a wait can kill the provider process before its close answers.

## Round 1 (full)

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`

Simplify: fixed a meta sentence, a repeated steer bullet, a history phrase in `session-stream.md`, a Core link in `coding-agent.md`, and two harness terms in the Core doc (moved to the harness Current limits). Skipped: removing the rows that `one-provider-path.md` also states (the ticket asks this doc to hold the contract), and cutting "Subscribers" (the ticket notes ask for subscribe with its ref).

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | no Goal and no Out of scope sections | Goal heading added; the harness doc keeps an Out of scope section |
| Standards | rows with no bound say "none" | "unbounded, accepted" |
| Standards | two idioms | rewritten |
| Standards | `provider_process_tools_test.exs` pointer | points at `one-provider-path.md`, "Helyx tools inside the program" |
| Spec | Out of scope items of the harness lost | restored |
| Spec | Codex line with no string `threadId` | stated |
| Spec | test pointers | fixed |
| Failure path | steer bound row counted only open requests; `Queue.room?/1` counts every `sent` entry | fixed |
| Failure path | `done` stores an empty message when none is open | fixed |
| Failure path | `Server`, not `TurnLoop`, drops stale events and answers stale tool requests | fixed |
| Codex | "the provider callbacks run only there": `id/0` and `release/3` run elsewhere | fixed |
| Codex | a resume error other than the lost thread fails with `{:malformed, "thread/resume"}` | fixed |

## Round 2 (reduced: 0 code lines, only Markdown and test comments)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Failure path | a Claude `tools/call` also maps in a program turn | fixed |
| Failure path | the stop reason is `:no_queued_turn_count` | fixed |
| Failure path | Codex answers server requests of child threads | fixed |
| Failure path | the close writes end of input at once; the kill can still TERM before the exit | fixed |
| Spec | Out of scope item "Claude background tasks in the TUI" lost | restored |
| Spec | Codex `turn/start` error stops the provider process | stated |
| Spec | `id/0` runs at plugin registration | fixed |
| Spec | a withdrawal is dropped only when no turn runs | fixed |
| Spec | `provider_process_test.exs` claimed every row; `provider.ex` and `events.ex` pointed at the wrong doc | fixed |

Not changed: the comments in `provider_process.ex` ("the callbacks run only here") and `queue.ex` ("whose request is open") predate this change and are outside the ticket.

## Round 3 (full: the fix touched two code files, comments only)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | session-lifecycle.md has no Out of scope section | added |
| Spec | the #432 limit of the `Provider.Loop` empty `done` drop is missing | added to Current limits |
| Codex | `expectedTurnId` is the running program turn id, not the `steer_id` | fixed, not committed |
| Codex | `initialize` and `tools/list` are answered before the -32601 rule | fixed, not committed |
| Failure path | Ownership row: an abort in `preparing` keeps the program; a relaunch also creates it; the provider process holds the port | fixed, not committed |
| Failure path | an interrupt ends every Claude sub-agent; only a background `Bash` task survives | fixed, not committed |
| Failure path | `queue.ex` linked "Steer" for the limit of 32; the limit is in "Bounds" | fixed, not committed |
| Failure path | no port closes on the stdin cap; the watchdog exits and the provider process stops on the exit | fixed, not committed |

Round 3 still found defects. No fourth round runs, and nothing is committed (ship rule: at most three rounds). Precommit passed before the last six fixes; after it, only Markdown and one comment in `queue.ex` changed.
