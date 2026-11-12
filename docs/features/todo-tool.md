# The todo tool

Adds the `todo` kind to the UI block vocabulary (`docs/features/ui-blocks.md`, "The vocabulary"). The vocabulary builds ADR 0011 (`docs/adr/0011-ui-block-vocabulary.md`).

## Goal

A user supervises several agents at once. For a task of more than a few steps, the agent writes its plan with the `todo` tool and updates it as it works. Every client shows the plan under the call as a checklist: the done items checked, the current item marked, the pending items open. A glance shows how far each agent is.

The same lines come back to the model as the result of the call, so a long turn keeps the plan in the conversation without a reminder.

The tool holds no plan of its own. A plan that the tool kept would need an owner row and a session field for state that the newest result already holds, and a client that joins later reads the newest `todo` result from the transcript. Reason: the session is the state, and the tool is the message.

The tools research (`docs/research/coding-tools.md`) records a plan tool in the default tool set that it compares. This tool states the same idea in the Helyx shape: a result text for the model and a UI block for the client.

## Interface changes

### `Helyx.Tool.Todo`

A bundled tool, `plugins/bundled/lib/helyx/tool/todo.ex`, registered in `CodingAgent.plugins/0` after `Helyx.Tool.Question`.

- `name/0` is `"todo"`; `concurrent?/0` is `true`, because the tool touches no file and no other resource. Two calls of the tool in one turn each land a result, and the newest result is the list that a client shows.
- The description tells the model to send the whole list each time, to mark one item `in_progress` while it works, and to use the tool for a task of three or more steps.

### Parameters

The schema is a JSON object with the key `items`, required: an array of 1 to `Helyx.Tool.Todo.max_items/0` objects. An item has exactly two keys, both required:

| Key | Type | Bound |
| --- | ---- | ----- |
| `text` | string | 1 to `Helyx.Tool.Todo.max_item_bytes/0` bytes, no new line |
| `status` | string | `pending`, `in_progress`, or `done` |

`Helyx.Tool.Args.check/2` checks the types, the sizes, the list count, the status values, and the required keys at the entry of `run/2`. Three rules that the schema cannot state are checks of the tool, and each error names its rule:

- an item holds only `text` and `status`, so an unknown key is refused;
- a `text` holds no `"\n"` and no `"\r"`, because the block shows one line for each item;
- at most one item is `in_progress`, because the user reads one item as the current one.

### The result

The result text is one line for each item in the order of the list: `[x] text` for done, `[>] text` for in progress, `[ ] text` for pending. The last line is `<done>/<total> done`. The model reads the text.

The result also carries one UI block of kind `todo`:

```json
{"kind": "todo", "text": "<done>/<total> done", "items": [{"text": "...", "status": "pending" | "in_progress" | "done"}]}
```

The `text` of the block is the count line only. A client shows the result text and the text of a block that it cannot render, so a block with the full checklist would show the checklist twice. The result carries one block, so the bound of the count of blocks of a result (`Helyx.UIBlock.max_result_blocks/0`) holds with room to spare. The session checks it with `Helyx.UIBlock.check/1` as any block of a result (`Helyx.Session.Hands.Run`), and the model never gets it.

### Clients

No client changes. The TUI and the GPUI app draw the block as its `text`, as they do for a kind that they do not render natively, so both show the checklist under the call at once. A native checklist renderer is out of scope.

## Replaced mechanism

None. This feature adds a tool and a kind.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| items of one plan | 1 to `Helyx.Tool.Todo.max_items/0`: a longer plan does not help the user at a glance | the error result says the list holds 1 to `Helyx.Tool.Todo.max_items/0` items | `parameters/0`, `Helyx.Tool.Args` |
| text of one item | 1 to `Helyx.Tool.Todo.max_item_bytes/0` bytes: a plan item is one short line | the error result says the text is 1 to `Helyx.Tool.Todo.max_item_bytes/0` bytes | `parameters/0`, `Helyx.Tool.Args` |
| new lines in a text | none: the block shows one line for each item | the error result `items[n].text must hold no new line` | `run/2` |
| items in progress | 1 | the error result `items: at most one item is in_progress` | `run/2` |
| keys of one item | `text` and `status` | the error result `items[n]: an item holds only text and status` | `run/2` |
| one `todo` block | `Helyx.UIBlock.max_bytes/0` bytes of JSON. A list at both item bounds stays under it, because the block holds each item text once | the session cuts the block to `{kind, text, cut: true}`, as for any block (ADR 0011 §2), and the user sees the fallback text of the block; the model still reads the whole list in the result text | `Helyx.UIBlock.check/1` |

Accepted (constructed): a text of many quotes, backslashes, or control characters encodes to more bytes than its raw size and is treated as above. A plan is a sentence; a text that JSON escapes at every byte is not one. No real model or client sends it, so the tool adds no check of the encode.

## Ownership

None: the tool holds no file, process, port, or temp file, and no state of its own.

## Out of scope

- A native checklist renderer in the TUI or in the GPUI app. Both draw the `text` of the block (`docs/features/ui-blocks.md`, "Rendering in the TUI").
- A list kept in the session state, and a list shared across sessions: the newest `todo` result is the list.
- Reminders to the model, such as a plan injected into a later turn.
