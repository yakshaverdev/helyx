# Agent self-knowledge

Status: the current contract since #470.

## Goal

The agent can answer questions about Helyx and about its own session. It knows where the Helyx docs are and which file covers a topic, and it reads a file with its normal tools only when the user asks about Helyx. It knows its working directory, its model, its session id, and the folder of its session file.

User story: in a Helyx session I ask "which model are you, and where is this session saved?". The agent answers `anthropic/claude-sonnet-5-5` and `~/.helyx/sessions/<project>/`. I ask "how do I add a tool to Helyx?". The agent reads the tools file of the docs map and answers from it.

## Interface changes

`Helyx.ModelContext.Default.build/2` builds the system prompt in this order:

1. the base prompt;
2. the docs section, if the docs are present;
3. the session section;
4. the context files (`docs/features/context-files.md`).

**Docs section.** A fixed text (`@docs_rule`): read these files only when the user asks about Helyx itself; the Helyx root and the absolute paths of `README.md`, `docs/features/`, and `docs/adr/`; and a map from topic to file, relative to the root (`@docs_map`): plugins, providers, tools, the TUI, sessions, compaction, and context files. The root is the Helyx source root, resolved at compile time from the plugin source path (`__DIR__`): the docs then belong to the source that the node was built from, and no environment variable or config can point at other docs. The option `:docs_root` overrides it, for tests.

**Docs missing.** Each build checks that `README.md` at the root is a regular file. If it is not (a release build, a moved checkout), the docs section is left out, and the session section stays.

**Session section.** Exactly four values: the working directory, the model ref (`provider/model`), the session id, and the session directory, the folder of the session file. A session that is not saved (no `:sessions_dir`, or a write failed) shows `not saved` as its session directory. Nothing else goes in the section: no environment, no home directory, no token, no config value.

**Core.** The session adds two values that it holds to the `opts` of `build/2`: `:model`, the `Helyx.ModelRef` of the turn, and `:session_dir`, the absolute path of the folder of the session file (`Path.absname/1` against the node's working directory, which is how the file writes resolve it, so a `~` stays literal) or nil. The `@moduledoc` of `Helyx.ModelContext` lists them. They go to `build/2` and `compact/2`, which get one `opts`, not to the provider process. Core gets no new construct.

**Prompt stability.** The sections change only when a value changes: a model switch, a resume in another folder, a session that stops saving, or a `README.md` at the root that appears or goes away. So the system prompt is the same for the turns of one session and one model, which keeps the provider prompt cache, and a harness provider does not restart its program: `Helyx.Provider.ClaudeCode.Program.ensure/2` and the Codex thread start a new one only when the system prompt changes. No date or time goes in the sections for this reason.

## Replaced mechanism

None. The docs and session sections are new. The context files keep their order, rules, and cap.

## Bounds

| What | Bound | Over the bound |
| --- | --- | --- |
| one value (root, docs path, cwd, model ref, session id, session directory) | one line of at most 4,096 bytes (`@max_value_bytes`), enforced in `build/2` where the line is rendered | the value is cut to 4,096 bytes with `Helyx.Text.cap/3`, which also drops a split character and invalid UTF-8; then each Unicode line break (`\R`, CRLF as one) becomes a space, which never adds bytes |
| the docs and session sections | fixed text (module attributes) plus eight values at the per-value bound | none; they are not part of the context-file cap `@max_total_bytes` |
| context files | `docs/features/context-files.md` | unchanged |

Tests build a session value at the bound, one under, one over, and multibyte, a working directory with each kind of line break, and a session directory with invalid UTF-8. The docs values go through the same render; a test cannot make them long, because a path that holds a regular `README.md` is within the OS path limit.

Accepted:

- A path with a line break shows a space in its place, so the agent sees a wrong path. Such paths are rare, and the alternative is an unbounded or multi-line value.
- A value cut at 4,096 bytes is a wrong path. A path that long is rare; the cut keeps the prompt bounded.
- The map is fixed text. A docs file that is renamed leaves a stale entry; a test checks that every file of the map exists.
- A session that stops saving changes its session section once, so a harness provider starts a new program at the next turn.
- The headings of the context files still show their raw path, so a folder name with a line break adds a line there (`docs/features/context-files.md`). The one-line rule covers only the docs and session sections.
- The root is the source path at compile time. A copy of `helyx_plugins` compiled under another project would point at that project, and its own `README.md` would pass the check. Every product uses a path dependency today.

## Ownership

None: the two sections read no file. They stat `README.md` only.

## Out of scope

Skills listed in the prompt (#471). A reload command, and self-modification of plugins at run time.
