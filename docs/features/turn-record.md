# Turn record

Ticket #553. Status: the five decisions below were decided by the owner on 2026-11-06 (decision comment on #553): each takes the proposal of this doc. The facts behind the options are in `docs/research/turn-record.md`.

## Goal

A user who opens an old session cannot see what the model got on a turn. The ModelContext builds the system prompt again before every provider call (`Helyx.ModelContext.Default.build/2`: the base prompt, the docs section, the session section, the skills catalog, and the context files, read from the disk at each build), and the session file does not store it. A later edit to `AGENTS.md` hides what an earlier turn read. Since #490 a summary also stands in place of older messages.

With this feature the session file holds the system prompt of each provider call, so a reader of the file can give, for any assistant message, the system prompt and the summary that the model got.

What the model got on a call is:

1. the `system` of the context that Core sent (`Helyx.Context.system`, after the ModelContext and the Compaction plugin, `Helyx.Session.Stream.prepare/4`): **new**, the entry of this feature;
2. the summary that Core passed to the Compaction plugin (`opts[:summary]`): already in the file, the last `summary` entry before the call (`summary-compaction.md`, "Session file");
3. the messages: already in the file, the chain up to the call.

The file is one chain (ADR 0001), so the prompt of a call is the last `system_prompt` entry before the call's assistant message, and its summary is the last `summary` entry before it. Both are derived from the place in the chain; no entry stores a reference.

## Decisions

### 1. What the file stores — decided by the owner, 2026-11-06

**Decision.** The full text, once when it changes. Before the session sends a context to the provider (the submit of a turn and the answer to a context request), it compares the `system` of that context with the last one it wrote; when they differ, it appends one `system_prompt` entry with the text. An unchanged prompt writes nothing. The file struct of the session keeps the SHA-256 of the last written text (32 bytes), not the text, for the comparison ("The hash" below).

**Reason.** The prompt of the bundled ModelContext changes only when a context file, a skill, the model, or the session directory changes, so most calls would write the same text again. A text once per change keeps the file, and so the read time of a resume (row "Session file on resume" of `coding-agent.md`), from growing with the number of calls. The chain gives the reference for free: a stored reference is a second fact that can disagree with the order of the chain.

**User story.** The user runs a session of 50 turns with 400 tool calls and edits `AGENTS.md` once in the middle. The file gains two prompt entries, not 400. Later the user opens the file and, for the assistant message of turn 30, finds the prompt that the model had: the second entry, with the edit.

**Other option: the full text on each call.** Each entry stands alone, and a reader needs no walk back through the chain. The cost: each provider call adds up to the entry cap to the file. With the bundled prompt (up to about 153 KB, see "Bounds") a turn of 100 tool calls adds megabytes, and at the deadline of #834 (1 ms for each 1,000 bytes) every resume of that session waits that much longer to read text that it does not use.

### 2. The size bound of the stored text, and what happens over it — decided by the owner, 2026-11-06

**Decision: the cap.** 262,144 bytes (256 KiB) of text in one entry, a Core bound in the writer of the session file. `Helyx.Context.system` has no Core bound (any ModelContext can return any string), so the bound must hold where the text enters the file. The bundled ModelContext stays under it (row "system prompt of the bundled ModelContext" below), so the cap cuts only a prompt of another plugin.

**Decision: over the cap at the write.** The entry holds the first 262,144 bytes, cut on a character boundary, and `bytes`, the size of the whole text, so a reader sees that it was cut and by how much. The comparison of decision 1 uses the hash of the whole text, so a change after the cut still writes a new entry.

**Other option at the write: no text over the cap.** The entry holds only `bytes`. The file grows less, but the reader sees nothing of that prompt.

**Over the cap at a resume.** The writer never makes such an entry; only a file edited by hand, or a file written by a build with a larger cap, has one. Under the read of #834 the line is read and decoded whole either way: a line of up to 64 MiB is read in reads of 1 MiB, a line over 64 KiB decodes in its own process with the heap cap, and a line over 64 MiB is `{:too_large, text}` before any check of this entry. So the choice changes only what follows the decode; it does not change the cost or the memory of the read, and the load deadline (1 ms for each 1,000 bytes) already counts the bytes of the line.

