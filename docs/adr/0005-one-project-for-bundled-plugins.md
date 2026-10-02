# One Mix project holds all bundled plugins

Until ticket #38 every bundled plugin was its own Mix project under `plugins/<name>`: nine projects, each with a lock file, a `precommit` alias, a dependency list, and a Dialyzer PLT. With the root and the coding agent app that made eleven projects. Root `mix precommit` built eleven PLTs, a dependency change meant a fetch in every project, and a new plugin started as a copy of project boilerplate. No product used the isolation that this cost gave: the one product depends on all nine.

## Decision

One Mix project, `plugins/bundled`, app `:helyx_plugins`, holds all bundled plugins and depends on the root by path. This reverses "one Mix project per plugin".

The layout follows scikit-learn. Core holds the interfaces. The bundled project holds the default implementations that ship with Helyx. A product depends on `:helyx_plugins` and registers the modules it wants; selection stays by module, through registration, as before. Contrib and external plugins stay separate packages under their own module root (`Acme.Provider.Bedrock`).

Module names and registration entries do not change. `Helyx.Provider.Fake` stays a normal module, not `only: :test`, because the coding agent app and other plugins' tests use it.

### The optional-dependency rule

A heavy or native dependency of one bundled plugin is declared `optional: true` in the bundled project, and the modules that need it are defined only when it is loaded: a `Code.ensure_loaded?/1` guard around the `defmodule`. A product that wants such a plugin adds the dependency to its own deps. `ex_ratatui` (a Rust NIF) is the first case: `Helyx.TUI`, `Helyx.TUI.Composer`, and `Helyx.TUI.Transcript` exist only when `ExRatatui.App` is loaded, and the coding agent app lists `ex_ratatui`. `Helyx.TUI.ViewModel` and `Helyx.TUI.Wrap` need nothing from `ex_ratatui`, so they have no guard.

The guard alone is not enough. Mix does not treat a module that appears later as a reason to recompile, and it reaches a stale source only through a module that the source defines; a guarded file that defined no module is never compiled again. So each guarded file also defines a small module that always exists (`Helyx.TUI.Available`, `Helyx.TUI.Composer.Available`, `Helyx.TUI.Transcript.Available`) with `__mix_recompile__?/0`, which Mix asks on every compile. Both parts are necessary. Measured on 2026-09-18 with Elixir 1.19.5, on a product that adds the optional dependency after its first build and then removes it:

- The guarded file defines no module: the add leaves a build without `Helyx.TUI`. A hook in a module in a different file does not help.
- The always-present module with no hook, in a toy project: the remove leaves the stale guarded module in the build.
- Both parts: add, remove, and add again each give the correct build.

A small, pure Elixir dependency is a normal dependency. `req` is the first case. `plug` stays `only: :test`.

## Considered options

- Keep one project per plugin. Rejected: the cost above, with no product that uses the isolation.
- Two projects, for example providers and tools. Rejected for now: split later only if a real product needs it.
- Move the bundled plugins into the root project. Rejected: Core stays small, and the root would gain `req` and `ex_ratatui`.

## Consequences

- Eleven Mix projects become three: root, `plugins/bundled`, `apps/coding_agent`. Three lock files, three PLTs.
- A new bundled plugin is a directory of modules and tests in `plugins/bundled`, not a project.
- Given up: per-plugin dependency isolation. A product that wants only the read tool still fetches and compiles `req` and every other normal dependency of the bundled project. The optional-dependency rule bounds this for heavy deps only.
- Given up: a compile-time check that one plugin does not call another. All bundled modules now share one project, so only review can find such a call.
- A guarded module that is absent is a run-time error, not a compile-time error. A call to it is an `UndefinedFunctionError`, and Core rejects it in a plugin list with `{:error, {:not_a_plugin, module}}`. The fix is the product's dep list.
- When `__mix_recompile__?/0` answers true, Mix touches the guarded files (`lib/helyx/tui.ex`, `lib/helyx/tui/composer.ex`, `lib/helyx/tui/transcript.ex`) to force the compile, and the next Mix command prints a note that it reset their mtime. Content does not change.
- Application env keys follow the app: the OpenAI provider's test seam moved from `:req_options` of `:helyx_provider_openai` to `:openai_req_options` of `:helyx_plugins`. All bundled plugins share that app, so a key names its plugin.
- The per-plugin test helpers merged into one `test_helper.exs`.

## Revision

2026-09-25, ticket #10. The Claude Code provider spawns `claude` and must stop it with the same guarantees as the bash tool (ADR 0004): its own process group, held with the hands before it runs, killed when the port closes, and released through `release/3`. The rule "one bundled plugin does not call another" stays. Code that two bundled plugins need goes into a helper module of the bundled project that is not a plugin, and both call it. The first one is `Helyx.Watchdog` (`plugins/bundled/lib/helyx/watchdog.ex`): the perl watchdog, the launcher, the marker and go-ahead handshake, and the release of the groups (`Helyx.Watchdog.Group`, formerly `Helyx.Tool.Bash.Group`). The bash tool and `Helyx.Provider.ClaudeCode` both delegate their `release/3` to it. The OS work stays out of Core (ADR 0004, revision of 2026-09-25). A helper module has no registration entry and implements no interface; it is `@moduledoc false`.

2026-09-25, ticket #11. `Helyx.HarnessIO` (`plugins/bundled/lib/helyx/harness_io.ex`) is the second helper module. It holds the stdout line cap, the exit wait, the error text cut, the prompt split, and the replay cap that `Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex` share. Each provider keeps its own protocol.

2026-09-26, ticket #125. `Helyx.HarnessIO` wraps every `Helyx.Watchdog` call of the harness providers: it already wrapped `start`, and it now also wraps `write`, `close` (as `stop/1`), and `release`. `Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex` call no `Helyx.Watchdog` function, so each provider calls one helper. The bash tool still calls `Helyx.Watchdog` directly. The watchdog protocol and every deadline are unchanged (ADR 0004).

2026-09-30, ticket #258. The exit wait left `Helyx.HarnessIO`: no harness provider used it after #200 and #201.

2026-10-03, ticket #327. `Helyx.TUI` split into `Helyx.TUI.Wrap`, `Helyx.TUI.Composer`, and `Helyx.TUI.Transcript`. Wrap needs nothing from `ex_ratatui` and has no guard. Composer and Transcript each have their own guard and their own always-present module in their own file, as the rule above requires. Checked on a scratch product: add `ex_ratatui`, remove it, and add it again each give the correct build.
