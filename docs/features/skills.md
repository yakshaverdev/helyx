# Skills

Status: the current contract since #471.

## Goal

A skill is a folder with a `SKILL.md` file in the Agent Skills format. The model sees a short catalog of the skills (name and description) in its system prompt, and it loads the text of a skill only when a task needs it. With skills, the coding agent runs the workflows of a repository, such as `/implement` and `/ship`, on every provider. The harness providers run with their own skills off (`docs/features/provider-parity.md`), so Helyx is the only source of skills on every provider. The facts about the format and about other programs are in `docs/research/agent-skills.md`; the decisions below stand on Helyx reasons.

User stories:

- I clone a repository that has `.agents/skills/ship/SKILL.md` and start Helyx with any model. I type `/ship`, and the agent follows the ship skill.
- The model sees in its catalog that a skill fits the task, loads it with the skill tool, and the TUI shows a `skill: ship` cell, not a plain file read.
- My home folder and the repository both have a skill named `ship`. The repository's one runs, and I see one notice line that my own one is hidden.
- A skill with a broken frontmatter does not load, I see why in one notice line, and the other skills load.

### Decisions

Decisions 1 to 3 are the owner's (2026-10-17). Decisions 4 to 8 are the orchestrator's, with the owner away.

1. **Folders.** Only `.agents/skills`. In the project: every `.agents/skills` from the working directory up to the git root, the nearest first. The git root is the first folder that holds a `.git` entry of any type, so a worktree, whose `.git` is a file, is a root. With no git root, the walk goes up to `/`. Then the user folder `~/.agents/skills`. Reason: one folder name that installers already write (`npx skills` installs into it), and no vendor folder, so a skill means the same thing on every provider. A project folder that is the user folder (the same device and inode, as when the working directory is under the home folder with no git root) loads once, as the user folder; a folder reached twice loads once, at its first place.
2. **Loading.** The bundled tool `Helyx.Tool.Skill`, named `skill`. It takes a skill name and returns the text of its `SKILL.md` with the absolute folder path, so that relative paths in it resolve. A second load of a skill that the session already loaded gives a short note, not the text again: the text is in the context once. Reason: a dedicated tool is a cell that the TUI can name, and the note keeps a repeated load from filling the context.
3. **Name clash.** The project skill wins over the user skill, and the nearer project folder wins over a farther one. Each hidden skill gives one notice line. Reason: the repository decides its own workflows.
4. **Format.** The Agent Skills specification is the contract. The file starts with a YAML frontmatter between two `---` lines. `name` has 1 to 64 characters of `a-z0-9-`, no hyphen at the start or the end, no `--`, and equals the folder name. `description` is a string of 1 to 1,024 characters (Unicode code points). The optional keys are `license`, `compatibility`, `metadata`, and `allowed-tools`; Helyx reads none of them. Another key is ignored, with no notice. A skill that breaks a rule is dropped with a notice, and the other skills load: the smallest unit is rejected. The frontmatter reader is `Helyx.Skills.Frontmatter`, not a full YAML parser: it reads only the keys that Helyx uses, `name` and `description`, so no other key can make a scan slow or large. See "The frontmatter reader" below.
5. **Catalog.** `Helyx.ModelContext.Default` adds a `## Skills` section to the system prompt of every provider, from the helper module `Helyx.Skills` in `plugins/bundled`, with no Core change to the catalog. It holds one line that tells the model to load a skill with the skill tool when a task matches, then one line per skill: `- name: description`, with each line break of the description as a space. The section is there only when the context's tools hold a tool named `skill` and the scan found a skill, so a product without the tool gets no instruction it cannot follow.
6. **User command.** `/name args` in the TUI and in print mode (`-p "/implement 730"`). A known skill name expands to the text that the skill tool gives on a first load, then, when the arguments are not empty, a blank line and the arguments as plain text. There are no placeholders. The expanded text is the user message, so the load counts as a load for the note of decision 2. A TUI command (`/model`, `/compact`, `/new`, `/resume`, `/help`) wins over a skill of the same name. A word that starts with a command name, such as `/models`, gives the usage of that command as before, unless the whole word is a skill name. A `/word` that is neither is sent as plain text. Print mode has no TUI commands, so there every known skill name expands.
7. **Nested skills.** A skill text can tell the model to load another skill. There is no call stack and no depth count.
8. **No installer.** `npx skills` installs into `.agents/skills`, with its own `skills-lock.json`. Helyx only reads the folders.
9. **Child sessions.** A child session of the agent tool has the skill tool and the skill list when its parent has the skill tool. By `docs/features/agent-tool.md`, a child gets the tools of its parent but `agent`, the working folder of its parent, and the system prompt that the same ModelContext plugin builds, and decision 5 puts the list there when the tools hold `skill`. The child has a fresh context, so its transcript is its own: a skill that the parent loaded gives the full text on the first load in the child, and the note of decision 2 counts only the loads of the child. A child has no user command, because no client drives it. Reason: the agent tool gives a child what the parent has, and a skill that the task of the child needs must load there.

