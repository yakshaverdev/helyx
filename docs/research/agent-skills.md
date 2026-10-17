# Agent skills: standard and harness practice (2026-10-17)

The sources are shallow clones from 2026-10-17. The short SHAs are agentskills/agentskills `69ef37e`, vercel-labs/skills `13e4063`, openai/codex `ce0323f`, badlogic/pi-mono `8efd314`, sst/opencode `8c173a8`, google-gemini/gemini-cli `ed96fae`, block/goose `bfcc6ee` and mattpocock/skills `49dd158`. Claude Code facts come from code.claude.com/docs/en/skills, fetched 2026-10-17.

## 1. The standard (agentskills.io)

The spec is `docs/specification.mdx` @69ef37e. It is identical to https://agentskills.io/specification (fetched 2026-10-17).

- **Layout**: a skill is a folder with `SKILL.md`. The optional subfolders are `scripts/`, `references/` and `assets/`, and any other file is allowed (8-17, 187-214).
- **Frontmatter** (25-32):
  - `name` (required): 1-64 chars, `a-z0-9-`, no leading, trailing or double hyphen. It **must match the parent directory** (60-65).
  - `description` (required): 1-1024 chars. It states what the skill does and when to use it.
  - `license` (optional).
  - `compatibility` (optional): at most 500 chars.
  - `metadata` (optional): a string-to-string map "for additional properties not defined by the spec" (150-152).
  - `allowed-tools` (optional): space-separated, "Experimental" (165-167).
- **Disclosure**: the metadata (about 100 tokens) loads at startup. The body loads on activation; under 5000 tokens is recommended. Resources load on demand. Keep `SKILL.md` under 500 lines (218-224).
- **Paths**: relative to the skill root, at most one level deep (228-237).
- **Versioning**: the format has no version number.
- **Validator**: `skills-ref` **rejects any key outside the six** (validator.py:15-22, 104-114). It also accepts `skill.md` (parser.py:23).