- **Option A, skip (decided).** The reader checks the chain fields of the entry (its `id` and its `parent_id`, as for every entry) and drops its text. The session resumes. A later view of the record shows that turn's prompt as not readable. Reason: a resume never uses the text (decision 3), so the session can go on safely, and the rule "reject the smallest unit that permits safe continuation" (`AGENTS.md`) picks the entry, not the session. Consequence: the reader's rule that damage on the disk is "never dropped in silence" (`Helyx.Session.File.Reader`) gets an exception for this entry, which the reader and `coding-agent.md` must state.
- **Option B, fail the load.** The resume fails with `{:error, {:invalid_file, text}}`, the text names the line, and the file does not change, as for a bad `summary` entry. Reason for it: one rule for every damaged entry. Consequence: the user cannot resume the session at all because of a record that the resume does not read, until the line is fixed by hand.

**User story.** The user's own ModelContext puts a 1 MB generated index in the prompt. The file stores its first 256 KiB with `bytes: 1048576`, and the user sees that the prompt of that turn was cut. With option A, a file whose prompt entry the user made too large by hand still resumes; with option B it gives an error that names the line.

### 3. How a resume uses it — decided by the owner, 2026-11-06

**Decision.** A fresh build, as today. The entry is a record only: the reader validates it and keeps nothing of it, and the first provider call after a resume writes one entry, because the file struct of a resume has no last hash. That entry is the prompt of the resumed session, so a reader needs no rule across resumes.

**Reason.** The prompt names the session directory and the model, and reads the context files and skills of now. A replay of the stored prompt would hide an `AGENTS.md` edit made since, which is the opposite of what the user expects from a context file. A reader that keeps no text also keeps the memory of a resume where #834 left it: the transcript plus one line.

**User story.** The user resumes a session from last week after editing `AGENTS.md`. The model follows the new file, and the record of the session shows the old prompt for last week's turns and the new one from the first call after the resume.

**Other option: replay the stored prompt of the last call.** A resumed session behaves as it did, whatever changed on the disk. The cost: edits to context files and skills do not apply to an old session; the reader must hold the last text (up to the cap) through the resume; a provider that keeps its own history would get a prompt that no longer matches its tools; and a skipped or cut entry (decision 2) would leave the resume with a broken prompt.

The cost of this decision: one entry per resume that makes a call, even when the prompt did not change (at most the cap; the bundled prompt is at most about 153 KB, see "Bounds"). Keeping the last hash on the disk instead would save that entry but adds a stored fact that a hand edit of the text makes wrong.

### 4. How the user sees it — decided by the owner, 2026-11-06

**Decision.** Only the session file in this ticket. The entry is one JSON line that `jq` reads (`select(.type == "system_prompt")`). A view in the TUI or a wire call comes later, in its own ticket.

