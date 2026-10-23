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
- Every other key can have a value on its key line and on its indented lines, and Helyx does not read it. One rule applies, the rule of characters. These characters are out at the start of a word in the value of another key: `"`, `'`, `[`, `]`, `{`, `}`, `!`, `&`, `*`, `|`, `>`, `?`, `@`, `` ` ``, and `%`. The start of a word is the first character of the value, the first character after the indentation of a line, or a place after a space or a tab. The notice names the line and the character: "line 4: the value of metadata has " at the start of a word". In a word, as in `don't`, `Bash(git:*)`, or `50%`, the character is text. A comment at column 0 is no line of the key, so the rule does not apply to it.

  One construct is in: a quoted scalar that starts the value, on the key line after `key: ` or on an indented line after its `k: ` (a key of the same characters as a key line), and closes on its line, with only blanks or a ` #` comment after it. It is checked as a quoted `name` or `description` is: a quote that does not close on its line, an unknown escape, or text after the closing quote drops the skill, as in "line 7: the value of metadata has a quote that does not close on its line". So `license: "MIT"` and `version: "1.0"` under `metadata` are in.

  The reason: a YAML construct that can go on past its line or hide a key line starts at the start of a scalar. Such constructs are a quoted scalar, a flow collection, a block scalar header, a tag, an anchor, an alias, and a reserved indicator. The start of a scalar is the start of a value or a line, or a place after a blank. So no line of another key can begin such a construct, and each key line at column 0 is a key of the mapping, as in YAML. A quoted scalar that closes on its line cannot run past the line or hide a key line, so it is safe. The rule needs no knowledge of where a value ends. The other constructs stay out because the specification gives only strings and a map of strings for the other keys.

Out, among others: a flow mapping or sequence as the document or as `name` or `description`, a multi-document file (the frontmatter ends at its first closing `---`), a quoted or complex key, a plain or quoted value over more than one line, an indentation indicator (`|2`), a folded block with keep chomping (`>+`, which YamlElixir does not read as YAML 1.2 does), and a block of only blank lines.

The guarantee "never wider than YAML" has one exception: the value of another key is not read beyond the rule of characters and the check of its quoted scalars. So a skill still loads when YamlElixir does not read the value of another key, such as `metadata:` with `  a: b: c` under it, `other: :[x`, which YAML 1.2 reads as text, or `other: "x"` with `  k: "y"` under it. Its `name` and `description` are the ones that the key lines give.

The rule of characters is narrower than YAML on purpose. These common forms in the other keys of real skills are out, and each drops the skill with its notice:

- a flow list or map, such as `allowed-tools: [Read, Grep]` or `argument-hint: [file]`;
- a block scalar, such as `notes: |` or `compatibility: >-`;
- a quoted scalar that does not start the value: a quoted list item (`- "x"`), a quoted key (`  "k": x`), or a quote after a word (`other: a "x"`);
- a quoted scalar over more than one line;
- an indented comment, or a comment on a plain key line, with a quote after a blank (`# the "x" key`);
- an anchor, an alias, or a tag.

A plain value of words is in: `license: Apache-2.0`, `allowed-tools: Bash(git:*) Read`, `metadata:` with `  author: example-org` under it, and a list with `- Read` items. The frontmatter texts of the specification all load (`docs/research/agent-skills.md`): its "Example with optional fields" with `version: "1.0"` under `metadata`, `license: Proprietary. LICENSE.txt has complete terms`, `compatibility: Requires git, docker, jq, and access to the internet`, and `allowed-tools: Bash(git:*) Bash(jq:*) Read`. The files of this repository's `.claude/skills` have only `name` and `description`, so the rule drops none of them.

The proof is the differential property of `plugins/bundled/test/helyx/skills/frontmatter_test.exs`. It generates frontmatter in the subset and near it, with the construct characters at the start of a word and in a word in the values of other keys, and quoted scalars there that close on their line and ones that do not, and asserts that each one that the reader accepts gives the same `name` and `description` as `YamlElixir.read_from_string/1`. When YamlElixir rejects such a frontmatter, the exception applies: the same frontmatter with a plain `o<n>: x` for each other key must give them. `yaml_elixir` is a test-only dependency of `plugins/bundled`. A probe of 100,000 generated frontmatters (2026-10-18, with the quoted scalars of other keys), of which 5,021 were accepted and 948 of those had a quoted value in another key, found no difference. The files of this repository's `.claude/skills` and the frontmatter texts of the specification all read, and give what YamlElixir gives.