**Frontmatter texts of the spec page** (https://agentskills.io/specification, read 2026-10-18 by the orchestrator, quoted verbatim in its decision; this note did not fetch the page again). The "Example with optional fields":

```yaml
---
name: pdf-processing
description: Extract PDF text, fill forms, merge files. Use when handling PDFs.
license: Apache-2.0
metadata:
  author: example-org
  version: "1.0"
---
```

The page also gives these values of single fields:

- `license: Proprietary. LICENSE.txt has complete terms`
- `compatibility: Requires git, docker, jq, and access to the internet`
- `allowed-tools: Bash(git:*) Bash(jq:*) Read`

The page says that `metadata` is "a map from string keys to string values" and that `allowed-tools` is "a space-separated string".

**Client guide** (`docs/client-implementation/adding-skills-support.mdx`). It is advice, not a rule:
- The spec "does not mandate where skill directories live". It recommends `<project>/.<client>/skills/`, `<project>/.agents/skills/`, `~/.<client>/skills/` and `~/.agents/skills/`. Some clients also scan `.claude/skills/` and the ancestors up to the git root (47-58).
- Scan bounds: depth 4-6 and at most 2000 directories (79).
- On a clash, "**project-level skills override user-level skills**". Inside one scope, either first or last may win, with a warning (85-87).
- Trust-gate project skills (91).
- Parse leniently. A name mismatch gets a warning. A missing description skips the skill (119-137).
- Store `name`, `description` and `location`, the absolute path (145-157).
- Put the catalog in the system prompt or in a tool description, for example `<available_skills>` XML (167-194). Hide skills with `disable-model-invocation` (220-228).
- Activate with the read tool or a dedicated `activate_skill` tool that has an enum of names (244-256). The user syntax (`/name` or `$name`) is the client's choice (260).
- Wrap the body in a tag with the skill dir and a resource list, and do not read the resources eagerly (276-308).
- Protect skill content from compaction and deduplicate activations (320-329).
- The guide says nothing about one skill invoking another.

**Draft remote discovery**: branch `jh/well-known-uri` @ab2ff8d, not merged. It defines `/.well-known/agent-skills/index.json` with `$schema …/discovery/0.2.0/schema.json` and entries of name, description, type, url and a `sha256:` digest (well-known-uri.mdx:12-71). vercel-labs/skills already reads it (providers/wellknown.ts:9, 116-127).

## 2. skills.sh and `npx skills` (vercel-labs/skills @13e4063)

skills.sh is the directory site. `npx skills` is an installer, not a spec (README:3).

- **Commands**: `add`, `use`, `list`, `find`, `remove`, `update` and `init`. A source can be GitHub, any git URL, a local path, or an archive URL. Downloads are capped at 10 MiB (README:36-153, 126).
- **Canonical store**: `.agents/skills/<name>`, or `~/.agents/skills/<name>` with `-g` (constants.ts:1-3, installer.ts:133-136).
- **Mode**: by default the CLI copies into the canonical store and symlinks each agent's folder to it. The alternatives are `copy` and `link` (installer.ts:34-38).
- Agents whose folder is `.agents/skills` get no link (agents.ts:914-916).
- **Folders** for about 80 agents (README:284-352):
  - Claude Code: `.claude/skills` and `~/.claude/skills`.
  - Codex and Pi: `.agents/skills` and `~/.agents/skills`.
  - OpenCode: `.agents/skills` and `~/.config/opencode/skills`.
  - Gemini: `.agents/skills` and `~/.gemini/skills`.
  - Goose: `.goose/skills` and `~/.config/goose/skills`.
- **Locks**:
  - Project: `skills-lock.json`, committed. It holds source, ref, skillPath and a SHA-256 hash of the files, with no timestamps (local-lock.ts:5-60).
  - Global: `~/.agents/.skill-lock.json` (skill-lock.ts:63-72).
- It reads skill lists from `.claude-plugin/marketplace.json` and `plugin.json` (README:485-501) and from a `package.json` `skills` field (skills-field.ts:4-8).

## 3. Harnesses

**Codex** (`codex-rs/ext/skills`)
- **Roots**, in order (host_roots.rs:56-185):
  1. `.codex/skills`
  2. `$CODEX_HOME/skills` (marked "Deprecated")
  3. `~/.agents/skills`
  4. `$CODEX_HOME/skills/.system`
  5. `/etc/codex/skills`
  6. plugin roots and extra roots
  7. `.agents/skills` in each directory from cwd up to `.git`
- **Clash**: Codex keeps same-name skills and sorts them Repo, User, System, Admin (host_merge.rs:227-266). A `$name` mention takes the first match, so the repo skill wins (selection.rs:65-75).
- **Bounds**:
  - Depth 6, 2000 dirs per root (loader/mod.rs:24-25).
  - Catalog: 2% of the context window, or 8,000 chars if the window is unknown. Descriptions are cut at 1,024 chars and are dropped when the budget overflows (render.rs:19-27, 126-151).
- **Frontmatter**: Codex reads only `name`, `description` and `metadata.short-description`, and it repairs colon-broken YAML (skills/src/parser.rs:7-90). Extra policy goes in `agents/openai.yaml` (loader/mod.rs:20-21).
- **Catalog**: a `## Skills` section. It tells the main agent to read `SKILL.md` with file tools and not to delegate that read (catalog_prompt.rs:24-40).
- **Invocation**: `$name` (mentions.rs:41) or a structured `UserInput::Skill` (user_input.rs:48-52). The body is injected as a user-role `<skill>` fragment (fragments.rs:92-127).
- **Plugin manifests**: `.codex-plugin`, `.claude-plugin` and `.cursor-plugin` (exec-server-protocol/src/protocol.rs:52-56).

**Pi** (`packages/coding-agent`)
- Pi "implements the Agent Skills specification" (docs/skills.md:7).
- **Roots**, in order (package-manager.ts:2464-2563):
  1. `.pi/skills` (trusted projects only)
  2. `.agents/skills` up to the git root (trusted only)
  3. `~/.pi/agent/skills`
  4. `~/.agents/skills`
  5. packages
- **Clash**: the **first wins**, with a diagnostic (skills.ts:426-455).
- The name does not need to match the dir (skills.md:83).
- **Catalog**: system-prompt `<available_skills>` with location, plus "Use the read tool" (skills.ts:358-388).
- **Invocation**: `/skill:name args` sends `<skill name location>`, the body without frontmatter, then the args (agent-session.ts:2178-2196).
- No size bounds were found.
- **Packages**: `pi install npm:|git:` reads `skills/` or `pi.skills` (docs/packages.md:9-70).

**OpenCode** (`packages/core`)
- **Docs** (web/…/skills.mdx:16-30):
  - Project: `.opencode/skills`, `.claude/skills` and `.agents/skills`, walking up to the worktree.
  - Global: `~/.config/opencode/skills`, `~/.claude/skills` and `~/.agents/skills`.
- Config may also list paths or HTTP URLs (config/plugin/skill.ts:83-101).
- **Identity**: the id is the dir name (skill-file.ts:45-56). It is a map key, so a later add replaces an earlier one (skill.ts:100-102). The source order was not traced.
- **Extensions** go in `metadata`, for example `opencode/autoinvoke` (skill-file.ts:49-51).
- **Catalog**: the docs say it is in the tool description. Source renders an instructions block with `<available_skills>` and sends deltas when skills change (skill/instructions.ts:16-90).
- **Load**: the `skill({id})` tool, gated by allow, deny or ask permissions (tool/plugin/skill.ts:12-60). It returns `<skill_content>` with the base dir and at most 10 sampled files (skill.ts:36-67).

**Gemini CLI**
- **Tiers**, low to high: built-in, extension, `~/.gemini/skills`, `~/.agents/skills`, `.gemini/skills`, `.agents/skills`. Workspace tiers need trust.
- **Clash**: the last wins, with a warning (skillManager.ts:52-145).
- **Catalog**: system-prompt XML (prompts/snippets.ts:318-331).
- **Load**: `activate_skill` with an enum of names and user consent. It adds the skill dir to the allowed paths (activate-skill.ts:143-180).
- **Invocation**: `/name args` (SkillCommandLoader.ts:38-52).
- **Install**: `gemini skills install <git> --path`.

**Goose**
- **Roots**, in order (skills/mod.rs:318-375):
  1. project `.agents`, `.goose`, `.claude`
  2. plugins
  3. `~/.agents/skills` (the canonical writable folder, mod.rs:45-53)
  4. `~/.config/goose`
  5. `~/.claude`
  6. `~/.config/agents`
  7. built-ins, only when the name is unseen (mod.rs:442-470)
- **Catalog**: bullets in the extension instructions (client.rs:243-263).
- **Load**: the `load_skill` tool (client.rs:84-90).
- **Invocation**: `/name args`.

**Claude Code** (docs)
- **Locations**: enterprise; `~/.claude/skills`; `.claude/skills` from cwd up to the repo root; nested `<subdir>/.claude/skills`, loaded lazily as `/subdir:name`; `--add-dir`; plugins as `/plugin:skill`; claude.ai account skills. Commands are merged into skills.
- **Clash**: "enterprise over personal, and personal over project", against the guide.
- `.agents/skills` is not mentioned.
- **Extra keys**: `when_to_use`, `argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`, `model`, `effort`, `context: fork`, `agent`, `hooks`, `paths` and others.
- **Arguments**: `$ARGUMENTS`, `$N` and named `$name`. If no placeholder takes them, `ARGUMENTS: <value>` is appended.
- **Load**: the Skill tool, with `Skill(name)` permission rules.
- **Budget**: 1% of the context window, with the least-used descriptions dropped first. Each entry is capped at 1,536 chars.
- **Catalog location**: not stated in the docs. Observed in this session: a system-reminder.

## 4. Nested invocation

No spec text covers it. In practice the body tells the model to activate another skill. mattpocock wayfinder/SKILL.md:124 says "call the Skill tool for whichever skills the `## Notes` block names". In this repo, `/implement` ends in `/ship`. Codex adds "Multiple mentions mean use them all" (catalog_prompt.rs:8). Inference: no harness keeps a call stack or passes arguments between skills.

## 5. Third-party bundles

mattpocock/skills ships `.claude-plugin/plugin.json` with its skill paths. Its README gives a separate route per agent (README:29-100):
- Claude Code: a plugin.
- Codex and Copilot: marketplaces that read `.claude-plugin`.
- Gemini: `gemini skills install --path`.
- Others: `npx skills add mattpocock/skills -a <agent>`.

The README warns that two routes give "every skill twice". No single install standard exists. The portable common case is a folder in `.agents/skills` or `~/.agents/skills`.

## (a) Table

| Harness | Folders, in order | Catalog | Load | Syntax | Bounds |
|---|---|---|---|---|---|
| Spec guide | `.<client>/skills`, `.agents/skills`, user equivalents; project wins | system prompt or tool description | read or `activate_skill` | client's choice | depth 4-6, 2000 dirs, body under 5k tokens |
| Codex | `.codex/skills`, `~/.agents/skills`, `.system`, `/etc/codex`, plugins, `.agents/skills` up to `.git`; repo first | `## Skills` section | file read | `$name` | 2% or 8k chars; desc 1024 |
| Pi | `.pi/skills`, `.agents/skills` up to git root, `~/.pi/agent/skills`, `~/.agents/skills`; first wins | system prompt | `read` | `/skill:name args` | none |
| OpenCode | `.opencode`, `.claude`, `.agents` (walk up), global equivalents, URLs | instructions block | `skill({id})` | attach | 10 files listed |
| Gemini | built-in through `.agents/skills`; last wins | system prompt | `activate_skill` | `/name args` | not traced |
| Goose | `.agents`, `.goose`, `.claude`, then home equivalents | instructions | `load_skill` | `/name args` | not traced |
| Claude Code | enterprise, `~/.claude`, `.claude` (walk up), nested, plugins; personal wins | context | Skill tool | `/name args`, `$ARGUMENTS` | 1%; 1,536 chars |

## (b) What the standard fixes and what each harness decides

The spec fixes:
- the folder with `SKILL.md`
- six frontmatter keys and the name and description rules, with name equal to the dir name
- the subfolder names and relative paths
- three-tier disclosure

The guide only recommends:
- the `.agents/skills` folders
- project-over-user precedence
- lenient parsing and trust
- the catalog shape and compaction protection

Each harness decides alone:
- its own folders and their order
- precedence on a clash: Claude Code and Pi do not follow the guide
- the catalog location and budget
- the read tool or a skill tool
- the invocation syntax and arguments: only Claude Code substitutes placeholders
- extension keys: Claude Code uses top-level keys, OpenCode uses `metadata`, Codex uses `agents/openai.yaml`
- the plugin manifest: `.claude-plugin/plugin.json` is the de facto shared one
- nested invocation

## (c) Open questions for Helyx

1. Should Helyx scan only `.agents/skills` and `~/.agents/skills`, or also `.claude/skills`? Should it walk up to the git root, and should project skills wait for trust?
2. Which precedence applies: project over user (guide, Codex, Gemini) or user over project (Claude Code, Pi)? Does a clash emit an event?
3. How strict is the parser? Should a name that differs from the dir name be allowed? Should Helyx keys live in `metadata` (`helyx/…`)?
4. Should loading use a dedicated tool with an enum, a tag and compaction protection, or the read tool? Inference: under "Core knows only interfaces", that would be a Tool plugin plus a ModelContext plugin.
5. What catalog budget and per-entry cap? Codex uses 2% and 1024, Claude Code uses 1% and 1536.
6. Should user activation be `/name`, `$name`, or a structured input part, as in Codex and OpenCode? A structured part fits ADR 0008.
7. Should arguments be appended as text or substituted into `$ARGUMENTS`?
8. Should Helyx install skills itself, or rely on `npx skills` and `skills-lock.json`? Should it read `.claude-plugin` bundles?
9. Should a second activation of a loaded skill do nothing? Is there a depth limit?
10. Should Helyx follow the draft `.well-known/agent-skills` index?
