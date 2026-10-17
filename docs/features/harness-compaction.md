# Harness compaction

Ticket #552. Split from #490.

## Goal

Claude Code and Codex keep their own history, so a Helyx summary never reaches their model. The user starts the compaction of the program from the TUI with `/compact`, and sees one line when the program compacts, by `/compact` or by itself.

Decisions of the owner (2026-10-13, in the ticket):

- **The session owns every compaction.** On `/compact` the session asks the provider to compact the context that it keeps. A provider that keeps its own history runs its own compaction. A provider that does not answers so; the session then gives a notice, until the Helyx summary of #490 takes its place. The Helyx summary never runs on a session whose provider compacts its own history. No code checks this yet: the only compaction plugin is the no-op `none`, and #490 adds the check with the summary. Reason: the history lives where the provider keeps it, and two summaries of one history fight each other.
- **`/compact` during a turn aborts the turn first**, then compacts. The turn is not retried. Reason: a Codex compaction turn cannot be steered, and a compaction in the middle of a turn can cut a tool call from its result.
- **No `/compact` message in the transcript.** A compaction is recorded as a compaction, not as a user turn.

Decisions of this doc:

- **A compaction is a turn with no user message.** The session opens a turn, sends the compact request in place of `{:turn, ...}`, and ends it at the provider's terminal. Reason: the turn already has every path that a compaction needs: the connect of the provider process, the abort with its interrupt, the death of the provider process, the wait, and the queues. A second activity would copy them.
- **Core derives the trigger.** A compaction event in a compaction turn is `manual`; in any other turn it is `auto`. Reason: a program compacts by itself only inside a model turn, and on request only in the compaction turn, so the wire value adds nothing that the turn does not give.
- **Core checks that a compaction happened.** A compaction turn that ends `done` with no compaction event fails with the text "the provider reported no compaction". Reason: one check for every provider, at the boundary, so a provider that ends the turn without a compaction cannot show the user a success.
- **Helyx does not set `CLAUDE_CODE_AUTO_COMPACT_WINDOW`.** The footer that shows the context window is #558, and the window of a model is #557, #559, and #560. Until Helyx shows a window, there is no limit that the program must match. The ticket of the footer decides it.
- **The session file records each compaction** as a `compaction` entry with the provider id, the trigger, and the token counts. A resume adds no message for it: the history and its summary stay in the program, and the Helyx transcript does not change (CONTEXT.md, "Compaction").
- **A compaction makes the program's history safe to resume.** A new provider process resumes the program's session only when the program has the transcript's end. An abort or a failure of the last reply makes the program start fresh with the replay, because the program may not keep the cut reply. A compaction of the provider under its current resume id, after the last assistant message, makes this check unnecessary, and also the check that the provider made a message under that id. The last assistant message must still come from that provider. The summary is now the program's whole history, so the next provider process resumes it. The session derives this from the `compaction` entries and the resume id entries of the file, and from the same events in memory (`Helyx.Session.Transcript.resumable/3`); it stores no other record. Accepted limit: the reply that the abort cut may not be in the summary. With no compaction after an abort or a failure, the program still starts fresh.
- **The usage of a compaction goes into the next `done` of the program.** A compaction turn ends `done` with no usage, and the provider keeps its usage sum. Claude Code: the `result` of `/compact` has every `usage` count 0, and its `total_cost_usd` includes the compaction call. The meter keeps the total of the last `done` as its mark, so the cost of the next `done` covers the compaction call once. Codex: the token counts of the compaction turn stay in the sum of the next `done`. Reason: no message holds the usage of a compaction turn, so a usage on its `done` is lost. A resumed Claude Code program reports the totals of its harness session, so after a reconnect the first `done` holds the compaction cost. When a call cut while it streamed is before the compaction, that `done` gets `cost: nil` live. After a reconnect it gets `cost: nil` when any abort or failure cut the reply before the compaction (`docs/features/usage-and-limits.md`, "Per provider"). Accepted limit: with no later `done` under the same Claude Code harness session, the cost of the compaction is in no message. The Codex sum lives in the provider process, as for any turn that ends with no `done` (`docs/features/usage-and-limits.md`, "Per provider"), so a new provider process does not have the token counts of the compaction.
- **A program with no history fails the compaction at once.** A fresh Claude Code program, or a fresh Codex thread, gets the Helyx transcript as a replay at its first turn, so before that turn it has nothing to compact. The provider ends the turn with the error `{:compaction_failed, "no history in the program yet"}` and writes nothing to the program, so the replay of the next turn is unchanged.

The facts are in `docs/research/claude-code-stream-json.md`, "Compaction (2026-10-13, #552)", and `docs/research/codex-app-server.md`, "Compaction (2026-10-13, #552)".

## Interface changes

**Provider request** (`Helyx.Provider.request/0`): `{:compact, turn_id, instructions}`, where `instructions` is a string, empty for none. The answers:

| Answer | Meaning | Session |
| --- | --- | --- |
| `:ok` | the provider runs the compaction as the turn `turn_id`: zero or more events, then a terminal | the turn is `submitted` |
| `:unsupported` | the provider keeps no history of its own | the Compaction plugin can summarize the transcript (`summary-compaction.md`); with no summary, a `:notice` event, then the turn ends `done`; a plugin error or a failed summary ends it `error`; the provider process stays |
| `{:error, reason}` | as for `{:turn, ...}` | the provider process stops, and the turn fails |

