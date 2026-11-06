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
- `Helyx.Message` gets the field `ui_blocks`, a list, `[]` by default. Only a tool result message has blocks. The session holds the blocks of a Helyx call's result from the hands' result until the provider's `tool_result` event for that call, and puts them on the message that joins the transcript. The model never gets them: a provider sends `content` alone.
- The end of a background run (`docs/features/background-bash.md`) is a user message, not a tool result: the blocks of its return are dropped.
- The session file entry of a tool result has the key `ui_blocks` when the list is not empty. The reader keeps the first 8 blocks, drops each that fails `check/1`, cuts each over the bound, and drops a `ui_blocks` that is not a list or that is on a message that is not a tool result. It logs each drop. The message stays.

### In a `:ui_block` event

- `Helyx.Tool.show(key, block)` shows a block during a running call. It checks `key` and `block` in the caller and raises `ArgumentError` on a bad one, as `Helyx.Tool.ask/1` does; a block over the bound is cut. Then it waits for the session: `:ok`, or `{:error, :not_running}` when the call is not a running call of the current turn, or its result is already in the transcript (an `aborted` result of a call that runs on, as at a taken steer), or its call was not open at its tool request. The window of a Helyx call's blocks is from its tool request to its result in the transcript, and only a request for an open call (in the open assistant message, or in the transcript with no result) opens it: the session admits a block of the call's Task only in it, and a provider block for the call never, so a provider and a tool never share the keys of one call. A request for a call with no open tool call, one that already has its result or one that the provider has not streamed, still runs (`docs/features/one-provider-path.md`, #369), but opens no window: its Task shows no block, and its result message carries no blocks. The bundled providers stream a call before its request (`Helyx.Provider.Loop`, the item of `Helyx.Provider.Codex`); for `Helyx.Provider.ClaudeCode` the order of its `assistant` line and its `tools/call` is not in a research note, and a call whose request comes first shows no block. Open (review round 4 of #878): such a request leaves no mark of a Helyx call, so once the call is open a provider block for it is admitted, against the drop rule above. The tool's Task is refused, so the two still share no key, and no bundled provider sends a `ui_block` event. A new key past 8 for the call raises. Raises outside a tool call.
- A provider sends the stream event `{:ui_block, call_id, key, block}`, with `call_id` nil or a non-empty string. `Helyx.Session.Stream.check/1` checks `key` and `block`, cuts a block over the bound, and makes any other shape a malformed event. The session drops a block whose `call_id` does not name an open call of the turn (in the open assistant message, or in the transcript with no result) or names a Helyx tool call of the turn. A new key past 8 for one `call_id` stops the provider process: the turn fails. A `tool_request` for a call that already has provider blocks names a call that the provider ran itself: a contract break, and the provider process stops, so a provider and a tool never share the keys of one call.
- The event is `:ui_block` with `%{call_id: String.t() | nil, key: String.t(), block: map()}` and the turn id. A later block with the same `call_id` and `key` replaces the earlier one.
- `Helyx.Session.Snapshot` gets `ui_blocks`: the newest block of each pair of `call_id` and `key` of the running turn, each as the data of its `:ui_block` event, in the order of the first event of the pair. The blocks of a call leave when the call's result joins the transcript, and all of them at the end of the turn. A client drops them at the same points: the `tool_execution_end` of the call and `turn_end`.

### Through an ask

`Helyx.Tool.ask/1` keeps its check of the request. A request with the key `kind` also passes `Helyx.UIBlock.envelope?/1`, or raises. A client picks the renderer of an ask by the `kind` of its request; a request with no `kind` is picked by the tool name.

### On the wire

`ui_blocks` in a tool result `message`, the `ui_block` event, the snapshot field `ui_blocks`, and protocol number 4 (`docs/features/wire-protocol.md`).

## The vocabulary

Each kind has its fields, its fallback rule, and, for an input kind, its answer shape. A kind never changes shape; a new shape is a new kind with a new name, and a name is never reused (ADR 0011 §5). A kind never defines `kind`, `text`, or `cut`.

### `form`

An input block: the request of an ask (ADR 0011 §4). The `question` tool sends it.

- Fields: `questions`, a list of 1 to 4 questions. A question is `question`, 1 to 1,000 bytes; `header`, 1 to 12 code points; `options`, 2 to 4 items of `label` (1 to 60 bytes, unique in the question) and `description` (at most 300 bytes); and `multi_select`, a boolean.
- `text`: a short line with the count of the questions, such as `2 questions`, not a copy of them, so the largest request stays under 65,536 bytes.
- Fallback: a client that cannot render a form shows `text` and gives no answer; the ask stays open for another client.
- Answer: `%{"answers" => answers}`, one item for each question in order: `selected`, the picked labels (at most one without `multi_select`), and `other`, a text of the user, or absent; an item needs one of them (`docs/features/question-tool.md`).

### Later kinds

The candidates after `form` are `choice`, `diff`, `table`, `progress`, and `link`; `approval` comes with the approval hook (ADR 0013). Each gets its entry here with the ticket that builds it.

### Rendering in the TUI

The TUI renders `form` with the picker of `Helyx.TUI.Question`. Every other kind shows its `text`, with a cut mark when `cut` is true, under its tool result or, for a `:ui_block` event, under its call or at the end of the turn. The text is cleaned and wrapped as a tool result text, and shows four lines and a hint row in the short form of Ctrl+O (`docs/features/tui-tool-output-toggle.md`). A block of a call shows under the oldest open cell of its call id; a block whose call has no cell in the transcript shows at the end of the turn. An ask of a kind that the TUI does not know shows the `text` of its request under its call line until its `ask_end`, and the TUI gives no answer.

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
| keys of `:ui_block` for one call, and with `call_id` nil in one turn | 8 each. With 8 calls at once (#734), the snapshot holds at most 72 blocks of a running turn, under 5 MiB | a raise in the Task; the provider process stops | `Helyx.Session.Server.UIBlocks` |
| blocks of Helyx results held for the provider's echo (`helyx_calls`) | one entry for each Helyx tool request of the turn whose call was open at the request and whose result has not joined the transcript, each at most 8 blocks. Every open call gets its result at a close or at the end of the turn, so every entry ends with it | n/a | `Helyx.Session.Server.UIBlocks` |
| `:ui_block` events | no rate cap: the emit is a call that waits for the session, and the credits and the transport bound the bytes queued to a subscriber (ADR 0011, "Bounds") | the slow close of ADR 0008 | accepted |
| one form request | 65,536 bytes of JSON, the ask bound | raises in the Task | `Helyx.Tool.ask/1` |

Tests at the limits: a block of 65,536 and 65,537 bytes of JSON, with escaped characters and with multibyte text; 8 and 9 blocks in a result; 8 and 9 keys for one call and for `call_id` nil; a `kind` of 64 and 65 bytes; a key of 64 and 65 bytes; an integer of 100 and 101 digits in a field of a block in each carrier and on a file read; the largest form request.

## Ownership

None: a UI block holds no external resource.

## Out of scope

A render tree or a layout language; styling, themes, and images; a client extension that adds a renderer; the rendering in the Rust core and the GPUI app (#885); the approval gate (#882).
