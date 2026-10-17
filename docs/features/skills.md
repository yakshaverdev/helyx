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
4. **Format.** The Agent Skills specification is the contract. The file starts with a YAML frontmatter between two `---` lines. `name` has 1 to 64 characters of `a-z0-9-`, no hyphen at the start or the end, no `--`, and equals the folder name. `description` is a string of 1 to 1,024 characters (Unicode code points). The optional keys are `license`, `compatibility`, `metadata`, and `allowed-tools`; Helyx reads none of them. Another key is ignored, with no notice. A skill that breaks a rule is dropped with a notice, and the other skills load: the smallest unit is rejected. The frontmatter reader is `Helyx.Skills.Frontmatter`, not a full YAML parser: it reads only the keys that Helyx uses, `name` and `description`, so no other key can make a scan slow or large. It accepts a strict subset of YAML and rejects any other text, so it is never wider than YAML. See "The frontmatter reader" below.
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

`Helyx.Skills.Frontmatter.read/1` fails closed: it accepts a strict subset of YAML and rejects every other text, so it can be narrower than YAML but never wider. It takes the text between the first two `---` lines, with `\n` or `\r\n` line ends, after a UTF-8 byte order mark when there is one. A text outside the subset drops the skill with its one notice, which names the line of `SKILL.md`: "line 5: the description goes on to the next line". A frontmatter with no `name` or no `description` gives a notice with no line: "the frontmatter has no name string".

The subset:

- The frontmatter has no control character but a tab, and none of U+0085, U+2028, U+2029, and U+FEFF: each is a line break or a mark in some YAML version.
- Each line is a key line, an indented line of the key above, a blank line (only spaces), or a full-line comment (`#` at column 0). A key line is a plain key of `A-Z`, `a-z`, `0-9`, `_`, and `-` that does not start with `-`, then a colon, then a space or the line end. An indented line before the first key is out, and so is a line with a tab after its leading spaces, because YamlElixir rejects some of those that YAML 1.2 reads. `name` or `description` twice is out.
- `name` and `description` each have one of these values, after the spaces and tabs that follow the colon. Only a space and a tab are blanks, and the trim goes by byte: a combining mark after the colon is text, and a no-break space is text.
  - a plain scalar on the key line, with a ` #` comment cut. It does not start with `-`, `?`, `:`, `@`, `` ` ``, `%`, `,`, `]`, or `}`, and it has no colon before a blank or at its end. A plain scalar that the YAML 1.2 core schema reads as a null, a boolean, or a number (`~`, `null`, `true`, `12`, `0x1F`, `.inf`) is no string, and so is one that starts as a number (`+`, `0x`, `1.2.3`), because YamlElixir reads some of those as numbers;
  - a single-quoted scalar, with `''` for a quote, or a double-quoted scalar, with the escapes of YAML 1.2 (`\n`, `\t`, `\"`, `\\`, `\/`, `\xXX`, `\uXXXX`, `\UXXXXXXXX`, and the others). It closes on the key line, and only blanks or a ` #` comment follow it. An unknown escape or a surrogate is out;
  - a literal (`|`, `|-`, `|+`) or folded (`>`, `>-`) block scalar, with a comment after its header or none. Its lines are indented and hold no tab. At least one holds text, each line with text is indented at least as far as the first one, and no line of only spaces is longer than that indentation. A column-0 comment ends it.

  After a plain or quoted value, only blank and comment lines follow. An anchor (`&a`), an alias (`*a`), or a tag (`!!str`, `!x`) as the value is out, with the notice "the description uses an anchor, an alias, or a tag".
- Every other key can have any value on its key line and on its indented lines, and Helyx does not read it. One check applies: its quotes and brackets close. A quoted or flow value that does not close on its key line, or a quote or a bracket that is open at the next key line, column-0 comment, or the end, is out. The check is a scan of the lines: a quote opens where a YAML scalar can start, and a bracket counts anywhere outside a quote. So it can find an open value where YAML has none (`notes: |` followed by `it's "open` at a deeper indentation inside another key, or `x]` in a plain value), but never the reverse. The lines of a block scalar on the key line are not scanned.

Out, among others: a flow mapping or sequence as the document or as `name` or `description`, a multi-document file (the frontmatter ends at its first closing `---`), a quoted or complex key, a plain or quoted value over more than one line, an indentation indicator (`|2`), a folded block with keep chomping (`>+`, which YamlElixir does not read as YAML 1.2 does), and a block of only blank lines.

The guarantee "never wider than YAML" has one exception: the value of another key is not read beyond its quotes and brackets, so a skill whose other key holds YAML that no parser reads, such as `metadata:` with `  a: b: c` under it or an alias of an anchor that is not there, still loads. Its `name` and `description` are the ones that the key lines give.

Open holes (findings 39 to 41 of `docs/reviews/2026-10-18-skills.md`): the scan of another key can take a quote that YAML opens for text, or the reverse, and then reads a `name` key line that YAML reads as text inside the value of that key. The known forms are a quote after a verbatim tag (`other: !<tag:yaml.org,2002:str>"`), a quote after `:` with no blank in a flow (`other: [a:"b, "c]`), and a quote in a block scalar inside the lines of another key. Until the scan is changed, the guarantee "never wider than YAML" does not hold for these forms.

The proof is the differential property of `plugins/bundled/test/helyx/skills/frontmatter_test.exs`. It generates frontmatter in the subset and near it (but none of the forms of the open holes), and asserts that each one that the reader accepts gives the same `name` and `description` as `YamlElixir.read_from_string/1`. `yaml_elixir` is a test-only dependency of `plugins/bundled`. A probe of 100,000 generated frontmatters (2026-10-18, after review round 1 of the third `/ship` run), of which about 10 % were accepted, found no difference. The files of this repository's `.claude/skills` all read, and give what YamlElixir gives. The research note `docs/research/agent-skills.md` holds no frontmatter text to test against.

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
| frontmatter read | in the scanning process, one pass over the lines of the frontmatter, linear in its bytes: at most 65,536 bytes from the file bound; the lines of another key are scanned for quotes and brackets and not kept, and no value expands (an anchor, an alias, or a tag in `name` or `description` drops the skill). Measured on 64 KB of each of ten worst shapes (2026-10-18, `docs/devlogs/2026-10-18-skills.md`): at most 21.1 ms, and at most 2.2 times the time on 32 KB | none |
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
