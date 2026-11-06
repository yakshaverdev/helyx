# A typed UI block vocabulary on the wire

Ticket #858 (owner decision of 2026-11-06), part of #853. Built by later tickets; this ADR changes no code.

User stories:

- A product adds a mode whose tool shows a diff, a table, or a progress item. The TUI and the client kit of #860 show it natively, with no client build.
- A user runs a client that is older than the server. A tool sends a UI block of a kind that this client does not know. The client shows the fallback text of the block, and the session goes on.
- The model calls `question`. The client shows a form, and the answer goes back with the `answer` operation, as today (`docs/features/question-tool.md`).

## Context

- A client renders text, thinking, tool calls, and the picker of the `question` tool. A tool returns text only: `Helyx.Tool.run/2` returns `{:ok, text} | {:error, text}`, and `Helyx.Session.Hands.Run.tool/3` turns any other return into the error result "the tool returned a value outside its contract". An approval, a choice, a diff, a table, or a progress item can only be text, so each new product needs a client change.
- The ask of #744 is already a generic construct: a running call asks with `Helyx.Tool.ask/1`, a JSON object of valid UTF-8 of at most 65,536 bytes of JSON, the session emits `:ask`, and a client answers with `Helyx.Session.answer/3`, checked by `Helyx.Session.check_answer/1` (at most 16,384 bytes). Core does not know the question shape; the TUI picks its renderer by the tool name.
- Event is data, not an interface (AGENTS.md, and the extension surface of ADR 0009). Core does not name the kinds of a vocabulary that only plugins and clients share.
- "Block" already names a content block of a message: text, thinking, and tool call (ADR 0001). This ADR names the new thing a **UI block**, so the two never mix: a content block is what the model and the provider see; a UI block is what a client shows.

## Decision

### 1. A UI block

A UI block is a flat JSON object:

```text
ui_block = {kind: string, text: string, ...the fields of the kind}
```

- `kind` names the type of the block, for example `form`, `diff`, `table`, `progress`: 1 to 64 bytes of `a` to `z`, `0` to `9`, and `_`, so it needs no JSON escape.
- `text` is the fallback text: what a client shows for a kind that it does not know, or for a block of a known kind whose fields it cannot read. Every block has it.
- The other keys are the fields of the kind. No field holds a UI block: a block is flat in the first version.

The vocabulary, not a layout tree: the server owns the state, the client owns the layout. A client renders a kind natively and decides how it looks.

### 2. The check, in Core, with one bound

Core checks the envelope of each UI block at the boundary where it enters, as it checks tool arguments and an ask request: a JSON object of valid UTF-8, with `kind` a name of §1, `text` a string, and `cut`, when present, a boolean. Core does not read the other fields and names no kind.

The bound of one block is `Helyx.Message.max_result_bytes/0`, 65,536 bytes, counted as the bytes of its JSON encode. The same check and the same bound apply in both carriers of §3.

The check walks the whole block once and counts the bytes of its encode, escapes included, without building the encode or an escaped copy of a string, so it tells "not a UI block" from "over the bound". A size-bounded walk that stops past the limit, such as `Helyx.Session.Input.json_object/2`, answers both with one `:error` and does not suffice. The walk adds no copy of the block: the block is already a term in the emitter's process, or part of a file that the reader bounds at 64 MiB.

- **Over the bound.** A block that passes the envelope check, is JSON of valid UTF-8 in every field, and is over the bound is cut as a tool result is cut: Core replaces it with `{kind, text, cut: true}`, where `text` is its fallback text cut as `Helyx.Message.cut_result/1` cuts a result (start and end kept, a notice line). The budget of that cut is the JSON encode of the whole replacement, not the raw bytes of the text: a character that JSON escapes counts with its escaped size, so `cut_result/1`, whose budget is fixed raw bytes, is not enough, and the build adds a cut with a budget. With `kind` at most 64 bytes, the replacement always fits. The fields of the kind are dropped. So the bound holds for every block that a client gets, and a big `table` or `diff` costs its block, not the result or the turn.
- **`cut: true`** means the block was cut. An emitter that cuts its own block under the bound, such as a `table` that keeps the first rows, sets it too and keeps the fields of its kind. A client renders a block of a known kind whose fields it can read, with a cut mark when `cut` is true, and the fallback text otherwise.
- **Not a UI block.** A value that fails the envelope check is a contract break of its carrier, and takes the generic path of that carrier (§3). It gets no special handler.
- `kind`, `text`, and `cut` are the envelope. A kind never defines a field with one of these names.

### 3. Where a UI block travels: both carriers

**In a tool result.** A tool can return UI blocks with its result. The tool result message gets a field `ui_blocks`, a list, empty by default, next to `content`. It is in the session file, in a tail snapshot, and in the `message` of the wire, so a client that joins later shows it.