**Reason.** A view needs a wire call and a protocol change (`docs/features/wire-protocol.md`), a render bound, and a decision on how to show a text of up to 256 KiB; none of it changes the entry. The first use the owner named is to read why a worker did what it did (#747), which reads files.

**User story.** The user wants to know why a worker ignored a rule. They open the session file, take the last `system_prompt` entry before the worker's reply, and read whether the rule was in it.

**Other option: a command or a view now.** For example a `/prompt` command in the TUI that shows the prompt of the selected turn. The user does not need to read JSON. The cost: a wire request and its bounds, a render path that must hold the 256 KiB bound, and a larger change with more review in one ticket.

### 5. The session file version and older files — decided by the owner, 2026-11-06

**Decision.** The version stays 1; the reader of this build accepts the new entry type. A file with no `system_prompt` entry (every file written before this feature) reads as before, and its record has no prompt for those turns.

**Reason.** The file is append-only: a resume of an existing session cannot change its header, so a new version number could not mark a resumed old file that gains the entries. The summary entry of #490 and the `last_id` field of #712 were added the same way, without a new version. A build from before this feature that resumes a new file stops cleanly: the reader rejects an entry type that its writer never produces (`{:invalid_file, "entry the writer never produces: \"system_prompt\""}`), and the file does not change.

**User story.** The user upgrades and resumes yesterday's session: it loads, and the record starts at the first call after the upgrade. If they go back to an older build and resume a session made after the upgrade, it refuses with an error that names the entry type, and the file stays intact.

**Other option: version 2.** An older build then hides new files from its session list and refuses them with `{:unknown_version, 2}`. The cost: the reader must accept versions 1 and 2; a resumed version-1 file either gets no record for its new turns (to keep its header true) or gets the entries under a header that says 1, which makes the version mean nothing for those files.

## Interface changes

They follow the decisions above.

**Session file entry:**

```json
{"type": "system_prompt", "id": "…", "parent_id": "…", "system": "…", "bytes": 1234}
```

- `system`: the prompt text, valid UTF-8 (the JSON encode checks it), at most 262,144 bytes, or `null` when the context has no system prompt (no ModelContext, or one that returns nil). A change between text and `null` is a change.
- `bytes`: the byte size of the whole text, a non-negative integer; 0 for `null`. The reader does not read it. `bytes` is larger than the size of `system` only for a cut text.
- Written by the session process, before the context goes to the provider, after the prepare Task's result is checked. Never written by a summary call: its context is not a turn's (out of scope).

**Reader (`Helyx.Session.File.Reader`).** A `system_prompt` entry passes the chain check of every entry (a string `id`, and the id of the entry before it as `parent_id`), and the reader keeps nothing of it, whatever its other fields hold: the resume does not use them (decision 3), so it does not check them. An entry over the cap is so skipped (decision 2, option A), and so is one whose `system` or `bytes` the writer never makes. It is an exception to the reader's rule that damage on the disk is never dropped in silence, stated in the reader and in `coding-agent.md`. An entry that breaks the chain fails the resume as any entry does.

**The hash.** `Helyx.Session.File` gets the field `system_hash`: the SHA-256 of the last text that this file struct wrote, `nil` for a `null` entry, or `:unset` for a struct that has written none, which is every struct of a start or a resume. `Helyx.Session.File.append_system_prompt/2` returns the file as it is when the hash is the same, and sets the hash only with a write that succeeded: a failed write raises, and the session turns persistence off (`file` nil). A session with no file, or whose persistence went off, writes and hashes nothing. The hash is in the file struct, not in the session state, because it says what the file holds.

**The system prompt must be valid UTF-8.** `Helyx.Session.Stream.prepare/4` rejects a context whose `system` is a binary that is not valid UTF-8, as it rejects one that is not a string: `{:bad_context, :model_context}` or `{:bad_context, :compaction}`, and the turn fails. `Helyx.Context.system` is typed `String.t()`, and the JSON encode of the entry raises on such bytes, which would crash the session at the write. No bundled plugin makes such a text.

**No ModelContext.** The context has a `nil` system, and the first call writes a `null` entry. Without it a resumed session whose earlier prompt was a text would show that text as the prompt of its later calls.

**Accepted hole: a context request with an open assistant message.** The contract of a context request lets a provider ask while an assistant message is open (`one-provider-path.md`, "A fresh context"). That message is written when it closes, after the new entry, so the record names the new prompt for a reply that the model wrote under the old one. Only `Helyx.Provider.Loop` sends a context request, and it sends `message_end` before it whenever the message has content (C2), and its overflow request comes before any content; so no bundled provider makes this state.

**No change** to events, the snapshot, the wire, or any plugin interface.

**Write failure.** As for every append: a failed write turns persistence off for the session with the one notice, and the turn goes on (`coding-agent.md`, the write-failure rule). The hash is updated only after a write that succeeded.

## Replaced mechanism

None.

## Bounds

| What | Bound | Over the bound | Enforced in |
| ---- | ----- | -------------- | ----------- |
| text of one `system_prompt` entry, at the write | 262,144 bytes | the first 262,144 bytes, cut on a character boundary, with `bytes` the whole size (decision 2) | the session file writer (`Helyx.Session.File`) |
| text of one `system_prompt` entry, at a resume | none of its fields is read: the reader keeps nothing of the entry | an entry over 262,144 bytes, or with fields that the writer never makes, is skipped (decision 2) | `Helyx.Session.File.Reader` |
| the system prompt of a context, at the boundary of the plugins | a string of valid UTF-8, or nil; no size bound in Core: only the file entry has the cap | `{:bad_context, plugin}`, the turn fails | `Helyx.Session.Stream.prepare/4` |
| one `system_prompt` line in the file | at most 6 bytes of JSON for each byte of text (`\u0001`), so about 1.5 MiB with the fields: under the 64 MiB line limit, and decoded in its own process with the heap cap when over 64 KiB (row "Session file on resume" of `coding-agent.md`) | cannot pass the line limit from the writer; a line over 64 MiB edited by hand is `{:too_large, text}` before this entry's check | `Helyx.Session.File.Reader` |
| system prompt of the bundled ModelContext | the sum of its caps: the context files 102,400 bytes (`2 * Helyx.Text.max_bytes()`), the skills catalog 16,384 bytes, the session section 4 lines and the docs section 4 path lines of at most 4,096 bytes each (32,768 bytes), and the fixed text of the base prompt, the headings, the docs rule, and the topic map (about 1.5 KB): about 153 KB, under the entry cap. A test (`plugins/bundled/test/helyx/model_context/default_test.exs`) measures the fixed text and adds the public caps (`Helyx.Text.max_bytes/0`, `Helyx.Skills.max_catalog_bytes/0`), so a change of those caps that passes the entry cap fails it. The value-line cap of 4,096 bytes is private to the module; the test repeats it, and a change of it needs the test changed too | not reached by the bundled plugin | `Helyx.ModelContext.Default` |
| growth of the file for each provider call | 0 bytes when the prompt did not change; one entry of at most about 1.5 MiB of line when it changed. Worst case one entry for each call, for a ModelContext whose prompt changes on every call (a clock in the prompt); the bundled one changes only with the disk, the model, or the session directory | none: the number of entries is bounded only by the number of calls, as the messages are | the session |
| growth of the file for each resume | one entry at the first provider call after the resume (decision 3) | none | the session |
| read cost of the entries at a resume | the bytes of each entry go through the read of #834; the load deadline grows 1 ms for each 1,000 bytes, so each entry adds its own time to the deadline (a full 256 KiB entry adds 262 ms of deadline; plain text reads at about 213 MB/s, about 1.2 ms). The reader keeps no text, so the memory of a resume stays the transcript, the reads that its texts point into, and one line with its decode | `{:error, :open_timeout}` past the deadline, as for any file | `Helyx.Session.File` (load deadline), `Helyx.Session.File.Reader` |
| hash of the last written text | 32 bytes, in the `Helyx.Session.File` struct of the session | none | `Helyx.Session.File` |
| a later view of the record | out of scope (decision 4); a view must hold the 262,144-byte bound in its render path, not only at the read | — | — |

## Ownership

No new resource. The entry is one more append to the session file, through the file handle that the session already holds, with its lock and release rules (`docs/features/session-lock.md`).

## Out of scope

- A view of the record in the TUI or over the wire (decision 4). No ticket yet; the owner decides.
- The tools of a call (`Helyx.Context.tools`): their specs come from the registered tools, not from the disk, and they do not change during a session.
- Messages that a plugin adds to a call and that are not in the transcript: the recall message of the Memory plugin, and the skills that `Helyx.ModelContext.Default` carries in front of the first kept message after a summary. A reader cannot rebuild them from the file.
- The context of a summary call: the summary entry records its result.
- What a provider that keeps its own history makes of the prompt: the entry records the `system` that Core sent, not what a harness program does with it.

## Overlap with #833

#833 (delete a session, remove one message) also changes the session file; it is not merged when this feature is built, and this feature is built against master. The removal of one message must keep, by the owner's decision of 2026-11-06:

- every `system_prompt` entry in the file, none dropped with the message that it comes before or after;
- the order of the chain: each `system_prompt` entry stays before every assistant message that came after it, and after every assistant message that came before it, so the last entry before a reply is still the prompt of that reply;
- the chain links: an entry whose parent is the removed message gets the parent of the removed message, as any entry after it does.

A removal that rewrites the file must also keep the `system_prompt` entries as they are, cut text and `bytes` included.
