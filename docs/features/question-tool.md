# Question tool

Ticket #744. Research: `docs/research/question-tool.md`.

## Goal

The model asks the user one to four questions, each with two to four options, and waits for the answers. Workflows such as `/hitl` ask the user to choose between options, and planning skills ask a clarifying question before work starts. Without the tool, the model can only end its turn with a question in prose.

User stories:

- The model calls `question`. The TUI shows a picker with the options and an "Other" line in the place of the composer. The user picks, the answers go back as the tool result, and the turn goes on.
- The user runs `helyx -p`. No user can answer, so the tool returns at once with a text that tells the model to decide, state the assumption, and go on.
- The user has the TUI open on the laptop and a web client on the phone. Both show the picker. The phone answers first; the laptop closes its picker.

Decisions (ticket #744, orchestrator, owner away):

1. **A bundled tool.** `Helyx.Tool.Question`, tool name `question`. Arguments: `questions`, a list of 1 to 4 items. Each item has `question` (the full text), `header` (a short label), `options` (2 to 4 items of `label` and `description`), and `multi_select` (a boolean, default false). The tool checks each argument at its entry; a bad argument gives an error result that names it.
2. **A tool asks the client: one generic Core construct.** A running tool call asks the clients of its session with `Helyx.Tool.ask/1` and waits for an answer. The session emits the event `:ask` with the call id, the tool name, and the request, a JSON object that the tool made. A client answers with `Helyx.Session.answer(session, call_id, answer)`. Core checks the answer at the boundary (a JSON object of valid UTF-8, at most 16 KiB encoded) and gives it to the tool. Core does not know the question shape: the TUI renders the request of the `question` tool because it is a client of the bundled tools. Reason: a permission prompt or another tool can use the same construct later, and Core stays free of the question shape.
3. **No client.** When no subscriber can answer, the ask returns `{:error, :no_client}` at once. The tool then returns the text "No user can answer in this run. Decide yourself, state the assumption in your answer, and go on."
4. **More than one client.** The first answer wins. The session emits `:ask_end` with `outcome: :answered`, so the other clients close their picker. A later answer gets `{:error, :not_waiting}`.
5. **Abort and stop.** The end of the turn (an abort, a failure, or a stop of the session through its abort) ends every ask of the turn: the session emits `:ask_end` with `outcome: :ended` before `turn_end`, and the hands kill the call, which gets its aborted result. A call whose result comes while it asks, such as a Task that dies, ends its ask the same way, and a later answer gets `{:error, :not_waiting}`. A stop of the session or of Core ends the session process, and the end signal closes the picker of each client.
6. **No deadline.** The wait has no time bound: a user can answer after hours. The abort is the bound.
7. **Not concurrent.** The question tool does not implement `concurrent?/0`, so one picker shows at a time. The construct itself allows one ask for each running call, so a concurrent tool can ask too (at most 8 at once, the cap of #734).
8. **Child sessions.** A child session of the agent tool gets no question tool: no user watches it. The agent tool removes `question` from the tool names of the child, as it removes `agent`. Its subscriber does not answer either, so a child that has the tool by a resume gets `:no_client`.
9. **The wire.** The WebSocket transport carries the two events, the `asks` of the snapshot, the `answers` param of `subscribe`, and the operation `answer` (`docs/features/wire-protocol.md`). The protocol number goes from 2 to 3.

Further decisions of this doc (owner away; the option that keeps Core smallest and matches the existing code):

- **A subscriber says that it can answer.** `Helyx.Session.subscribe/2` takes `answers: true`. The session counts a subscriber that gave it; `-p` mode and the agent tool do not give it, the TUI does, and a wire client gives `"answers": true` in `subscribe`. Reason: `-p` mode and the agent tool subscribe too, and a bot on the wire can read events and not answer. A subscriber that goes after the ask does not end it: the abort is the bound.
- **The ask belongs to a running call of the current turn.** The session takes an ask only while the call is running in the hands for the current turn. Any other ask, such as one from a background run or one that comes after the turn ended, gets `{:error, :not_running}`. So every ask ends with its turn, and a wait between turns holds none.
- **The tool name is in the event and in the context.** `Helyx.Tool.context/0` gets the key `tool`, the name of the called tool, and the ask passes it. A client dispatches the request to a renderer by the tool name, as it renders a call line by the tool name, and needs no transcript lookup.
- **The asks are state of the snapshot.** `Helyx.Session.Snapshot` gets `asks`, the open asks oldest first, so a client that joins during a wait shows the picker. A replay gives the events instead.
- **The request is plugin output.** `Helyx.Tool.ask/1` checks the request in the caller: a JSON object of valid UTF-8 whose JSON encode is at most 64 KiB. Any other request is a contract break and raises in the Task, which gives the generic error result of a crash. The largest request of the question tool is under the bound (see "Bounds").
- **The answer of the question tool** is `{"answers": [{"selected": [label], "other": text}]}`, one item for each question in order. `selected` holds the labels that the user picked (at most one without `multi_select`), and `other` the text of the "Other" line, or is absent. An item needs a label or a text. The tool checks the answer, because it comes from a client; an answer that does not fit the questions gives an error result.
- **The result text** is `The user answered:`, then one block for each question, with an empty line between them: a line `Q: <question>`, and a line `A: ` with the labels joined with `, `, then `other: <text>` when the user wrote one, joined with `; `.
- **The TUI picker** takes the place of the composer, and the composer keeps its text. Up and Down move, Space marks an option of a multi-select question, Enter picks the option or confirms the marks, and the next question shows. A typed character or a paste goes to the "Other" line and moves the cursor there; Enter takes the line when it is not empty, with the marks of a multi-select question. On a multi-select option with no mark, Enter takes the option under the cursor. After the last question, the TUI sends the answer. Escape aborts the turn, as everywhere, also over a search that the picker hides. An answer goes to the next question only while the answers so far, and the longest single option of each later question, fit the answer bound, so each later question can still be answered; else the question stays, and the footer says "not sent: the answers are over 16 KiB". A rejected send keeps the picker, and the footer says why. The TUI shows the oldest open ask of the `question` tool, and ignores an ask of another tool. An open `/resume` list keeps its place until it closes; the picker comes before an open search.

## Interface changes

- `Helyx.Tool.ask(request)`: `{:ok, answer} | {:error, :no_client | :not_running}`, in a tool call Task. Raises on a request that is not a JSON object of at most 64 KiB, and in any other process. It waits with no timeout.
- `Helyx.Tool.context/0`: the new key `tool`, the name of the called tool.
- `Helyx.Session.answer(session, call_id, answer)`: `:ok | {:error, :invalid_answer | :not_waiting | :session_not_found}`, with the call timeout of the session API.
- `Helyx.Session.subscribe/2`: the option `answers: boolean()`, default false.
- `Helyx.Session.max_answer_bytes/0`: the answer bound, 16,384, for a client that bounds its input to it.
- `Helyx.Event`: `:ask` with `%{call_id: String.t(), tool: String.t(), request: map()}`, and `:ask_end` with `%{call_id: String.t(), outcome: :answered | :ended}`. Both carry the turn id.
- `Helyx.Session.Snapshot`: `asks`, a list of `%{call_id, tool, request}`, oldest first.
- `Helyx.Tool.Question`: the bundled tool `question`, registered in `CodingAgent`.
- `Helyx.Tool.Agent`: the child gets the tools of the parent but `agent` and `question`.
- Wire: the events `ask` and `ask_end`, `asks` in the snapshot, `answers` in `subscribe`, the operation `answer` with the errors `invalid_answer` and `not_waiting`, protocol 3.
- TUI: `Helyx.TUI.Question`, the picker; `Helyx.TUI.ViewModel` folds the asks; the TUI subscribes with `answers: true`.

## Replaced mechanism

None. The subscriber entry of the session gets a fourth element, the `answers` flag, and the snapshot a new field; a tolerant reader ignores both.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| `questions` | 1 to 4 items | an error result | `Helyx.Tool.Question.run/2` |
| `options` of a question | 2 to 4 items, labels unique in the question | an error result | `Helyx.Tool.Question.run/2` |
| `question` | 1 to 1,000 bytes | an error result | `Helyx.Tool.Question.run/2` |
| `header` | 1 to 12 code points | an error result | `Helyx.Tool.Question.run/2` |
| `label` | 1 to 60 bytes | an error result | `Helyx.Tool.Question.run/2` |
| `description` | at most 300 bytes | an error result | `Helyx.Tool.Question.run/2` |
| a request | a JSON object of valid UTF-8, at most 65,536 bytes of JSON. The largest question request, four questions at every bound in their worst JSON form (each byte a control character, six bytes of JSON), is under it: a test checks it | raises in the Task: the generic error result | `Helyx.Tool.ask/1` |
| an answer | a JSON object of valid UTF-8 with no integer over 100 digits, at most 16,384 bytes of JSON | `{:error, :invalid_answer}`; the wire gives `bad_params` for a value that is not an object, and `invalid_answer` for the rest | `Helyx.Session.answer/3` |
| open asks of a session | one for each running call of the current turn: at most 8, the cap of #734 | n/a | `Helyx.Session.Server.Asks` |
| the wait for an answer | none: the end of the turn is the bound | n/a | accepted, decision 6 |
| answers to one ask | the first; a later one gets `{:error, :not_waiting}` | n/a | `Helyx.Session.Server.Asks` |
| the question text in the TUI picker | the 1,000 bytes of the tool, wrapped to the width; the picker is at most the room of the composer, and its question rows are cut to it | cut | `Helyx.TUI.Question` |
| "Other" text in the TUI | 16,384 bytes, the answer bound (`Helyx.Session.max_answer_bytes/0`): a longer text cannot pass it. The line shows the end of the text that fits the row | the cut drops the rest | `Helyx.TUI.Question` |
| the answers of the TUI picker | the JSON of the answers so far and the longest single option of each later question within 16,384 bytes, checked at each Enter | the question stays, and the footer says "not sent: the answers are over 16 KiB" | `Helyx.TUI.Question` |

Tests at the limits: 4 and 5 questions, 2, 4, and 5 options, a question of 1,000 and 1,001 bytes, a header of 12 and 13 code points with multibyte text, a label of 60 and 61 bytes, a description of 300 and 301 bytes, an answer of 16,384 and 16,385 bytes, and the largest request under 65,536 bytes.

## Ownership

None: the ask holds no external resource. The reply of the session to the Task is a message; a Task that the hands kill leaves an entry that the end of the turn removes.

## Out of scope

A permission prompt for other tools, a free-text-only question, a question from a provider (not a tool), and a timeout.