## Interface changes

### `Helyx.Tool.transcript/0` (Core)

The skill tool must know what the session loaded, and only the session holds it. A harness provider keeps its own history, so a rewrite of the context cannot give the note; the tool itself must. A store in the plugin cannot see the user command of decision 6. So the note is derived from the transcript, with no state of its own: it survives a resume, and after a summary compaction drops the earlier load, the next load gives the text again.

`Helyx.Tool.transcript/0`, called from a Task of the hands, returns the session's transcript when the session answers, the messages that `Helyx.Summary.kept/2` keeps after its stored summary: the messages that its next context build starts from. The hands put the session pid in the process dictionary of each Task, next to the hands pid. The call goes to the session process with no deadline. The session never waits for a tool Task, so the call cannot deadlock; it exits when the session ends, and the Task fails as any tool does. Outside a Task of the hands it exits, as `Helyx.Tool.hold/1` does. A tool result reaches the transcript through the provider's own events, so the result of an earlier call of the same assistant message can be missing from it. `Helyx.Summary.kept/2`, public Core API on the summary struct, is the one rule of which messages a summary keeps; `Helyx.Compaction.Summary` and the `:transcript` call both use it.

### `Helyx.Skills` (helper, `plugins/bundled`)

- `scan(cwd, home)`: the skills of the folders of decision 1, the catalog text, and the notices. The ModelContext calls it at each context build, the tool at each call, the TUI at mount and at each submitted `/word`, and print mode twice (for the notices and for the expansion).
- `text(skill)`: the load text:

  ```text
  <skill name="ship">
  Folder: /abs/repo/.agents/skills/ship (relative paths in this skill resolve against it)

  <the SKILL.md text, frontmatter included, cut by Helyx.Text.truncate/2>
  </skill>
  ```

  The frontmatter stays, so a line number in the cut notice is a line of `SKILL.md`, and the read tool continues at that offset.
- `loaded?(messages, name)`: true when a user message starts with the first line `<skill name="NAME">`, or a tool result of the tool `skill` that is not an error starts with it.
- `expand(text, cwd, home)`: the text of decision 6, or nil when the text is not `/name` of a known skill.

### The frontmatter reader

`Helyx.Skills.Frontmatter.read/1` takes the text between the first two `---` lines (with `\n` or `\r\n` line ends) and reads it as a block map of top-level keys. A UTF-8 byte order mark before the first `---` is skipped. A line at column 0 is a key (`key:` and its value; a `:` inside a plain key has no blank after it, and the key does not start with a blank or a YAML indicator character, except `-`, `?`, or `:` before a character that is no blank; a single- or double-quoted key is read as its text), a comment, or blank; an indented or blank line belongs to the key above it. A comment at column 0 ends a value of `name` or `description` that has begun, so an indented line after it is an error. The blanks are a space and a tab, as in YAML: another Unicode space is text, so `name: x` followed by a no-break space is no valid name. Every key other than `name` and `description` is skipped with its lines, unread, whatever they hold. `name` or `description` twice is an error.

A value of `name` or `description`, on the line of its key or on the next indented line, is one of:

