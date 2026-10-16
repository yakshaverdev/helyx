# Transcript shape and session file format

Helyx needs one transcript shape that both model providers and harness providers can write into, and one file format that survives restarts. We use a provider-neutral message shape with three message kinds (user, assistant, tool result) and three content blocks (text, thinking, tool call), and we store sessions as append-only JSONL where every entry has an id and a parent id. Helyx chose this shape because its blocks can hold the content of both the Anthropic and the OpenAI message formats: text, thinking, and tool calls. The parent id costs one field now and allows branching later without a format change.

The image block and the thinking signature were removed on 2026-10-16 (#634). No bundled path wrote them, and none of 46 real session files held one. The reader rejects a file that holds one, so no content is dropped in silence. A feature that needs images or signatures adds them back with a writer.

## Considered options

- Use the OpenAI chat format directly. Rejected: thinking blocks and image tool results do not map without loss.
- Flat JSONL without parent ids. Rejected: adding branching later would require a migration.

## Update 2026-09-30: branches exist (#266), replaced by the update of 2026-10-16

Two Helyx servers can append to one session file. Each keeps its own leaf, so each writes its own branch. The reader follows `parent_id` from a leaf to the header, so file order no longer decides the conversation. A resume takes the branch of the newest leaf. A repair never truncates: a line that does not decode is skipped, and a last line without its newline gets one before the next append. A lock and SQLite were considered and declined: SQLite is a native dependency with a migration, and its file is not plain text. A UI to list or switch branches is later work.

## Update 2026-10-16: one chain (#629)

This update replaces the update of 2026-09-30. Since the writer lock (#579), one process at a time writes a session file. A session that loses its lock stops saving and goes on in memory, the same as after a write failure. So a writer never appends to a file that it does not hold, and the reader reads the file as one chain: the header, then each entry with the id of the entry before it as its `parent_id`. A line that does not decode is skipped, and a last line without its newline gets one before the next append, as before. An entry that does not continue the chain is `{:invalid_file, text}` with its line number, and the resume changes nothing. The index by id, the walk from the newest leaf, the rule for a repeated id, and the fork rule of #282 are removed.

Capabilities removed: a file with two branches is rejected, not partly read. A file with a break in its chain is rejected, also when a valid start of it could be resumed; the user can inspect or repair it. A residual case stays: the lock can end, and an append can come before the session handles that end. A file that breaks in that window is rejected and not changed. The `parent_id` field stays, so a later branch feature needs no format change.
