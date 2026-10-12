# 2026-10-12: Domain review run

An `/orchestrate` run of the tickets #508 to #515 from `docs/reviews/2026-10-12-domain-review.md` (decisions in section 12), and of the tickets that the run found: #517, #518, #522. The owner answered the parked questions during the run.

## Merged

| Ticket | PR | What changed |
|---|---|---|
| #515 | #519 | The `required` interface option is deleted. |
| #510 | #520 | `resumed` moved from `Turn` to `ProviderConn`, so the "lost" flag survives a reused provider process. One name for the resume id: the stream event `{:resume_id, id, cut}` and the client event `:resume_id`. |
| #511 | #521 | The resume label counts assistant messages, so the transcript repair shifts nothing. |
| #517 | #523 | `Helyx.Core.Plugins.resolve/1` returns an error for a plugins value that is not a list of modules (`{:invalid_plugins, v}`, `{:invalid_plugin, e}`). Core never raises on it. |
| #508 | #524 | One cut for tool results, `Helyx.Message.cut_result/1`: 64 KiB of valid UTF-8, the notice first, then the head, `[… cut …]`, and the tail. It runs after the repair, never fails the turn, and runs again when a session file is read back. |
| #512 | #526 | One slot for the provider process, `State.conn`, with `status: :starting \| :ready \| :ending`. `Wait.provider` and the phase `:context` are deleted. |
| #522 | #527 | A plugin module listed twice gives `{:error, {:duplicate_plugin, module}}`. |
| #514 | #528 | The glossary, ADR 0003, ADR 0007, `AGENTS.md`, the feature docs, and the moduledocs state only what the code on master keeps. The Turn and Model call glossary entries use the owner's text. |
| #518 | #529 | A resume id that arrives in the wait after an aborted turn is recorded, and the client gets the "lost" notice at once. Only the pid in `State.conn` with status `:ready` can record it, for the current turn or the turn that the wait ended (`Wait.turn`). |
| #513 | #530 | `Queue.abort/1` is the one owner of the queue drop. An abort or a failed turn gives the queued texts back in one `queue_dropped` event, steers first, and the TUI composer puts them before the draft. Each follow-up opens its own turn. |

Totals from `06bee9d` to `2141c97`: Core `lib/` +639 / −435, plugins and app `lib/` +54 / −14, tests +773 / −223, feature docs, ADRs and root docs +138 / −59.

## Parked

**#509** (`ready-for-human`, branch `ticket/509-error-text`, worktree `.claude/worktrees/agent-aed234ce75552161d`). Question: when a turn fails because a plugin crashed, how does Helyx make the error text so that no stacktrace gets into it?

- Three commits are reviewed: the error is a string of at most 4000 bytes, the log line is bounded, and the inspect work on a huge term is a known ceiling.
- The fix for gate r1 (a raw Erlang crash) is uncommitted in the worktree. Each rerun round found a new crash shape that the shape list in `crash/1` did not know. The three open shapes are an `exit(exception)` in a stream, `{:shutdown, {:failed_to_start_child, id, {exception, stack}}}` from `init/3`, and a `MatchError` that holds an inner stack.
- Options on the ticket:
  1. Remove every stacktrace from the reason with one bounded walk before Core writes the text (recommended).
  2. Add the three shapes to the list.
  3. Show only the text that a plugin wrote.

## Decisions

By the owner:

- **#508:** the cut keeps the head and the tail with a middle marker, and the notice goes first.
- **#514:** the shorter Turn and Model call glossary texts. #514 was parked once for these texts and then unparked.
- **#518:** option 1. Record a late resume id and show the "lost" notice.
- **#509:** the error is a string of at most 4000 bytes. An aborted turn keeps `error: :aborted` as data.
- The re-cut on resume and the strict refusal of a bad plugin configuration stay.

Mine:

- **#525 is closed as wontfix.** Two plugins whose `child_spec/1` return one child id fail Core's start, as any OTP `start_link` does. A caller that traps exits, such as a supervisor, gets `{:error, reason}`. `docs/agents/review-checklist.md` states this. It was the third hole on the Core start path (#517, #522, #525), so I stopped at the standard contract and did not add a fourth check.
- **#522 gate r2:** I rejected a finding of a "regression" of the #508 limits. The branch was based on a master without #508, and the rebase removed it.
- **#509:** I rejected the proposal to run the `message/1` of a plugin exception in a process with no link. That process could start a linked process that stops the session, but no real plugin does this ("Inputs from plugins" in the review checklist).
- **#518 after its rebase on #514:** no reduced round. #514 changed only doc text in the files that both changed, and Codex checked that their executable ASTs were unchanged.
- **The `abort/1` doc:** the #514 worker found that the doc called an abort with no turn a no-op, which is false in a wait. I gave the fix to #513, which rewrote that path, and not to a new ticket.

## Escapes

| Ticket | Ship | Codex gate | System change |
|---|---|---|---|
| #510, #512, #517, #522 | r1: 0 (#512 r2: 0) | r1: 0 | none |
| #511 | r1: 1, r2: 0, rebase r1: 0 | r1: 0 | none; ship caught it |
| #508 | r1: 2, then 0 in r2 to r5 | r1: 0 | none; ship caught both |
| #518 | r1: 1, r2: 0 | r1: 0 | none; ship caught it |
| #513 | r1: 0, r2: 2, r3 after the rebase on #518: 0 | r1: 0 | none; ship caught both |
| #515 | r1: 0 | r1: 1, r2: 1 | A doc edit claimed a guarantee that the code does not keep. The standards brief of `/ship` now checks each guarantee of a rule text that a diff adds or changes against a probe or a test. |
| #514 | two loops of three rounds, a rebase round, a gate-fix round | r1: 1, r2: 0 | The second escape of the same class: the abort text claimed an interrupt answer that a blocked provider never gives. The spec axis of `/ship` now requires a guarantee table in the review record, with one row per guarantee of a changed contract text and a test `file:line` or a probe for each row. |
| #509 (parked) | three rounds, each with new crash shapes | r1: 1 | Not merged. The branch has a checklist rule on error text, and the worktree has one more line for it. |

Checklist changes that the merged tickets brought: "Plugins and Core" in `docs/agents/review-checklist.md` (narrowed by #515, made a guarantee again by #517, the `start_link` rule of #522).

## What broke

- A conflict in `escapes.md` left a diff3 `|||||||` line after my resolver ran. I removed it and amended.
- `gh pr merge` for #520 failed with "Post graphql: unexpected EOF". The PR was still open, and the second run merged it.
- Workers shared one Codex helper script in the scratchpad and overwrote it. Each worker now gets its own script name.
- `git worktree remove` fails on a locked worktree. Unlock it first.

## Open

- **#509:** waits for the owner's answer.
- **#518:** a resume id that the live process sends after the wait has ended (idle, or a later turn) is still dropped. No provider is known to send it there. Recording it needs an owner decision.
- **#513:** Up and Down in the composer still drop an edit of a recalled prompt. Only `queue_dropped` keeps it. The failure-path budget did not reach two live clients, an abort in the wait after a done turn with a late `:rejected`, Ctrl+C when the event arrives, or a suspended Escape Task.
- **#513:** the ticket said that each queued text is bounded at input. It is not (#29). The docs state the bounds of the code.
- Seven lines on master still name an outside harness as a reference (`AGENTS.md:19`, ADR 0001, ADR 0006, `docs/features/TEMPLATE.md`, `bash-timeout.md`, and two in `fuzzy-edit.md`). No ticket yet.
