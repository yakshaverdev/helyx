# AGENTS.md

Instructions for coding agents that work in this repository. `CLAUDE.md` is a symlink to this file.

## Project

Helyx is a BEAM-native substrate for malleable software. It is an Elixir framework for agent-native, stateful products. Read `README.md` for the architecture.

Key design constraints:

- Core stays small. It contains only plugin registration, OTP supervision, and interface dispatch.
- Everything else is a plugin: memory, tools, model context, compaction, transports, user interfaces.
- The extension surface is small: Provider, Tool, ModelContext, Compaction, Event, and one Transport.
- The server owns agent and session state. Clients are thin and render from the event stream.
- Local mode runs server and TUI in one BEAM node with OTP messages. Phoenix is not in core; it arrives later as a Transport plugin.

First checkpoint: a terminal coding agent (pi.dev style) built on these primitives.

## Repository layout

```text
AGENTS.md          Agent instructions (this file). CLAUDE.md symlinks here.
CONTEXT.md         Domain glossary (created lazily by /domain-modeling)
docs/
  adr/             Architecture decision records: NNNN-<slug>.md
  agents/          Per-repo config for the engineering skills
  devlogs/         Dated work logs: YYYY-MM-DD-<topic>.md
  features/        One design doc per feature, written before implementation
  research/        Source research that feature docs cite: <topic>.md
  reviews/         Code review outputs and follow-ups
lib/helyx/         Helyx core, interfaces, session, and message shapes
test/              Tests, mirrors lib/. test/support/ holds test-only plugins
plugins/bundled/   All bundled plugins in one Mix project, app helyx_plugins, path dependency on the root (ADR 0005)
apps/<name>/       Products, one Mix project each
```

## Commands

Run from the repository root. The Mix projects are the root, `plugins/bundled` with all bundled plugins, and one project for each app. The root `precommit` alias finds every `plugins/*/mix.exs` and `apps/*/mix.exs` and runs `mix precommit` in each project.

- `mix test`: run all tests
- `mix test path/to/file_test.exs:123`: run one test by line number
- `mix format`: format code
- `mix precommit`: in the root, format, compile with warnings as errors, Credo strict over all sources, Dialyzer, and test. Then, in `plugins/bundled` and in every app, format, compile, Dialyzer with a forced PLT check, and test. A new project needs its own `precommit` alias. The root run fails without one. Every precommit alias starts with `deps.get --check-locked`, so a fresh worktree or a rebase that brings a new project needs no manual fetch. `mix precommit` never changes a lock file: after you change a dependency in a `mix.exs`, update the locks yourself and commit them. Projects depend on each other by path, so one change can make other locks stale. Fetch in all of them: `for d in . plugins/* apps/*; do (cd "$d" && mix deps.get); done`. Run `mix precommit` before you finish any change.
- Send precommit output to a log file and search the log: `mix precommit > precommit.log 2>&1 && echo passed || { echo failed; false; }`, then `grep -n "==> precommit\|\*\* (\|error\|warning\|failure" precommit.log`. The root run prints `==> precommit <project>` before each project, so the last such line above an error names the project. An error above the first such line belongs to the root. Git ignores `precommit.log`. The run takes minutes, and the line that names the failure is rarely among the last ones. Never pipe it to `tail`, and never rerun it to read an error.
- `cd plugins/bundled && mix test test/helyx/tool/read_test.exs`: run one test file of a plugin

## Elixir guidelines