- a plain scalar: its lines, with ` #` comments cut, folded (a line break is a space, an empty line a line break). A plain scalar that YAML reads as a null, a boolean, or a number (`~`, `null`, `true`, `12`, `0x1F`, `.inf`) is no string;
- a single-quoted scalar, with `''` for a quote, folded the same way;
- a double-quoted scalar, with the YAML escapes (`\n`, `\t`, `\"`, `\\`, `\xXX`, `\uXXXX`, `\UXXXXXXXX`, and the others of YAML 1.2) and the escaped line break; an unknown escape or a surrogate is an error;
- a literal (`|`) or folded (`>`) block scalar with its chomping indicator (`-`, `+`) and an indentation indicator `1` to `9`, counted from the key's column.

Out, each an error that drops the skill with its notice:

- a flow mapping or a flow sequence as the document (`{name: x}`) or as the value of `name` or `description` (`[a]`): "the frontmatter is not a map of keys" or "the frontmatter has no description string";
- a multi-document file: the frontmatter ends at its first closing `---`, and a `...` line is not a key;
- a complex key (`? name`) or a sequence (`- a`) as the document; `- a` or `? a` as the value on the line of `name` or `description`: "the description is not valid YAML";
- an anchor (`&a`), an alias (`*a`), or a tag (`!!str`, `!x`) in `name` or `description`: "the name uses an anchor, an alias, or a tag";
- a block scalar indented with a tab, or with a line that is less indented than its first line.

Some readings are wider than YAML, on purpose, because each gives the text that the author meant and none can make a value larger than its lines: a plain scalar can hold `: ` or end with `:`, as in `description: Use when: X`; a plain scalar can start with `@`, `` ` ``, `%`, `]`, `}`, or `,`; an indented comment line inside a plain scalar reads as an empty line; a comment after a closing quote needs no blank before its `#` (`'x'#c` reads as `x`); a line of a plain scalar can be indented with a tab; a lone `\r` is text, not a line end; and a leading empty line of a block scalar can hold more spaces than its first text line. The research note `docs/research/agent-skills.md` holds no frontmatter text to test against, so the test set is the forms above and the files of this repository's `.claude/skills` all read (`plugins/bundled/test/helyx/skills/frontmatter_test.exs`).

### `Helyx.Tool.Skill`

`skill` with the one required string argument `name`. A name that the scan does not know is an error result that names the catalog. A known skill that `loaded?/2` finds in `Helyx.Tool.transcript/0` gives the note: the skill is loaded, follow the earlier text, and read `<folder>/SKILL.md` if that text is no longer in the context. Else the result is `text/1`.

### TUI and print mode

- `Helyx.TUI.Command.parse/2` takes an expand function; `Helyx.TUI.Composer.submit/2` passes it. The TUI passes `Helyx.Skills.expand/3` with its working directory.
- The TUI shows each notice of the scan as a notice cell at mount.
- The call line of a `skill` call with a string `name` is `⚙ skill: <name>`, cut as every call line (`Helyx.TUI.CallLine.line/2`).
- Print mode expands the prompt (after the piped input joins it) and writes each notice of the scan on stderr before the session id.
- `CodingAgent` registers `Helyx.Tool.Skill`.

## Replaced mechanism

The TUI command rule: a command name with no separator after it, as in `/models`, gave the usage of the command. Now it gives the usage only when the whole word is not a skill name; else the skill expands. The tests of the old rule stay. No other mechanism changes.

## Bounds

