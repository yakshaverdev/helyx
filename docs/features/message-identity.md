# Message identity

## Goal

Every message of a session has a stable id, and every user message has an origin. Issue #649. ADR 0006, revision of 2026-10-17.

User stories:

1. A client that stores the conversation (a memory, an audit log) restarts. It gets the snapshot and the events again, and it stores each message once, by its id.
2. A client that stores what the user said skips the end of a background run and a turn that product code started, because their origin is not `:user`.
3. Product code starts a turn on a timer. After a lost reply of `prompt`, it subscribes and finds its own origin id in the snapshot, so it knows that the prompt was admitted.
4. A session file written before this change still resumes. Its user messages read as origin `:unknown`, never as `:user`.

Reasons:

- The position of a message is not an identity: a resume adds interrupted results and drops stray results (`Helyx.Session.Transcript`), so the id is on the message.
- The structure, not the text, marks injected input. The end of a background run has a fixed text form (`background-bash.md`), but a user can type the same text.
- The origin goes into the file, because a mark that the storage layer drops is lost at the next resume.

## Interface changes

`Helyx.Message` gets two fields:

- `id`: a string. Core sets it on every message that joins a session: a user message when Core admits it, an assistant message when it opens (so its `message_start` carries it), and a tool result when it joins. A session with no `sessions_dir` gets ids too. `Helyx.Message.user/1` and `tool_result/2` still give nil; a provider builds such messages for its own wire.
- `origin`: nil for an assistant message and a tool result. For a user message, `%{kind: kind, id: id}`:

| kind | set by | id |
| --- | --- | --- |
| `:user` | Core, for `prompt`, `steer`, `follow_up` with no `:origin` option | nil |
| `:background` | Core, for the end of a background run, a lost end too | the run id |
| `:product` | product code, with the `:origin` option | the product's id, unique per occurrence |
| `:unknown` | the file reader only, for a user message of a file from before #649 | nil |

`Helyx.Session.prompt/3`, `steer/3`, and `follow_up/3` take `origin: %{kind: :product, id: id}`. Any other option list, or a product id that fails the bound below, is `{:error, :invalid_origin}`, and nothing is queued. `:user` and `:background` are for Core only.

The id stays with the message:

- A queued steer or follow-up is the message itself, so it keeps its id and its origin through the queues, the steer ledger, a rejected steer, and the submit path, which puts the same message into the context.
- A steer that a provider takes with `{:user_message, steer_id}` joins as the message of its ledger entry.
- `:queue_dropped` gets `messages`, the dropped user messages, beside `texts`. `:steer_unconfirmed` gets `message` beside `text`. The TUI composer goes on reading `texts`.
- `message_start`, `message_end`, `tool_execution_end`, the snapshot messages, and the partial message of the snapshot turn carry the message with its id. Provider wire ids (tool call ids, steer ids, resume ids) are separate.
- `turn_start` does not change: one turn can open with several queued user messages, so provenance belongs on each message.

Session file:

- The version stays 1: the fields are additive. The entry id of a message is the message id: `Helyx.Session.File.append_message/2` writes the id of the message and makes none. A message with no id raises (`Codec.encode/1`): the session sets the id of every message that it appends.
- A user entry has `"origin": {"kind": "user" | "background" | "product", "id": ...}`, with `"id": null` for `:user`.
- The reader decodes the entry id as the message id. A user entry with no `origin` key is `:unknown`. A present origin that is malformed (null, an unknown kind, a missing or bad id, an extra key), or an origin on another role, rejects the file as the other bad fields do.
- A message entry id that repeats an earlier message entry id, or that does not have the format of `Helyx.Session.Id.new/0` (`Id.valid?/1`), rejects the file (`Helyx.Session.File.Reader`): a client must not get two messages with one id, and an id of another format could hold `:`, the separator of the derived ids below. Core never writes either: every entry id since the first session file came from `Id.new/0`. The ids of the other entries reach no client and are not checked.

Repair results: `Helyx.Session.Transcript.repair/1` writes nothing, so each resume derives the id of an interrupted result again: `<assistant id>:<n>`, where `n` is the place of the call among the tool calls of its assistant message, from 0. A provider call id can repeat in a message, so the place, not the call id, names the call. `:` is not in the alphabet of `Helyx.Session.Id.new/0`, and the reader rejects a stored message id of another format, so a derived id never equals another message id.

## Replaced mechanism

1. The queues and the steer ledger held texts, and an end of a background run as `{:end, text}`. They now hold the user messages, and an end as `{:end, message}`. `Queue` treats the item as opaque, so its rules do not change. The run id of an end came from its text (`Background.id/1`); the hands now get it from the origin.
2. `Records.append_user/2` built a new user message from a text. It now appends the message that it gets. The submit path built new messages from the steer texts (`Message.user/1`); it now uses the same messages.
3. `Helyx.Session.File.append/2` made a new entry id for each entry. It still does for the header, a model change, a resume id, and a compaction; a message entry has the message id.
4. No reply is removed. No test property is deleted; the tests that compared whole messages now ignore or check the new fields.

## Bounds

| What | Bound | Where enforced | Over the bound |
| --- | --- | --- | --- |
| origin id from product code | non-empty, valid UTF-8, at most 256 bytes (`Helyx.Message.origin?/1`, its own limit) | `Helyx.Session.prompt/3`, `steer/3`, `follow_up/3`, before the call | `{:error, :invalid_origin}` |
| origin kind | closed set; `:product` only from product code | same | `{:error, :invalid_origin}` |
| origin in the file | the same check | `Helyx.Session.File.Codec` | the file is rejected |
| message entry ids of a file | each once, each of 12 characters of the alphabet of `Id.new/0` | `Helyx.Session.File.Reader` | the file is rejected |
| the message ids that the reader keeps for that check | one per message entry; the file limit of 64 MiB bounds them (row "Session file on resume" of `coding-agent.md`), inside the heap cap of the read process | `Helyx.Session.File.Reader` | the read process dies at its heap cap: `{:too_large, text}` |
| derived ids | one per open call of a resumed transcript | `Transcript.repair/1` | n/a |

The queues keep their bounds (32 steers, 32 follow-ups); the message adds a 12-byte id and an origin of at most 256 bytes to each entry.

## Ownership

No external resource.

## Out of scope

- Request ids with a duplicate check for operations (ADR 0006 §4). Presence of an origin id in the snapshot proves admission; absence proves nothing while a prompt waits in a queue.
- The consumer that uses the ids (the memory interface ticket).
- `Helyx.Session.Background.lost/1` still finds the ended and the started runs of a resumed transcript by their text, because a file from before #649 has only the text. A user prompt that starts with the end line of a run stops its lost end.
- The TUI prompt history and the `prompt` of the session list still take every user message, injected text included.