- The model never gets a UI block. `content` stays the text that the tool returned for the model, and a provider sends `content` alone. A tool that wants the model to see what the block shows puts it in its text. Reason: no provider changes, and a block does not double the context.
- A return whose blocks fail the check of §2 is a return outside the contract: the error result of `Helyx.Session.Hands.Run.tool/3`.
- A UI block rides only on the result of a Helyx tool (`run/2`). The `:tool_result` stream event of a provider carries none in the first version; a harness provider that wants to show a block uses the event below.
- **Count.** A tool result holds at most a count of UI blocks that the feature doc sets. A return over it is a return outside the contract, as above. With each block within 65,536 bytes, the count bounds the bytes of `ui_blocks`; they do not count against the content bounds of a message.
- The session file is a boundary, and the model never saw a UI block, so the reader rejects the smallest unit and keeps the message: a block that fails the check is dropped, a block over the bound is cut as above, the blocks past the count are dropped, and a `ui_blocks` that is not a list, or that is on a message that is not a tool result, is dropped as a whole. The conversation does not change, and the reader logs each drop. The file-read bound of #673 (1,024 content blocks for a message, `lib/helyx/session/file/codec.ex`) counts content blocks only. A message at read has no byte bound of its own, only the 64 MiB of the file and the heap cap of its parse (`lib/helyx/session/file.ex`). UI blocks make a file grow faster: a session whose file passes those caps fails to resume, as any session does today. Accepted; the feature doc sets the count of blocks with it in mind.

**In a dedicated event.** During a call or a turn, an emitter can show a UI block that is not a result, such as a progress item. The session emits the event `:ui_block` with `%{call_id: String.t() | nil, key: String.t(), block: ui_block}`, with the turn id.

- The emitters are a running tool call, through a new function of `Helyx.Tool` that checks the block in the caller as `Helyx.Tool.ask/1` checks its request (a bad block raises in the Task: the generic error result of a crash), and the provider of the turn, through a new stream event that `Helyx.Session.Stream.check/1` checks (a bad block is a malformed event: the provider process stops and the turn fails). A hook of #563 that wants to show a block uses the path that #563 decides.
- The function of `Helyx.Tool` is a call that waits for the session, as `ask/1` is, so the session mailbox gets back-pressure. The session takes a block only from a running call of the current turn, as it takes an ask; any other caller, such as a background run, gets `{:error, :not_running}`.
- A provider names in `call_id` only a call that it runs itself: an open call of the turn that is not a Helyx tool call. `Helyx.Session.Stream.check/1` runs in the provider process and has no turn state, so the session checks the call id. A provider block whose call id names any other call is dropped, as a provider `tool_result` of an unknown id is dropped (`lib/helyx/session/server/records.ex`: "A result for no open call is dropped"): a block can be on its way when its call ends, so a valid provider can send one. Only the Task of a Helyx tool call shows blocks for that call, so a provider and a tool never share the keys of one call.
- The keys of one call, and the keys with `call_id` nil in one turn, are each at most a count that the feature doc sets. A block with a new key past it is a contract break of its emitter: the raise in the Task, or the malformed event.
- `key` is the emitter's name for the block, a string of 1 to 64 bytes, checked with the block. A later `:ui_block` with the same call id and key replaces the earlier one, so a progress item updates in place; blocks with other keys show side by side. With `call_id` nil, the key names the block within the turn.
- A UI block of an event is not in the transcript or the session file, as a `notice` is not. A client drops the blocks of a call at its result, and the blocks of a turn at `turn_end`. The snapshot is the fold of the same events: the newest block of each pair of call id and key, for the calls of the running turn that have no result yet, and for `call_id` nil. So a client that joins during a call shows its progress, and one that joins after the result shows none; a reconnect with `after` gets the events from the replay ring.

### 4. Replies reuse the ask and the `answer` operation

A UI block that takes input, such as `form` or `approval`, travels as the request of an ask (`Helyx.Tool.ask/1`), not in a result or a `:ui_block` event. The request of such an ask is the UI block itself. Its vocabulary entry names the answer shape that it expects. The client answers with the `answer` operation, which Core checks as today (`Helyx.Session.check_answer/1`, 16,384 bytes). The ask keeps its own rules (`docs/features/question-tool.md`): its request bound is the same 65,536 bytes of JSON, and a request over it is a contract break, not cut, because a cut form cannot be answered. A request that has the key `kind` also gets the checks of `kind`, `text`, and `cut` of §2 in `Helyx.Tool.ask/1`; the check of JSON, UTF-8, and size there today stays and is not repeated. A request that fails raises in the Task, the generic error result, as a request over the bound does today.

- A client picks the renderer of an ask by the `kind` of its request; a request with no `kind` is an ask of a tool that is not on the vocabulary yet, and the client picks by the tool name, as the TUI does today.
- A client that does not know the kind of an input block shows its text and gives no answer. The ask stays open for another client, and the abort is the bound, as for any ask.
- `form` is the first UI block: the `question` tool is rewritten so that its request is a `form` block and its answer shape is the answer of `docs/features/question-tool.md`. The largest question request today is under 65,536 bytes (`docs/features/question-tool.md`, "Bounds"), but not by enough for a second copy of the questions, so the `text` of a `form` is a short line, such as the count of questions, not a copy of them; the test of the largest request stays and checks the form.

