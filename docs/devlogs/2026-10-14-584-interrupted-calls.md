# 2026-10-14: interrupted tool calls (#584)

Done:

- The resume read gives each open tool call `Helyx.Session.Transcript.interrupted_result/0`: the session stopped while the call ran, the call may have run, check before a repeat. A live abort keeps `aborted`. No new file entry.
- The lost end of a background run (#577) has the same form.
- `Transcript.resumable/3` gives no id to a harness whose id came before a message with an interrupted result, so the harness starts fresh and reads the result in the replay.
- The durability rule of the session file is in `docs/features/coding-agent.md`, "Session file".

What broke: round 1 found that a harness resumed its own session and never read the text; round 2 found that the first fix also dropped an id that a fresh start compacted. See `docs/reviews/2026-10-14-584-interrupted-calls.md`.

Next: the sibling outside #584. A live end path writes `aborted` results that a dead provider process never got, and the provider still resumes under its id. It needs its own ticket.
