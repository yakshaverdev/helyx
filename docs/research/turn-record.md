# Turn record: how harnesses store what the model was sent

Ticket #553. Gathered on 2026-11-06 from the harnesses installed on the dev machine, with no network: the shipped code (source where a package ships it, otherwise the strings of the binary or the bundled JavaScript), the `--help` text, and the key names, types, counts, and sizes of local session files. No message content was read. These are observations; the decisions are in `docs/features/turn-record.md`.

| Harness | Version | Read from |
| --- | --- | --- |
| Claude Code | 2.1.318 (session files written by 2.1.287 to 2.1.289) | strings of the compiled binary, `--help`, one session JSONL of 41.7 MB |
| Codex CLI | npm package 0.166.0, native `aarch64-apple-darwin` binary; newest rollout written by 0.167.0 | strings of the binary (no Rust source ships), `--help`, one rollout JSONL of 5.8 MB, `logs_2.sqlite` schema |
| Gemini CLI | 0.67.0 | unminified bundle `bundle/chunk-LAR4JEC7.js`, session JSONL under `~/.gemini/tmp/*/chats` |
| opencode | 2.2.5 | strings of the binary, schema of `opencode.db` (all four local sessions predate the tables below) |
| pi | 1.4.0 | JavaScript source of `@earendil-works/pi-coding-agent` and `pi-ai` |
| Amp | 0.0.1793952045-g82bb22 | strings of the binary, four local thread JSON files |
| cursor-agent | 2026.01.23-916f423 | webpack bundle; no local chat store existed |

Where a finding comes from strings and not from a run, it says "inferred".

## 1. What is stored: full text on each turn, or once with a reference

- **Claude Code.** An entry with `type: "attachment"` and `attachment.type: "prompt_snapshot"` holds `systemPrompt` (an array of strings, about 11 to 12 thousand characters in the sample), `tools`, and rendering fields. It is written once per segment of the conversation: at the first request and again after each `compact_boundary`, not on each turn and not on each change (30 snapshots in a file with 14 compactions, two per segment). The help of `--system-prompt-snapshot <on|off>` says the prompt "is rendered on the conversation's first request… and recorded", and that with `off` it is "rendered fresh every request". The context files go in a separate `attachment.type: "instructions"` entry, `files[]` of `{type, path, content}` (`Project` about 10 to 12 KB), shown to the model as a user message, also written again after each compaction.
- **Codex.** The base prompt is stored once in `session_meta.payload.base_instructions` (`text`, 21,524 characters, and `provenance`). AGENTS.md and the environment go into the history once, as `response_item` user and developer messages. A `world_state` entry holds a full snapshot (about 70 KB, with `agents_md.text`) at the start and after a compaction, then small patches (180 to 461 bytes) when something changes. `turn_context` is written once per turn (16 in 15 turns, each about 2,000 bytes) and holds settings only, no prompt text.
- **Gemini CLI.** Not stored. Session entries are `user`, `gemini`, `info`, and `$set` patches; no key holds the system instruction.
- **opencode.** Stored once, then only on change, by hash: `instruction_blob(hash, value)` keeps each text once, `instruction_state` maps keys to hashes per session, and `InstructionState.commit` returns early when nothing changed; a change publishes `session.instructions.updated` with a delta.
- **pi.** Stored once, then only the changed sections. The prompt is a set of named sections (preamble, tools, rules, docs, project context, skills, cwd). Each turn the prompt is rebuilt and diffed against the one derived from the transcript (`diffSystemPromptSections`, `core/system-prompt.js:140`); a difference adds a `{role: "system", sections}` entry (`core/agent-session.js:1525-1528`), an unchanged turn adds nothing, and a reader merges the patches in order (`getCurrentSystemMessage`, `pi-ai/dist/utils/transcript.js:58`). A compaction entry also keeps the whole current prompt (`session-manager.js:882,895`).
- **Amp.** Not stored in the local thread files (roles user and assistant only); newer threads live on a server, unknown.
- **cursor-agent.** Stored once per conversation: `root_prompt_messages_json`, blob references to the root prompt messages in a per-chat SQLite store. Whether it changes inside a conversation is unknown.

## 2. Size cap of the stored text, and what happens over it

