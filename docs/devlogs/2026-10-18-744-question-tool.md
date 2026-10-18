# 2026-10-18: the question tool (#744)

Done:

- Core: `Helyx.Tool.ask/1` asks the clients from a running tool call and waits with no timeout. The session keeps the open asks (`Helyx.Session.Server.Asks`), emits `:ask` and `:ask_end`, and puts them in the snapshot. `Helyx.Session.answer/3` checks the answer (a JSON object of valid UTF-8, at most 16 KiB) and gives the first one to the call. A subscriber says that it answers with `subscribe(session, answers: true)`; with none, the ask returns `{:error, :no_client}` at once. The end of the turn ends every ask before `turn_end`.
- `Helyx.Tool.context/0` has the tool name; `ask/1` calls the session by its registry name. The end of a call ends its ask (`Asks.call_end/2`).
- The bundled tool `Helyx.Tool.Question` checks its arguments at the bounds of the ticket, asks, checks the answer against the questions, and returns `Q:`/`A:` blocks. With no client it tells the model to decide. The agent tool gives a child no `question` tool.
- Wire protocol 3: the operation `answer`, `answers` in `subscribe`, the events `ask` and `ask_end`, and `asks` in the snapshot.
- TUI: `Helyx.TUI.Question`, the picker in the place of the composer; the view model folds the asks; the TUI subscribes with `answers: true`.
- `Helyx.Session` went over 400 lines with `answer/3`, so `load/2` moved to `Helyx.Session.Server.Open` and the model lookup to `Helyx.Session.Input.model/2`.

What broke:

- `gh issue view 744 --comments` printed nothing, with exit 0. `gh issue view 744 --json title,body,comments,labels` gave the ticket.
- A raise in a tool Task gives the exception message as the error result, not "tool crashed": the first test of a bad request expected the wrong text.
- `tui.ex` went to 402 lines with the picker; one comment for the fields that take the place of the composer brought it to 400.

- Credo strict refused a 32nd field in `Helyx.Session.Server.State`, so the open asks live in `Helyx.Session.Turn`: they end with the turn.
- The merge gate found that an answer keyed by the call id could reach a later ask of the same call. Each ask now has a random id, the key of the answer, the events, the snapshot, and the wire op; protocol 3 stays.
- Rebased onto the skills work of master: the coding agent registers both tools, and `tui.ex` stays at 400 lines.
- Review: three rounds and a reduced round after the rebase, see `docs/reviews/2026-10-18-744-question-tool.md`. The work went over the 45 minutes of `/ship` to finish rounds 2 and 3, so that only reviewed code is committed; a usage limit stopped the session once, between rounds 2 and 3.

Next: none for this ticket. A web client renders the `question` request from `docs/features/question-tool.md`.
