# Review of #672: a 4 MiB bound on the user text of the session API

Invariant: `Helyx.Session.prompt/3`, `steer/3`, `follow_up/3`, and `compact/2` refuse a text over 4,194,304 bytes (`Helyx.Session.max_text_bytes/0`) with `{:error, :text_too_large}` in `Helyx.Session.Input.text/1`, before the UTF-8 check and before any call to the session process, so no such text enters a queue, the transcript, or an event. The TUI shows `not sent: over 4 MiB` and keeps the composer text. Print mode cannot reach the bound (1 MiB stdin, the OS bound on arguments). Accepted holes: a user message that a resume reads from a session file has only the 64 MiB file bound; the texts that an abort gives back to the composer can join past 4 MiB, and the user splits them before the send.

Base: `aabf8050` (the branch base; `origin/master` moved during the work, so the diffs use the base, not `origin/master`).

## Round 1 (full)

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents): applied the TUI text from one function; shorter `@doc` phrases. Skipped: removal of `max_text_bytes/0` (the ticket asks for it), a shorter bounds row, one shared 4 MiB binary in the test (about 1 ms).

Codex: approve, no findings.

| Finding | Axis | Resolution |
| --- | --- | --- |
| The new reason `not sent: the text is over 4 MiB` is 32 bytes; the footer doc states at most 27 bytes, and a 30-column footer showed `over 4` without `MiB` (reproduced) | failure path | Text is `not sent: over 4 MiB`, 20 bytes; added to the reason list in `coding-agent.md` |
| `.credo.exs` entry for `session.ex` at 414 lines; the comment says the list only shrinks | standards | Entry removed. The checks of client input (cwd, origin, text) moved to `Helyx.Session.Input`, which owns them; `session.ex` is 392 lines |
| A Core comment named the wire (#656) | standards | The comment cites #672; the reason stays in the feature doc |
| The TUI routed one refusal text through `Command.error/1` | standards | Round 2 simplify: a literal in both places, `error/1` private again |
| `multiline-composer.md` still said the composer send is unbounded | spec | Composer and paste rows and the out-of-scope line name the send bound; the join of given-back texts past 4 MiB is an accepted hole |
| At-bound test only for `follow_up/3`; "no event" checked only through user texts and queue counts | spec | Each of the four calls takes a text at the bound; on an idle session `refute_received {:helyx_event, _}` after the refusals |
| "past the context of every model today" | spec | Removed (round 2: the catalog has 1,050,000-token models) |
| Print-mode output sentence has no test | standards | Replaced by the claim that print mode cannot reach the bound, which the spec reviewers probed (`getconf ARG_MAX` 1,048,576; Linux 128 KiB per argument; stdin 1 MiB) |

## Round 2 (full: the fix adds a module and touches several code files)

Base of the fix: `e0f86683` (`git stash create` of the round-1 tree). Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents): applied the literal TUI text and one 4 MiB build per test. Skipped: the delegate of `max_text_bytes/0` (`Input` is internal, `Session` is the public API).

Codex: approve, no findings. Failure path: no finding; every path into the session runs the moved checks, and every footer reason is at most 27 bytes.

No defect was reproduced, so the loop ends. Wording findings, fixed:

| Finding | Resolution |
| --- | --- |
| `harness-compaction.md` names `Helyx.Session.compact/2` as the enforcer | Names `Helyx.Session.Input.text/1` |
| "past the context of the models that Helyx runs" is false for 1,050,000-token models | Clause removed |
| The bounds row claims that Core refuses no text the wire admits; no wire code exists | Says that 4 MiB is the bound that the wire contract of #656 states |
| The moved cwd comment lost its subject | Restored |
| No `follow_up/3` test for `:invalid_utf8` | A text of exactly 4 MiB that is not UTF-8 gives `:invalid_utf8` for all four calls |

Kept as judgement calls: the literal `4 MiB` in the TUI texts (each reason is a fixed text, as the footer doc says); the test names.