The reply bound is the one of `{:turn, ...}` (2,000 ms, armed kill). `Helyx.Provider.Loop` answers `:unsupported`.

**Stream event**: `{:compaction, tokens_before, tokens_after}`, each a token count from 0 to 10^9, or nil when the program does not report it. It may come in any turn. `Helyx.Session.Stream.check/1` checks it; any other shape is a bad stream event. A compaction turn takes no other rule: a provider that sends message events in it gets them recorded as in any turn.

**Client API**: `Helyx.Session.compact(session, instructions \\ "")`:

| Session | Result |
| --- | --- |
| idle | `:ok`; a compaction turn starts |
| a turn runs | `:ok`; the turn aborts as at `abort/1` (its queues go back to the client), and the compaction turn starts at the end of the wait |
| the wait after a turn | `:ok`; the compaction turn starts at the end of the wait, before the queued follow-ups |
| a compaction turn runs, or one waits | `{:error, :turn_running}` |
| text over 4 MiB (`Helyx.Session.max_text_bytes/0`) | `{:error, :text_too_large}` |
| text that is not valid UTF-8 | `{:error, :invalid_utf8}` |

An abort drops a compaction that waits. A steer in a compaction turn is not sent to the provider: it waits in the steer queue, and the next turn starts with it. A compaction cannot be steered.

**Events** (`Helyx.Event`): `:turn_start` of a compaction turn has `%{origin: :compaction}`. New type `:compaction`, `%{trigger: :manual | :auto, tokens_before: n | nil, tokens_after: n | nil}`, with the turn id. The `:done` end of a compaction turn adds no assistant message when no message is open.

**Session file**: the entry `{"type": "compaction", "provider": id, "trigger": "manual" | "auto", "tokens_before": n | null, "tokens_after": n | null}`. A resume rejects a compaction entry whose provider is not a string as an invalid file. An older reader skipped that entry.

**Claude Code** (`Helyx.Provider.ClaudeCode`): the compact request writes the user line `/compact <instructions>` with its own `uuid`, as a turn. The program starts it with `command_lifecycle` `started`. A `system` `compact_boundary` line in a started turn gives the compaction event with `compact_metadata.pre_tokens` and `post_tokens`. In a compaction turn the `stream_event`, `assistant`, and `user` lines are dropped: the summary line, the `Compacted` line, and the text of a failed compaction never reach the session. The `compact_error` of a `system` `status` line is kept, and the `result` after it ends the turn with `{:compaction_failed, text}`. A `result` of a compaction turn with no boundary and no `compact_error` ends it `done`, and Core fails it, as it has no compaction event. A lost session during a compaction ends the turn the same way: the fresh program has no history.

**Codex** (`Helyx.Provider.Codex`): the compact request sends `thread/compact/start` and answers `:ok` at its result. The next `turn/started` is the compaction turn, whose id comes only there. A `contextCompaction` item at `item/completed` gives the compaction event with nil counts. Codex takes no instructions; they are dropped.

**TUI**: `/compact [instructions]` calls `Session.compact/2`. A `:compaction` event adds one line: `compacted: 32k → 5k tokens`, `compacted` when a count is nil, with ` (auto)` after an automatic one.

## Replaced mechanism

none

## Bounds

| What | Bound | Over the bound | Enforced in |
| ---- | ----- | -------------- | ----------- |
| compaction instructions | at most 4 MiB of valid UTF-8, as a prompt (#672) | `{:error, :text_too_large}` or `{:error, :invalid_utf8}` | `Helyx.Session.Input.text/1`, called by `Helyx.Session.compact/2` |
| answer to `{:compact, ...}` | 2,000 ms, armed kill, as for `{:turn, ...}` | the provider process ends; its `provider_down` fails the turn | OTP timer server |
| `submitted` compaction turn: the `:ok` answer to the terminal | unbounded, accepted, as a model turn: Claude Code took 2.9 s and 2.3 s, Codex 7.8 s | the user aborts; the interrupt has its armed kill | client |
| an interrupt of a compaction turn | not verified on either program; the reply kill of 2,000 ms bounds it | the provider process ends, and the next turn starts a new one | OTP timer server |
| a token count of a compaction event | 0 to 10^9, or nil | the provider gives nil for a wire value outside it; Core fails the turn for any other value (bad stream event) | each provider; `Helyx.Session.Stream.check/1` |
| `compact_error` text | the error cap of the provider (`HarnessIO.cap_error/1`) | cut | `Helyx.Provider.ClaudeCode` |
| compactions that wait | at most one; a second `/compact` gets `{:error, :turn_running}` | none | `Helyx.Session.Server.Compaction.admit/2` |
| the TUI line | the counts are at most 10^9, so the line is at most about 40 bytes | none | `Helyx.TUI.ViewModel` |

## Ownership

No new resource. The compaction turn runs on the provider process of the turn, with its rows in `docs/features/session-lifecycle.md`.

## Out of scope

- The Helyx summary for providers that keep no history, and its trigger: #490.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` from the context window: the footer, #558.
- A compaction line in the snapshot of a resumed session.