- Elixir has no `return` statement and no early return. The last expression in a block is the value.
- Use pattern matching and multiple function clauses over conditional logic.
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail. Reserve exceptions for unexpected states.
- Use structs over bare maps when the shape is known.
- Name processes only when necessary; pass pids or use Registry.
- Prefer `GenServer.call/3` over `cast/2` so callers get back-pressure.
- Do not add parentheses to keyword-style macro calls (`field :name, :string`, `plug :foo`).
- A test asserts order and properties, not an upper bound of elapsed wall-clock time. Other worktrees and precommit runs load the machine, so an upper bound fails at random (#193). A wait that must not happen is checked with a margin for load, and the margin is stated.
- Tests end with `_test.exs` and mirror the `lib/` structure. Prefer async tests (`use ExUnit.Case, async: true`) unless the test touches shared state.
- Write `@moduledoc` and `@doc` for public modules and functions. Use `@moduledoc false` for internal modules.
- Prefer `Req` for HTTP; avoid `:httpoison`, `:tesla`, and `:httpc`.
- Validate at boundaries. A boundary is where data comes from something this code does not control: client input, plugin output into Core (stream events, tool results, callback returns), the disk, external programs and networks, tool arguments from the model at the tool entry, terminal input, and config. Check there, and handle the error there. Inner code trusts the check: it has no fallback clause, error return, or repair for a state that no caller can make. A state that only a bug can make crashes ("let it crash"); a pattern match or a guard that crashes is fine.
- Remove a repeated check only when the earlier check still proves the same property. Keep a documented safety check. Check the new limits that a transformation, an accumulation, or elapsed time introduces (text that expands, a buffer that grows, a deadline that approaches).
- Use the checked value. If an operation reads a new value, validate that value before use. A prior check of external state does not remove the need to handle a failure when the state is used.
- Reject the smallest unit that permits safe continuation. Keep unrelated data when its validity is known. State when missing identity, damaged structure, or an unresolved resource requires a larger failure.

## Module naming

- Core is `Helyx.Core`. An interface is `Helyx.<Interface>`, for example `Helyx.Provider`. A product uses its own root, for example `Acme`.
- A plugin is `<Root>.<Interface>.<Name>`. The root tells you who owns the code:
  - Bundled plugins use the `Helyx` root: `Helyx.Provider.Anthropic`, `Helyx.Tool.Shell`, `Helyx.Transport.Local`.
  - External plugins use their own root: `Acme.Provider.Bedrock`. Do not define modules under `Helyx.*` outside this repo. Module names are global in a BEAM node, and two packages that define the same module fail to compile together.
- A new bundled plugin is a module under `plugins/bundled/lib/helyx/<interface>/` with its tests under the same path in `test/`, not a Mix project. A small, pure Elixir dependency is a normal dependency of `helyx_plugins`. A heavy or native one is `optional: true`. The modules that need it are defined only when it is loaded. The product lists the dependency itself. `ex_ratatui` and `Helyx.TUI` are the example (ADR 0005). An application env key of `helyx_plugins` names its plugin, for example `:openai_req_options`.
- Code that two bundled plugins need is a helper module in `plugins/bundled`, such as `Helyx.Watchdog`. It is `@moduledoc false`, implements no interface, and has no registration entry. Both plugins call the helper; one plugin never calls another (ADR 0005).
- The path follows the module name, except in `lib/helyx/interfaces/` and `lib/helyx/data/`. These two folders group files only. They are not part of the module name.
- Core resolves a plugin by its registration entry and a behaviour check, not by its module name. The module path is a reading aid only.
- An interface module such as `Helyx.Provider` stays a pure behaviour and public API. It never becomes a default implementation. Implementations live one level below it.

## Docs conventions

- **Devlogs** (`docs/devlogs/`): one file per work session, named `YYYY-MM-DD-<topic>.md`. Record what was done, what broke, and what is next.
- **Features** (`docs/features/`): one file per feature, named `<slug>.md`. Write the design before the implementation, starting from `docs/features/TEMPLATE.md`. State the goal, the interface changes, the bounds of every input, buffer, and wait, and what stays out of scope.
- **Research** (`docs/research/`): facts gathered from outside sources, named `<topic>.md`, with the date and the source revisions. It records observations; tickets and feature docs hold the decisions.
- **Reviews** (`docs/reviews/`): outputs of code reviews, named `YYYY-MM-DD-<scope>.md`, with findings and their resolution.
- **Decisions** (`docs/adr/`): architecture decision records, named `NNNN-<slug>.md`, with context, decision, and consequences.

## Git conventions

- Every commit goes through `/ship`: simplify, review on three axes, `mix precommit`, commit. See `.claude/skills/ship/SKILL.md`.
- `/orchestrate` runs the ready tickets to merged on master without the user: worktree, `/implement`, a Codex review until clean, rebase, merge. It parks what needs a person as `ready-for-human`. `/hitl` asks the user those parked decisions and starts the orchestrator again.
- Tickets are built with `/implement <n>`, the project skill, which ends in `/ship`. Do not use `mattpocock-skills:implement` here; it reviews and commits on its own path.
- Conventional commits: `type(scope): message` (see existing history).
- Do not commit generated artifacts (`_build/`, `deps/`, `.elixir_ls/`).

## Agent skills

### Issue tracker

Issues live in GitHub Issues for `akshaydeshraj/helyx` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Review checklist

Invariants the failure-path review axis checks. See `docs/agents/review-checklist.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