### After a summary compaction

Ticket #745. The model loads a skill, works for a long time, and the session compacts with a summary (`summary-compaction.md`). The skill text stays in the context after the cut, so the model goes on following it.

Decisions (the orchestrator's, with the owner away):

1. **Derive, not store.** The skills loaded in a session come from the transcript: the loads that `loaded?/2` finds, results of the skill tool and `/name` expansions. The session stores no new list.
2. **Where.** `Helyx.ModelContext.Default` adds the texts of the skills loaded before the cut as one user message after the summary, newest first. The ModelContext runs before the Compaction plugin, which puts the summary in front of the first kept message. So the ModelContext puts its message in front of the first kept message, with no id, and `Helyx.Compaction.Summary` keeps a message with no id before the cut after its summary: every message of the transcript has an id (`message-identity.md`), so a message with no id is one that the ModelContext added. The summary input does not hold it.
3. **Bounds.** At most 5 skill texts and 32,768 bytes for the whole message, newest first. A skill that does not fit gets one line that tells the model to load it again if it needs it.
4. **The file changes.** The text is the one in the transcript, the text that the model saw, not the file read again, so the context holds the same text as before the cut.
5. **Harness providers.** A provider that keeps its own history (Claude Code, Codex) runs its own compaction (`harness-compaction.md`) and never gets the Helyx summary in a normal turn: the program's summary decides if a loaded skill stays. A load of the skill tool after it gives the note, because the Helyx transcript still holds the earlier load, and the note tells the model to read `SKILL.md` (see "Accepted"). The skills message reaches a harness only in the replay after a model switch or a lost thread, the same as the Helyx summary.

The rule, at each context build with a summary (`opts[:summary]`): the messages before the first kept message (`Helyx.Summary.kept/2`) are the summarized part. A skill counts when a load of it is in the summarized part and no load of it is in the kept part: a load in the kept part is in the context already. Its text is the text of its newest load in the summarized part: the whole result of the skill tool, or a user message up to its last `\n</skill>`, so the arguments of `/name args` stay out. With no summary, or with a first kept id that is not in the messages, nothing is cut and no message is added.

`Helyx.Skills.carried(before, kept)` gives the text of the message, or nil:

```text
These skills were loaded before the summary above, newest first. Follow each one as before.

<skill name="ship">
...
</skill>

The skill tdd was loaded too, and its text is not here: load it again if you need it.
```

The texts come first, newest first, then the lines, newest first. A skill gets its text when fewer than 5 have one and its text fits what is left of the bound, else its line when that fits; from the first skill whose line does not fit, it and every older one are left out.

`Helyx.Tool.Skill` does not change: its transcript is the kept part, so a load of a carried skill after the cut gives the text again. The next build then finds the load in the kept part and leaves that skill out of the message, so the text is in the context once from then on.

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
| one `SKILL.md` | 65,536 bytes (`@max_file_bytes`), a regular file, valid UTF-8, checked by one `Helyx.Text.read_file/2` that reads at most 65,537 bytes | dropped with a notice that gives the reason of `read_file/2` |
| frontmatter read | in the scanning process, one pass over the lines of the frontmatter, linear in its bytes: at most 65,536 bytes from the file bound; the lines of another key are checked by the rule of characters or as a quoted scalar of one line and not kept, and no value expands (an anchor, an alias, or a tag drops the skill). Measured on 64 KB of each of the worst shapes (2026-10-18, `docs/devlogs/2026-10-18-skills.md`): at most 31.9 ms at a load average of 16.2, and at most 2.5 times the time on 32 KB | none |
| catalog text | 16,384 bytes (`@max_catalog_bytes`), the whole section, heading and rule line included | filled in precedence order; from the first skill that does not fit, that skill and every later one are left out of the catalog, the tool, and the command, with one notice |
| catalog skills | at most 200, from the read bound | as above |
| notices of one scan | one per skill folder of the scan, plus one for the folder bound and one for the catalog cut: at most 202 lines | none |
| one notice line | at most 1,024 bytes (`@max_notice_bytes`, `Helyx.Text.cap/3`); the TUI and print mode cut it again as every notice | cut on a character boundary |
| load text | `Helyx.Text.truncate/2` of the file (2,000 lines or 51,200 bytes, with its notice), the header, and the folder line capped at 4,096 bytes: at most about 56 KiB, under `Helyx.Message.max_result_bytes/0` (65,536), so the hands never cut it and its first line stays first | cut by `truncate/2` with a notice that names the next offset |
| skill name from the model | a string, else an error; a name that the scan does not hold is an error that echoes at most 64 bytes of it | error result |
| user command | the composer text or the print prompt; the expanded text is under 64 KiB plus the arguments, and `Helyx.Session` checks the 4 MiB bound of a message | the session refuses it |
| `Helyx.Tool.transcript/0` | the messages that `Helyx.Summary.kept/2` keeps, all of them with no summary, one copy per call; the call has no deadline, because the session never waits for a tool Task | none; the session holds it already. The call exits when the session ends |
| skills after a summary | at most 5 texts (`@max_carried`) and 32,768 bytes for the whole message (`@max_carried_bytes`), checked where the message text is joined; each part counts its bytes and the two bytes before it | the skill gets its line; from the first line that does not fit, the rest are left out |
| the scan for loads after a summary | one pass over the transcript at each build with a summary, one `\A` match of the first text of each message, and one search for `\n</skill>` in each user message that is a candidate for one of the 5 texts | none: the session holds the transcript already |

When the scan runs and what it costs: at each context build (the start of each turn, and before each model call of `Helyx.Provider.Loop`), at each skill tool call, at TUI mount, at each submitted `/word` in the TUI, and twice in print mode. So an edit to a skill takes effect at the next scan. On a folder of 200 skills of 2,046 bytes each, with a folded description, one scan with the frontmatter reader took a median of 56.5 ms (max 282.0 ms) in one run of 20 scans and 22.6 ms (max 46.2 ms) in a second, on the development machine at a load average of 5 to 7 (2026-10-18, `docs/devlogs/2026-10-18-skills.md`). The worst case reads 200 files of 64 KiB, 12.5 MiB.

Accepted:

- A file can change between the stat and the read of `Helyx.Text.read_file/2`; the read itself reads at most 65,537 bytes, so a file that grew after the stat is still dropped.
- Folder identity by inode assumes a POSIX filesystem.
- The scan, the tool, and the TUI read the skills of the machine that runs them. With a remote client, the TUI notices and the `/name` command read the client's disk, and the catalog and the tool read the server's disk.
- `Helyx.ModelContext.Default` takes the home folder from its `:home` option; the tool and the clients use `System.user_home!/0`. No product sets `:home`; a product that does gets a catalog that the tool does not match.
- A parent folder that other users can write (such as `/tmp`) can add project skills when the walk reaches it with no git root.
- After a native compaction of a harness, the harness can have dropped a loaded skill while the Helyx transcript still holds it; the note then tells the model to read `SKILL.md`.
- A user command always expands to the full text, also when the session loaded the skill already: the client holds no transcript, and the user asked for the skill again.
- The TUI user cell and the recall of an earlier prompt show the expanded text, not `/name args`.
- After a summary, a user message that starts with a `<skill name="...">` line that the user typed counts as a load, as it does for the note of decision 2.
- After a summary, the arguments of a `/name args` that hold a `\n</skill>` line go into the carried text up to that line.
- With the five texts at the bound, the lines of older skills can be left out: then the summary is the only trace of them.
- With `Helyx.Compaction.None` and a stored summary (a session file of a product with the summary plugin, resumed by one without it), the whole transcript is sent, and the carried message repeats skill texts that are in it.

## Ownership

None: each `SKILL.md` is opened and closed inside `Helyx.Text.read_file/2`, and `File.ls/1` and `File.stat/1` hold no handle after they return. The frontmatter reader starts no process.

## Out of scope

- Agent definitions (a separate ticket).
- Trust prompts for project skills: Helyx has no approval gate (#503).
- The `.well-known/agent-skills` index.
- Moving this repository's `.claude/skills` to `.agents/skills`: the old worker build still reads them there.
