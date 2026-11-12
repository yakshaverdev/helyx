# UI blocks

Ticket #878, part of #853. Builds ADR 0011 (`docs/adr/0011-ui-block-vocabulary.md`). The ADR holds the decisions and their reasons; this doc holds the shapes that the ADR leaves to it, the vocabulary, and the bounds.

## Goal

A tool, or the provider of a turn, shows the user a typed block, such as a form, a diff, or a progress item, and every client renders it from one shared vocabulary. A client that does not know a kind shows the fallback text of the block, so a new kind needs no client build and no new protocol number.

## Interface changes

### The UI block

A UI block is a JSON object with string keys, as a JSON decoder gives it: `%{"kind" => kind, "text" => text, ...fields}`, and `"cut" => true | false` when present. `Helyx.UIBlock` holds its check and its cut:

- `Helyx.UIBlock.check(value)` returns `{:ok, block}` for a UI block within the bound, `{:ok, cut}` for a UI block over it, where `cut` is `%{"kind" => kind, "text" => cut_text, "cut" => true}`, and `:error` for a value that is not a UI block (ADR 0011 §2). One walk checks the envelope, every string as valid UTF-8, every key as a string, every integer against the digit limit before any encode, and counts the bytes of the JSON encode without building it. It walks the whole value, so "over the bound" and "not a UI block" stay apart.
- `Helyx.UIBlock.key?(value)`: a key of a `:ui_block` event, valid UTF-8 of 1 to 64 bytes.
- `Helyx.UIBlock.envelope?(map)`: the checks of `kind`, `text`, and `cut` alone, for the request of an ask that has the key `kind`.

The cut text keeps its start and its end with the notice line and the marker line of `Helyx.Message.cut_result/1`, and its budget is the JSON encode of the whole replacement: a character that JSON escapes counts with its escaped size. The notice counts the raw bytes of the fallback text.

### In a tool result

- `Helyx.Tool.run/2` may also return `{:ok, text, ui_blocks}` or `{:error, text, ui_blocks}`, where `ui_blocks` is a list of UI blocks. The two-element returns stay and mean `ui_blocks: []`.
- `Helyx.Session.Hands.Run.tool/3` checks the list: a proper list of at most 8 blocks, each `check/1` not `:error`. Any other value is a return outside the contract: the error result "the tool returned a value outside its contract", with no blocks. A block over the bound is cut.
- `Helyx.Message` gets the field `ui_blocks`, a list, `[]` by default. Only a tool result message has blocks. The session holds the blocks of a Helyx call's result from the hands' result until the provider's `tool_result` event for that call, and puts them on the message that joins the transcript. They count in the 72 blocks of the turn: a result whose blocks do not fit keeps none. A result of a call that the transcript answered already, as at a taken steer, keeps none: its result does not join again, unless a reused call id opens the call again (#369): that result then joins with no blocks. A second run of the call, a reused call id (#369), replaces the held blocks of the first. The model never gets them: a provider sends `content` alone.
- The end of a background run (`docs/features/background-bash.md`) is a user message, not a tool result: the blocks of its return are dropped.
- The `after_tool` hooks (`docs/features/hooks.md`) get the result as `{status, text}`, the shape of their contract, without its blocks: the blocks are for the clients, and the hook contract has no field for them. A `:keep`, and a hook that fails, keep the blocks; a `{:replace, {status, text}}` gives a result with no blocks, because the hook replaced the whole result.
- The session file entry of a tool result has the key `ui_blocks` when the list is not empty. The reader keeps the first 8 blocks, drops each that fails `check/1`, cuts each over the bound, and drops a `ui_blocks` that is not a list or that is on a message that is not a tool result. It logs each drop. The message stays.

### In a `:ui_block` event

