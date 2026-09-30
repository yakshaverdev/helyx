# Transcript shape and session file format

Helyx needs one transcript shape that both model providers and harness providers can write into, and one file format that survives restarts. We use a provider-neutral message shape with three message kinds (user, assistant, tool result) and four content blocks (text, thinking, tool call, image), and we store sessions as append-only JSONL where every entry has an id and a parent id. The shape is taken from pi (earendil-works/pi), which already round-trips Anthropic and OpenAI without loss. The parent id costs one field now and allows branching later without a format change.

## Considered options

- Use the OpenAI chat format directly. Rejected: thinking blocks and image tool results do not map without loss.
- Flat JSONL without parent ids. Rejected: adding branching later would require a migration.

## Update 2026-09-30: branches exist (#266)

Two Helyx servers can append to one session file. Each keeps its own leaf, so each writes its own branch. The reader follows `parent_id` from a leaf to the header, so file order no longer decides the conversation. A resume takes the branch of the newest leaf. A repair never truncates: a line that does not decode is skipped, and a last line without its newline gets one before the next append. A lock and SQLite were considered and declined: SQLite is a native dependency with a migration, and its file is not plain text. A UI to list or switch branches is later work.