- **Claude Code.** No cap on one entry found. File-level constants only: `MAX_TRANSCRIPT_READ_BYTES` 52,428,800 (50 MB), a scan chunk of 1 MiB, and 5 MiB as an `over_prune_threshold` next to the `compact_boundary` marker (inferred: past it a reader starts at the last boundary). What happens over 50 MB was not determined.
- **Codex.** `project_doc_max_bytes` defaults to 32,768; over it the string "project doc exceeds remaining budget; truncating" (inferred: cut, with a budget shared by several files). No cap on `base_instructions` found.
- **Gemini CLI.** No byte cap: `readGeminiMdFiles` reads each file whole; the limits are on imports (`maxDepth: 5`) and folders (`maxDirs: 50`).
- **opencode.** No byte cap found; an empty rendered instruction throws.
- **pi.** No cap: `loadContextFileFromDir` (`core/resource-loader.js:115-130`) reads the whole file.
- **Amp, cursor-agent.** No client cap found.

## 3. Resume: the stored prompt, or a fresh build; and the compaction summary

- **Claude Code.** Replays the stored prompt. Help text: "every later request and resume sends the record as-is, even when a later launch passes different text, until the conversation is compacted". In code, the last `prompt_snapshot` is taken (`findLast`). A compaction writes `system`/`compact_boundary` with `compactMetadata` (pre and post tokens and more), followed by a `user` entry with `isCompactSummary: true` (12 to 25 KB in the sample), which is not counted as a human turn.
- **Codex.** Replays stored history and world state (`apply_rollout_reconstruction`; "ignored world-state patch without a full snapshot"). Strings suggest that changed base instructions are announced in the conversation ("The following instructions replace the previous base instructions:") rather than swapped (inferred). The `compacted` entry holds a `replacement_history` (20 items, 159,706 bytes in the sample), followed by a full `world_state` and a `turn_context`.
- **Gemini CLI.** Rebuilds fresh (`getCoreSystemPrompt3` in `startChat`). A compression makes a `<state_snapshot>` summary that is replayed as an ordinary user message; dropped turns are removed with a `removeIds` patch.
- **opencode.** Replays the stored instructions (`InstructionState.initial`; it fails with "Instruction state not found during assembly"), diffs fresh sources against them, and sends a change as an extra system message. The end of a compaction starts a new epoch whose initial instructions are the current ones.
- **pi.** Rebuilds fresh from disk, then stores the difference against the stored prompt, so the stored history stays exact. After a compaction the load gives the stored prompt of the compaction entry, then the summary wrapped in a prefix and `<summary>`.
- **cursor-agent.** Replays the stored root prompt (`hydratePromptMessages`).
- **Amp.** Unknown.

## 4. How the user sees what the model got

- **Claude Code.** No command; the `prompt_snapshot` entry is readable with `jq`, and `--debug`/`--debug-file` exist (whether they hold request bodies was not checked).
- **Codex.** `codex debug prompt-input [PROMPT]`: "Render the model-visible prompt input list as JSON" (not run). A logs SQLite table exists; whether it holds full requests was not determined.
- **Gemini CLI.** `/memory show` prints the loaded context files; an environment switch writes the system prompt to a file; telemetry with prompt logging emits `gen_ai.system_instructions`.
- **opencode.** No user view found.
- **pi.** The session file, and `/export` to HTML, which includes the system prompt (`core/export-html/index.js:188`).
- **Amp.** `amp threads context <thread>` prints the estimated input context as JSON (server side, not run).
- **cursor-agent.** No user view; the display filters out system messages.

## 5. Session file version and older files

- **Claude Code.** No schema version; each entry carries the writing program's `version`. Parsing looks lenient (`safeParse`, `.optional().catch(void 0)`), so a snapshot that does not parse is ignored (inferred).
- **Codex.** `session_meta.payload.cli_version`, the writing program's version. A line that fails to parse is logged and skipped ("failed to parse rollout line:", "skipping legacy ghost_snapshot rollout line"; inferred from strings).
- **Gemini CLI.** No version field; a line that fails to parse is skipped silently; a legacy whole-JSON file is read by a fallback and rewritten as JSONL on resume.
- **opencode.** The session row holds the writing program's version; the schema moves by SQL migrations.
- **pi.** A header `{type: "session", version}` with `CURRENT_SESSION_VERSION = 3`; older files are migrated in memory and rewritten (`session-manager.js:722`). Adding the system entries did not raise the version: an old file has none, and the next turn's diff against an empty prompt adds the whole prompt.
- **Amp.** No schema version found. **cursor-agent.** `PRAGMA user_version = 1` on each open; no migration found.

## Not determined

The exact source logic of Claude Code, Codex, opencode, Amp, and cursor-agent (no source ships); what Claude Code does with a file over 50 MB; whether the Codex AGENTS.md budget is per file or shared; whether any debug log holds full request bodies; anything of Amp's server-side store.