### 5. Versioning

- The vocabulary is a document that the emitting plugins and the clients share: `docs/features/ui-blocks.md`, written by the first build ticket. Each kind has its fields, its fallback rule, and, for an input kind, its answer shape.
- A kind never changes shape. A new shape is a new kind with a new name, and a name is never reused. Each kind is its own version, so the vocabulary has no version number.
- A client that gets a kind that it does not know shows the fallback text. So a new kind needs neither a client build nor a new protocol number: the wire schema has the envelope of §1 and no kind.
- The wire protocol number changes once, when the build adds `ui_blocks`, the `ui_block` event, and the snapshot field (ADR 0008 §7).

### 6. The TUI is the first client

The TUI renders UI blocks first: `form` with the picker of `Helyx.TUI.Question`, then each kind that a build ticket adds, and the fallback text for any other kind. The client kit of #860 renders the same kinds from the same document.

## Bounds

| Input | Bound | Over it |
|---|---|---|
| one UI block | 65,536 bytes of JSON, `Helyx.Message.max_result_bytes/0`, in both carriers | cut to `{kind, text, cut: true}` (§2) |
| `kind` of a UI block, `key` of a `:ui_block` event | `kind`: 1 to 64 bytes of `a`-`z`, `0`-`9`, `_`; `key`: 1 to 64 bytes of valid UTF-8 | not a UI block: the generic path of the carrier |
| one input block, the request of an ask | 65,536 bytes of JSON (`Helyx.Tool.ask/1`) | raises in the Task: the generic error result |
| an answer | 16,384 bytes of JSON (`Helyx.Session.check_answer/1`) | `{:error, :invalid_answer}` |
| UI blocks of one tool result | a count that the feature doc sets; with each block within its bound, the count bounds the bytes | live: a return outside the contract, the error result; at file read: the blocks past it are dropped |
| keys of `:ui_block` for one call, and with `call_id` nil in one turn | a count that the feature doc sets; with the 8 calls at once of #734, it bounds the blocks of the snapshot | a contract break of the emitter: the raise in the Task, or the malformed event |
| `:ui_block` events | no rate cap in Core. The emit is a call that waits for the session. Each event holds one block within its bound, so it is smaller than a `message_end`, which can hold a message of 8 MiB; the bytes queued to a subscriber are bounded as for every event, by the credits and the transport (ADR 0008 §5: the credits count events, and the byte bound is in the transport) | the slow close of ADR 0008. Accepted: a tool that updates a block in a tight loop fills the replay ring (1,024 events and 4 MiB, about 64 updates of 64 KiB), so a reconnect gets a tail snapshot instead of a replay; the snapshot holds the newest block of each call id and key, so the client still shows the right state. The feature doc can add a rate cap |
| nesting | none: a field holds no UI block | the vocabulary defines no such field |

## Considered options

- **A tool result only.** Rejected (the owner chose both): a progress item during a long call has no result to ride on.
- **A dedicated event only.** Rejected (the owner chose both): a block that is not in the transcript is gone for a client that joins after the replay ring, and a diff of an edit belongs to its result.
- **UI blocks as a new content block of the message.** Rejected: every provider would map or skip it, and the model would read what is meant for the user.
- **A layout tree or a render language.** Rejected: the client would lose its own layout, and the server would own a view.
- **A vocabulary version number, with compatible changes to a kind.** Rejected by the owner: a new shape is a new kind, so a client never meets a known kind in a shape that it does not know.
- **Core names the kinds and checks their fields.** Rejected: Core knows only interface constructs; the kinds belong to the plugins and the clients that share the document.

## Consequences

The later tickets build:

- `Helyx.Message`: the field `ui_blocks` of a tool result message, and ADR 0001 gets an update for it; the session file reader checks and cuts it.
- `Helyx.Tool`: the return of `run/2` with UI blocks (its exact shape in the feature doc), the check in `Helyx.Session.Hands.Run.tool/3`, and the function that emits a `:ui_block` event in a call.
- `Helyx.Session.Stream.check/1`: the stream event of a provider that carries a UI block.
- `Helyx.Event`: `:ui_block`. `Helyx.Session.Snapshot`: the fold of §3, the newest block of each call id and key of the running turn.
- The wire (`docs/features/wire-protocol.md`): `ui_blocks` in `message`, the `ui_block` event, the snapshot field, and a new protocol number.
- `docs/features/ui-blocks.md`: the vocabulary, with `form` first. The candidates after it are `choice`, `diff`, `table`, `progress`, and `link`; `approval` comes with the approval hook of #563.
- `Helyx.Tool.Question`: its request becomes a `form` block. The TUI picks the picker by the kind.
- The TUI renders each kind, and the fallback text for the others. The client kit of #860 builds the block models from the same document.

Out of scope: a general render tree or layout language; styling, themes, and images; a client extension that adds a renderer (a later ticket of the client kit).