- `Helyx.Tool.show(key, block)` shows a block during a running call. It checks `key` and `block` in the caller and raises `ArgumentError` on a bad one, as `Helyx.Tool.ask/1` does; a block over the bound is cut. Then it waits for the session: `:ok`; `{:error, :not_running}` when the caller is not the recorded call Task of the call, or the call's result is already in the transcript; or `{:error, :too_many_blocks}` for a new block when the turn holds 72 blocks, and for a call whose request came past the Helyx call ids of the turn. A new key past 8 for the call raises. Raises outside a tool call.
- The record of a Task. The session keeps a record of each call Task and hook Task of the turn, which the hands send before the Task runs (`docs/features/hooks.md`, "The caller check of an ask"), and takes a block of a call only from the record of its call Task, as it takes an ask: a background run after its start answer, a hook Task, and a process that the tool started get `:not_running`. The records of a call end when its result joins the transcript, also an `aborted` result of a call that runs on, as at a taken steer, and with them its open asks (below); a Task of a call whose result is in the transcript already and that is not open again, a request that names an answered call (#369), also from an earlier turn, gets no record. So no block or ask of a call comes after its result. A request that comes before its tool call still runs (`docs/features/one-provider-path.md`, #369), and its Task's blocks show at once: a client shows a block of a call that it has no cell for at the end of the turn, then under its call. The bundled `Helyx.Provider.Loop` and `Helyx.Provider.Codex` stream a call before its request; for `Helyx.Provider.ClaudeCode` the order of its `assistant` line and its `tools/call` is not in a research note, and either order works.
- A provider sends the stream event `{:ui_block, call_id, key, block}`, with `call_id` nil or a non-empty string. `Helyx.Session.Stream.check/1` checks `key` and `block`, cuts a block over the bound, and makes any other shape a malformed event. The session drops a block whose `call_id` does not name an open call of the turn (in the open assistant message, or in the transcript with no result), or names a Helyx tool call of the turn. The session keeps the id of each Helyx tool request of the turn in a set, from the request to the end of the turn, in any order of the request and its tool call: a provider block that names an id of the set is dropped. A call that an approval request named (`docs/features/hooks.md`, "Harness approvals") is a call that the provider runs itself: its provider blocks show, while its chain runs and after, within the bound of the set (past it, every named provider block is dropped, above); an approval request for an id of the set is denied, as for a Helyx call (`Helyx.Session.Server.Approvals`); past the bound, a call whose request kept no id has no owner once Core answered it, and an approval for it runs, the accepted hole of `docs/features/hooks.md`, "The owner of a call id". The set holds at most 256 ids of at most 65,536 bytes together (a provider call id is about 30 bytes): a request past it runs as any other, but its id stays out of the set, so its call shows no blocks (its Task's `show/2` gets `{:error, :too_many_blocks}`, and its result keeps none); from then on the session cannot tell a call of the provider from a Helyx call, so it drops every provider block of the turn that names a call; a block with `call_id` nil still shows. A new block past the 72 of the turn is dropped. A new key past 8 for one `call_id` stops the provider process: the turn fails. A `tool_request` for a call that has blocks and is not in the set names a call that the provider ran itself, as only a provider block lands on such a call: a contract break, and the provider process stops, so a provider and a tool never share the keys of one call. A second request for an id of the set is a request as any other, which the tool queue runs or answers, as #369 lets a request for an answered id run, also when its Task showed blocks, unless its call still runs or waits in the tool queue: then it is a request for an open call id, which stops the provider (`docs/features/one-provider-path.md`).
- The event is `:ui_block` with `%{call_id: String.t() | nil, key: String.t(), block: map()}` and the turn id. A later block with the same `call_id` and `key` replaces the earlier one.
- `Helyx.Session.Snapshot` gets `ui_blocks`: the newest block of each pair of `call_id` and `key` of the running turn, each as the data of its `:ui_block` event, in the order of the first event of the pair, at most 72. A block that replaces the block of its pair counts no new block, so it passes at the cap. The blocks of a call leave when the call's result joins the transcript, and all of them at the end of the turn. A client drops them at the same points: the `tool_execution_end` of the call and `turn_end`.

### Through an ask

`Helyx.Tool.ask/1` and `Helyx.Hook.ask/1` keep their check of the request. A request with the key `kind` also passes `Helyx.UIBlock.envelope?/1`, or raises (`Helyx.Session.Ask`). A client picks the renderer of an ask by the `kind` of its request; a request with no `kind` is picked by the tool name. An ask, an input block, follows the record of its Task: when the call's result joins the transcript, an open ask of the call ends with `ask_end` `ended`, its caller gets `{:error, :not_running}`, and a later ask of the call's Tasks gets `{:error, :not_running}`.

### On the wire

`ui_blocks` in a tool result `message`, the `ui_block` event, the snapshot field `ui_blocks`, and protocol number 5 (`docs/features/wire-protocol.md`).

## The vocabulary

Each kind has its fields, its fallback rule, and, for an input kind, its answer shape. A kind never changes shape; a new shape is a new kind with a new name, and a name is never reused (ADR 0011 §5). A kind never defines `kind`, `text`, or `cut`.

### `form`

An input block: the request of an ask (ADR 0011 §4). The `question` tool sends it.

- Fields: `questions`, a list of 1 to 4 questions. A question is `question`, 1 to 1,000 bytes; `header`, 1 to 12 code points; `options`, 2 to 4 items of `label` (1 to 60 bytes, unique in the question) and `description` (at most 300 bytes); and `multi_select`, a boolean.
- `text`: a short line with the count of the questions, such as `2 questions`, not a copy of them, so the largest request stays under 65,536 bytes.
- Fallback: a client that cannot render a form shows `text` and gives no answer; the ask stays open for another client.
- Answer: `%{"answers" => answers}`, one item for each question in order: `selected`, the picked labels (at most one without `multi_select`), and `other`, a text of the user, or absent; an item needs one of them (`docs/features/question-tool.md`).

### `approval`

An input block: the request of an ask (ADR 0011 §4). The approval gate, `Helyx.Hook.Approval`, sends it from its hook Task with `Helyx.Hook.ask/1` (#882, `docs/features/approval-gate.md`).

- Fields: `tool`, the tool name of the call, a string; `provider`, nil for a Helyx tool call, or the id of the provider whose own tool it is, a string; `arguments`, the JSON text of the call's arguments, a string. The gate cuts `tool` and `provider` at 256 bytes and `arguments` at 16,384 bytes, at a character boundary, and sets `cut: true` when it cut one.
- `text`: `allow <tool>?`, or `allow <tool> of <provider>?`.
- Fallback: a client that cannot render an approval shows `text` and gives no answer; the ask stays open for another client, and the limit of the gate or the abort ends it.
- Answer: `%{"decision" => "allow"}` or `%{"decision" => "deny"}`. Any other answer is a deny.

### `diff`

A result block: `edit` and `write` send it with their result (`docs/features/diff-blocks.md`).

- Fields: `path`, the path argument of the call as the model gave it, cut at `Helyx.Diff.max_path_bytes/0` bytes at a character boundary; `added` and `removed`, the counts of the `+` and the `-` lines of the whole change, also when the hunks are cut; and `hunks`, 0 or more, each of `old_start`, `old_lines`, `new_start`, `new_lines`, and `lines`. Each line is one sign of `" "`, `"-"`, or `"+"`, then the line without its line end; a line over `Helyx.Diff.line_bytes/0` is cut at a character boundary with ` …` appended. `added` and `removed` are absent when no diff was made: a write that cannot read the old file, and a change over a bound of `Helyx.Diff`. A change of only a line end or of the final newline has no hunk, and its `text` says so.
- `text`: the unified diff. It is the header `--- a/<path>` and `+++ b/<path>`, then for each hunk `@@ -o,ol +n,nl @@` and its lines. A client shows it as the fallback.
- `cut: true` when the emitter left out lines or cut a line. The emitter also cuts at `Helyx.Diff.budget_bytes/0` bytes of lines, counted once although each line is in `text` and in `hunks`, so a block stays near 50 KB and under the 65,536-byte bound of `Helyx.UIBlock.check/1` in most cases. The session cuts a block that is still over the bound to `{kind, text, cut: true}`, and a client then shows the text.
- Fallback: a client that cannot render `diff` shows `text`.

### `todo`

The plan of the current task. The `todo` tool sends the block with its result, not as the request of an ask (`docs/features/todo-tool.md`).

- Fields: `items`, a list of 1 to `Helyx.Tool.Todo.max_items/0` items, each with `text` of 1 to `Helyx.Tool.Todo.max_item_bytes/0` bytes and no new line, and `status` (`pending`, `in_progress`, or `done`), with at most one item `in_progress`.
- `text`: one line for each item, `[x] <text>` for done, `[>] <text>` for in progress, `[ ] <text>` for pending, then a line `<done>/<total> done`.
- Fallback: a client that cannot render a `todo` shows `text`, which reads as the checklist.
- No answer: the block rides on a result, so no client sends anything back.

### Later kinds

The candidates after `form`, `approval`, `diff`, and `todo` are `choice`, `table`, `progress`, and `link`. Each gets its entry here with the ticket that builds it.

### Rendering in the TUI

The TUI renders `form` with the picker of `Helyx.TUI.Question`, and `approval` with the picker of `Helyx.TUI.Approval` (`docs/features/approval-gate.md`, "The TUI renderer"), in the place of the composer: the oldest open ask of the two that the TUI can read. Every other kind shows its `text`, with a cut mark when `cut` is true, under its tool result or, for a `:ui_block` event, under its call or at the end of the turn. The text is cleaned and wrapped as a tool result text, and shows four lines and a hint row in the short form of Ctrl+O (`docs/features/tui-tool-output-toggle.md`). A block of a call shows under the oldest open cell of its call id; a block whose call has no cell in the transcript shows at the end of the turn. An ask of a kind that the TUI does not know shows the `text` of its request under its call line until its `ask_end`, and the TUI gives no answer.

### Rendering in the client kit

The Rust core of the client kit (`clients/rust/core`, #885) reads a block that it checked into a model, `vocabulary::UiBlock::read`: its `kind`, its `text`, its `cut`, and a view, `Form` or `Approval` for a known kind whose fields it can read by the entries above (the bounds of `form` as the TUI reads them: a `multi_select` that is absent is a single pick, a null one is not readable), and `Text` for any other kind or fields. `Ask::block` gives the block of an ask whose request has a `kind`; an ask with no kind gives none. `transcript::open_calls` gives the row of the oldest open call of each call id.

The GPUI app draws a `form` with its questions, headers, and options (a mark for a single and a multiple pick), an `approval` within the bounds of `Helyx.TUI.Approval` (its `text` as the title, at most 1,024 bytes on one line; its tool and provider, at most 256 bytes each, the cut of the gate; and its arguments in a monospace box of at most 16,384 bytes, with a line `… more arguments` when a part is left out), and every other block as its `text`, at most 65,536 bytes, the bound of a block, since the client does not check the size of an ask request; each with a mark `[cut]` when `cut` is true or a part of the text is left out. Each cut is at a character boundary (`vocabulary::head`, with `MAX_TITLE_BYTES`, `MAX_NAME_BYTES`, and `MAX_ARGUMENTS_BYTES`). A block of a tool result draws under its result; a block of a `ui_block` event and the block of an ask draw under the oldest open call of their call id, else at the end of the turn, as in the TUI. The app answers an ask of a kind that it reads (`clients/rust/app/src/ask.rs`): the oldest open `form` or `approval` takes the keys in the place of the composer, and a click on an option or on Allow and Deny answers too. A form follows the TUI picker: one question at a time, a cursor over its options and its Other line, Space marks only a multiple pick (a single pick is the option under the cursor at Enter), the marks go out in option order and only the question that the keys act on shows them, a paste on the Other line is one line, Enter takes the marks, and the Other line is bound to the answer bound. It sends `{"answers": [{"selected": [label], "other": text}]}`, one item for each question in order, and an approval sends `{"decision": "allow"}` or `{"decision": "deny"}`; an answer over 16,384 bytes, or one that leaves no room for a later question, is not sent, and the panel says why. The panel stays closed while the answer's request is pending or after it got `ok`, and opens again with its last answer when the send was refused, the server answered an error, or the reply was lost, because the user decides (ADR 0006 §4). An ask of a kind that the app cannot read shows its text and the line `this app cannot answer this ask; another client can`; an ask whose request has no `kind` is not drawn. Both stay open for another client (ADR 0011 §4). Tests: `clients/rust/core/tests/vocabulary.rs` reads every UI block of `server_frames.json`, the fields at their bounds, and the cut of a drawn text at a character boundary; `tests/transcript.rs` the placement; `clients/rust/app/src/ask.rs` builds the answer of each kind, marks a multiple pick, takes the Other line, and refuses an answer over the bound. The window has no test: it draws the models that the core and the app's `ask` tests prove.

## Replaced mechanism

One code path: the choice of the question picker in the TUI.

1. Old rule: `Helyx.TUI.Question.sync/1` opened the picker for the oldest ask of the tool `question`, and trusted the shape of its request, because the bundled tool checked it. New rule: the picker opens for an ask whose request has the kind `form` and fields that the TUI can read (the fields of `form` above), from any tool, and for a request with no kind from the tool `question` with the same fields. Any other ask with a kind shows its `text`; an ask with no kind shows nothing. Neither gets an answer from this client.
2. No reply is removed: the answer goes back with the `answer` operation as before.
3. The tests of the old picker (`plugins/bundled/test/helyx/tui/question_test.exs`) keep their property: a `question` ask opens the picker, and its answer has the shape of `docs/features/question-tool.md`. They now send a `form`. The new tests are in `plugins/bundled/test/helyx/tui/ui_blocks_test.exs`.
4. A user sees the picker for a form of any tool, and the fallback text for an ask that the TUI cannot render, where before such an ask showed nothing.
5. No state without a bound.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| one UI block | 65,536 bytes of JSON (`Helyx.Message.max_result_bytes/0`) | cut to `{kind, text, cut: true}`, with the cut text within the bound | `Helyx.UIBlock.check/1`, in every carrier and at file read |
| an integer in any field | 100 digits (`Helyx.Message.max_integer_digits/0`), tested before any encode | not a UI block: the carrier's generic path; dropped at file read | `Helyx.UIBlock.check/1` |
| `kind` | 1 to 64 bytes of `a`-`z`, `0`-`9`, `_` | not a UI block | `Helyx.UIBlock.check/1` |
| `key` of a `:ui_block` | valid UTF-8 of 1 to 64 bytes | raises in the Task; a malformed provider event | `Helyx.Tool.show/2`, `Helyx.Session.Stream.check/1` |
| UI blocks of one tool result | 8, so at most 512 KiB a result. A session file grows by at most that for each tool result; the 64 MiB file bound of the reader stays | live: a return outside the contract; at file read: the blocks past 8 are dropped | `Helyx.Session.Hands.Run`, `Helyx.Session.File.Codec` |
| keys of `:ui_block` for one call, and with `call_id` nil in one turn | 8 each | a raise in the Task; the provider process stops | `Helyx.Session.Server.UIBlocks` |
| UI blocks that one turn holds: of its `:ui_block` events, which the snapshot gives, and of the Helyx results that wait for their `tool_result` event (`held_results`) | 72 together (`Helyx.UIBlock.max_turn_blocks/0`), the keys of 8 calls and of nil. A call keeps its blocks until its result joins the transcript, and a provider can hold results back (`Helyx.Provider.Loop` sends them in call order), so more than 8 calls can hold blocks: the cap counts the blocks, not the calls. At most 72 blocks of 65,536 bytes, 4.5 MiB | a new block from a tool: `{:error, :too_many_blocks}`; from the provider: dropped; a result whose blocks do not fit keeps none. A replace passes | `Helyx.Session.Server.UIBlocks` |
| Helyx call ids of a turn (`helyx_calls`) | 256 ids, and 65,536 bytes of ids together, from each request to the end of the turn: about 8 KiB for 256 provider ids | the request runs; its call shows no blocks (`{:error, :too_many_blocks}` to its `show/2`, a result with none); the provider blocks of the turn that name a call are dropped from then on | `Helyx.Session.Server.UIBlocks` |
| records of call and hook Tasks | one for each live Task of the turn, as the hands start them (`docs/features/hooks.md`); the result of the call in the transcript ends them | n/a | `Helyx.Session.Server.Asks` |
| `:ui_block` events | no rate cap: the emit is a call that waits for the session, and the credits and the transport bound the bytes queued to a subscriber (ADR 0011, "Bounds") | the slow close of ADR 0008 | accepted |
| one form request | 65,536 bytes of JSON, the ask bound | raises in the Task | `Helyx.Tool.ask/1` |

Tests at the limits: a block of 65,536 and 65,537 bytes of JSON, with escaped characters and with multibyte text; 8 and 9 blocks in a result; 8 and 9 keys for one call and for `call_id` nil; 72 and 73 blocks of a turn, from a tool and from the provider, and with the blocks of a held result; 256 and 257 Helyx call ids of a turn, and ids of 65,536 and 65,537 bytes together; a `kind` of 64 and 65 bytes; a key of 64 and 65 bytes; an integer of 100 and 101 digits in a field of a block in each carrier and on a file read; the largest form request.

## Ownership

None: a UI block holds no external resource.

## Out of scope

A render tree or a layout language; styling, themes, and images; a client extension that adds a renderer. The approval gate and its `approval` kind are in `docs/features/approval-gate.md` (#882).