| What | Bound | Over the bound |
| --- | --- | --- |
| folders walked | the components of the working directory path, up to the git root | none; a path is short |
| entries of one skills folder | unbounded: `File.ls/1` lists every name, and each name gets one `File.stat/1` of `<name>/SKILL.md` | accepted: the folders are the user's own; the stat is cheap and nothing is read |
| skill folders in one scan | 200 entries that have a `SKILL.md` entry (`@max_skills`), in precedence order: nearest project folder first, names sorted in a folder, the user folder last. A hidden one counts and is not read | the rest are not read, one notice with their count; so the user skills are cut first, then the farthest project folders |
| one `SKILL.md` | 65,536 bytes (`@max_file_bytes`), a regular file, valid UTF-8, checked on the stat and again on the read text | dropped with a notice |
| frontmatter read | in the scanning process, one pass over the lines of the frontmatter, linear in its bytes: at most 65,536 bytes from the file bound; the lines of a skipped key are not kept, and no value expands (an anchor, an alias, or a tag in `name` or `description` drops the skill). Measured on 64 KB of each worst shape (2026-10-18, `docs/devlogs/2026-10-18-skills.md`): about 13.6 ms at most, 14.7 ms in a review rerun on the loaded machine | none |
| catalog text | 16,384 bytes (`@max_catalog_bytes`), the whole section, heading and rule line included | filled in precedence order; from the first skill that does not fit, that skill and every later one are left out of the catalog, the tool, and the command, with one notice |
| catalog skills | at most 200, from the read bound | as above |
| notices of one scan | one per skill folder of the scan, plus one for the folder bound and one for the catalog cut: at most 202 lines | none |
| one notice line | at most 1,024 bytes (`@max_notice_bytes`, `Helyx.Text.cap/3`); the TUI and print mode cut it again as every notice | cut on a character boundary |
| load text | `Helyx.Text.truncate/2` of the file (2,000 lines or 51,200 bytes, with its notice), the header, and the folder line capped at 4,096 bytes: at most about 56 KiB, under `Helyx.Message.max_result_bytes/0` (65,536), so the hands never cut it and its first line stays first | cut by `truncate/2` with a notice that names the next offset |
| skill name from the model | a string, else an error; a name that the scan does not hold is an error that echoes at most 64 bytes of it | error result |
| user command | the composer text or the print prompt; the expanded text is under 64 KiB plus the arguments, and `Helyx.Session` checks the 4 MiB bound of a message | the session refuses it |
| `Helyx.Tool.transcript/0` | the whole transcript, one copy per call; the call has no deadline, because the session never waits for a tool Task | none; the session holds it already. The call exits when the session ends |

When the scan runs and what it costs: at each context build (the start of each turn, and before each model call of `Helyx.Provider.Loop`), at each skill tool call, at TUI mount, at each submitted `/word` in the TUI, and twice in print mode. So an edit to a skill takes effect at the next scan. On a folder of 200 skills of 2,046 bytes each, with a folded description, one scan with the frontmatter reader took a median of 56.5 ms (max 282.0 ms) in one run of 20 scans and 22.6 ms (max 46.2 ms) in a second, on the development machine at a load average of 5 to 7 (2026-10-18, `docs/devlogs/2026-10-18-skills.md`). The worst case reads 200 files of 64 KiB, 12.5 MiB.

Accepted:

- A file can change between the stat and the read; the read text is checked again.
- Folder identity by inode assumes a POSIX filesystem.
- The scan, the tool, and the TUI read the skills of the machine that runs them. With a remote client, the TUI notices and the `/name` command read the client's disk, and the catalog and the tool read the server's disk.
- `Helyx.ModelContext.Default` takes the home folder from its `:home` option; the tool and the clients use `System.user_home!/0`. No product sets `:home`; a product that does gets a catalog that the tool does not match.
- A parent folder that other users can write (such as `/tmp`) can add project skills when the walk reaches it with no git root.
- After a native compaction of a harness, the harness can have dropped a loaded skill while the Helyx transcript still holds it; the note then tells the model to read `SKILL.md`.
- A user command always expands to the full text, also when the session loaded the skill already: the client holds no transcript, and the user asked for the skill again.
- The TUI user cell and the recall of an earlier prompt show the expanded text, not `/name args`.

## Ownership

None: each `SKILL.md` is opened and closed inside `Helyx.Text.read_file/1`, and `File.ls/1` and `File.stat/1` hold no handle after they return. The frontmatter reader starts no process.

## Out of scope

- Keeping loaded skills through a summary compaction (a follow-up ticket). With the derived note, a load after a compaction gives the text again.
- Agent definitions (a separate ticket).
- Trust prompts for project skills: Helyx has no approval gate (#503).
- The `.well-known/agent-skills` index.
- Moving this repository's `.claude/skills` to `.agents/skills`: the old worker build still reads them there.
