# Interrupted tool calls (#584)

## Goal

A session stops while a tool call runs: a crash, a kill, a node stop. The session file then holds the call and no result. At resume, the model must see that the call may have run, so that it checks before it repeats a call with effects, such as a `git push`.

User story: a session crashes while bash runs `git push`. I resume it. The model sees that the call was interrupted and may have run, and it checks (for example with `git log`) before it repeats the call.

Decisions (owner, 2026-10-14):

1. The resume read gives each open call one error result with a fixed text. No new session-file entry: the result is derived on read, as before (#269). A write before every tool call ("never started") would spare only one check, and it adds a write and its failure paths.
2. A user abort keeps `aborted` (`Helyx.Session.aborted_result/0`). Only the read of a stopped session uses the new text.
3. The session doc states the durability of the session file, once: `docs/features/coding-agent.md`, section "Session file", rule "Durability".

## Interface changes

At resume, `Helyx.Session.Transcript.repair/1` gives each open call (a call with no result among the tool results right after its message) the result `{:error, text}`, where `text` is:

```text
The session stopped while this tool call ran, and its result was lost. The call may have run in full, in part, or not at all. Check its effects before you repeat it.
```

The value is `Helyx.Session.Transcript.interrupted_result/0`, an internal module: no client matches the value, and `test/helyx/session/transcript_test.exs` pins the text. The repair runs only in `Helyx.Session.resume/2`. The live end paths (abort, failure, steer, a harness turn end) still write `aborted`.

The file is unchanged: it keeps the open call, and every resume derives the same result at the same place. A result that the file holds, `aborted` included, is kept.

### Clients

No client matches the value of `aborted_result/0` or of the new result; each one reads a tool result as text. Each one shows the new value as it shows any error result:

- TUI: the tool cell shows the text in the error style (`Helyx.TUI.Transcript`, `result_lines/2`), wrapped, in the four-line preview. The text is one line of 165 bytes, so the preview shows all of it. The `aborted` notice of a turn end comes from `turn_end` with `outcome: :aborted`, not from a tool result, and a resume sends no `turn_end`.
- Print mode (`CodingAgent.Print`): it prints the final answer, not tool results. A print run that resumes a session (#574) gives the model the new text in the replay.
- Harness providers: the Claude Code replay sends the text as a `tool_result` with `is_error: true`, and the Codex replay as a `function_call_output`. Both read `Helyx.Message.text/1`. A harness gets the replay only when it starts fresh, so an interrupted result of the last assistant message makes `Transcript.resumable/3` give no resume id that the harness gave before that message: the harness never got the result, and a resumed harness session would not get it either. The cost is one replay after a crash in a tool call. An id that the fresh harness gives after the resume came with the replay, so the result does not block it: it resumes after a later message of the fresh session or a compaction under it, as any id does.

### Background runs (#577)

A background run that the stop lost gets a derived end at resume (`Helyx.Session.Background.lost/1`). The two cases do not overlap: a call with a start answer has a result, so it is not open, and its run can only be lost; a call that the stop cut before its start answer is open, and gets the text above. Both texts have one form: what stopped, what may have run, and a check before a repeat. The lost end now reads:

```text
The session stopped while this background command ran, and its end was lost. The command may have run in full or in part. Check its effects before you run it again. Its output file was deleted with the session.
```

The delivery rules of #577 do not change.

## Replaced mechanism

1. The resume read gave each open call `{:error, "aborted"}`. It now gives `Transcript.interrupted_result/0`, at the same place and in the same order. The live `aborted` results do not change. `Transcript.resumable/3` gave the stored resume id of a harness whose last message had a call that a crash left open; it now gives none, and the harness starts fresh with the replay.
2. No reply is removed.
3. Tests: `test/helyx/session/transcript_test.exs` ("repair/1") now expects the interrupted text, and adds a test that a stored `aborted` result stays. `test/helyx/session/persistence_test.exs` ("a resume writes nothing ...", "resume after a crash mid-turn ...") expects the interrupted text in the provider request and in the snapshot. "a resume with an interrupted call of a labelled provider starts that provider fresh" checks the fresh start and the result in the history; "resumable/3" in `transcript_test.exs` checks the rule, and its property test models it. `test/helyx/session/background_test.exs` expects the new lost text.
4. The model and the user see the new text in place of `aborted` after a resume.
5. None.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| interrupted results at resume | one per open call of the transcript; the file has at most 64 MiB | the file limit of `Helyx.Session.File` |
| text of one result | fixed, 165 bytes of ASCII, under the result cut of 65,536 bytes | cannot pass |

## Ownership

None: the change adds no resource.

## Accepted holes

- A call whose live result the session could not write gets the interrupted text at resume, though the session did not stop while it ran: a write failure turns persistence off (`docs/features/coding-agent.md`, write failure rule), so nothing after it reaches the file. The text still holds: the call may have run.
- A file written before #269 holds its `aborted` results, and they stay.
- The replay of a fresh harness has a bound of 400,000 bytes (`Helyx.HarnessIO.cap_replay/3`, `docs/features/long-lived-harness.md`) and leaves out the oldest messages, and with them each result whose call message it left out. When the last assistant message, the arguments of its calls, and its results pass the bound, the interrupted result is left out too, and the model does not read it. One call with large arguments, such as a `write` of a large file, is enough. The TUI shows the notice "<provider> got the transcript without its N oldest messages"; print mode shows no notice for a cut.
- The rule takes an id whose label is at or after the last assistant message as an id of a fresh start that read the replay. Both bundled harnesses send their id only at the first turn of a fresh program, before any message (`Helyx.Provider.ClaudeCode`, `Helyx.Provider.Codex`). A provider that sent the id it resumed again after a message, then compacted under it, would resume without the interrupted result. The provider contract does not forbid that order.
- `Transcript.resumable/3` finds an interrupted result by its value: an error result with the exact text. A tool that returns that exact text as an error makes the next start of a harness fresh, at the cost of one replay.

## Out of scope

- A record of the start of a tool call (decision 1).
- fsync of the session file (decision 3).
