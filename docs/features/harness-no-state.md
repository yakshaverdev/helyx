# Harness session with no stored state

Ticket #750. The decision is in the triage comment of the ticket (2026-10-19).

## Goal

A product that uses Helyx as a library runs one prompt through a harness provider (`Helyx.Provider.ClaudeCode`, `Helyx.Provider.Codex`), and no file of the program that holds the conversation outlives the call. The login of the program still works: the option changes only what the program stores of the conversation.

Decisions:

- **A provider option of the session, off by default.** `Helyx.Session.start/2` and `Helyx.Session.resume/2` take `:provider_opts`, a keyword list. Core checks only that it is a keyword list, and gives it, after its own options, to `init/3` of every provider process of the session: the turn's and the summary call's. The session file does not keep it: a resume gives its own. A resume that attaches to a session that runs with other `:provider_opts` gives `{:error, :provider_opts_differ}`, because that session keeps its own options. Core does not name a key. Each provider checks the keys that it reads at `init/3` and ignores the others. Reason: Core knows only interface constructs; the options of `init/3` are one. The siblings #751 and #753 add their options on the same path.
- **A child session of the agent tool starts with the `:provider_opts` of its parent** (ticket #797, orchestrator decision of 2026-10-19). So a parent with `persist: false` has children whose harness program stores no conversation either. Core gives the session's `:provider_opts` to each tool call in `Helyx.Tool.context/0`, and `Helyx.Tool.Agent` passes them to the start of the child (`docs/features/agent-tool.md`). A resume of the child gives its own, as every resume does.
- **The option is `persist: false`.** Both harness providers read it; the default is `true`. A value that is not a boolean fails the provider's `init/3` with `{:invalid_option, :persist}`, and the turn fails.
  - Claude Code: every launch of the program has `--no-session-persistence`. `claude` 2.1.302 lists it in `--help`. The help says "only works with --print", but the Agent SDK in the same binary passes it with the stream-json flags and no `-p`, the launch mode of the provider (`docs/research/claude-code-stream-json.md`, "No session persistence").
  - Codex: `thread/start` has `ephemeral: true`. On codex 0.163.0 the schema of `codex app-server generate-json-schema` gives `ThreadStartParams.ephemeral` (boolean or null), and `Thread.ephemeral` is "Whether the thread is ephemeral and should not be materialized on disk". `ThreadResumeParams` has no `ephemeral` (`docs/research/codex-app-server.md`, "Ephemeral threads"). The answer to `thread/start` must have `thread.ephemeral` exactly `true`; any other answer fails the line check with `{:malformed, "thread/start"}`, and the provider process stops. Reason: only the program's answer confirms that it does not store the thread.
- **The resume rule.** A harness session with no stored state cannot be resumed. So the coding agent keeps the default.
  - The provider gives no `{:resume_id, id, cut}` event for it. The session stores no resume id, and each later provider process of the session starts a fresh harness session with the replay, as at the first turn. So does a `Helyx.Session.resume/2` of a session that ran with `persist: false`: its file holds no resume id. Reason: an id that names nothing to resume would make each later start go through the lost-session path.
  - In one provider process, a prompt change starts a fresh harness session with the replay in place of the resume: Claude Code a fresh program with a new id and a new meter, Codex a new program with a fresh ephemeral thread.
  - `init/3` with `persist: false` and a `:resume_id` fails with `:no_state_resume`, and the turn fails with `{:provider_init, :no_state_resume}`. That is one clear error, and nothing runs. It comes when `Helyx.Session.resume/2` with `persist: false` opens a session whose file holds a resume id of the provider, from a run with the default. Reason: that harness session has stored state; Claude Code would read it, and a Codex `thread/resume` takes no `ephemeral`, so the program would write the thread on. The id stays in the file: the next turn on that provider fails the same way. The caller resumes without the option, or starts a new session.
  - Claude Code: a compaction fails at once with `%Helyx.ProviderError{kind: :compaction_failed, text: "no stored state to compact"}`, and the program stays. Reason: the compaction runs in a program without `--disable-slash-commands` that resumes the harness session (`docs/features/harness-compaction.md`), and this harness session cannot be resumed. A Codex compaction runs in the running program, so the provider sends `thread/compact/start` as before; a compaction of an ephemeral thread was not run with a real program (research, "Not run").

## The environment of the program

Ticket #751. The decision is in the triage comment of the ticket (2026-10-19).

- **The option is `env`**, a map of string to string, default `%{}`, on the `:provider_opts` path of `persist`. Both harness providers read it at `init/3`, and every launch of the program gets it (`Helyx.HarnessIO.launch/4`): the first one, a relaunch after a prompt change or a lost session, and the program of a compaction. The map is added to the environment that the program inherits from the BEAM, and a key that is in both gets the value of the map. The perl watchdog and the `/bin/sh` that start the program get the same environment; the names that the shell sets itself are refused ("The check"). Reason: one option sets every variable. The state folder of the program is one use of it: `CLAUDE_CONFIG_DIR` for Claude Code, `CODEX_HOME` for Codex. It gets no option of its own.
- **The check.** Each key is a shell identifier: ASCII letters, digits, and `_`, not starting with a digit. It is not a name that the shell of the launch sets itself: `BASH`, `BASHOPTS`, `BASH_COMMAND`, `BASH_EXECUTION_STRING`, `BASH_SUBSHELL`, `BASH_VERSINFO`, `BASH_VERSION`, `CDPATH`, `COMP_WORDBREAKS`, `ENV`, `HISTCMD`, `IFS`, `LINENO`, `OLDPWD`, `OPTERR`, `OPTIND`, `POSIXLY_CORRECT`, `PPID`, `PS1`, `PS2`, `PS4`, `PWD`, `RANDOM`, `SHELLOPTS`, `SHLVL` (`@shell_names` of `Helyx.HarnessIO`). Each value is a non-empty string of valid UTF-8 with no NUL byte. Any other `env` fails `init/3` with `{:invalid_option, :env}`, and the turn fails. Reasons, from probes of 2026-10-19:
  - dash, the `/bin/sh` of Debian and Ubuntu, drops a name such as `A-B` from the environment of the program that it runs, while the bash of macOS passes it.
  - The `/bin/sh` of the launch sets some variables itself, so a value of the map would not reach the program as given. Through `/bin/sh -c 'exec "$0" "$@" 2>/dev/null'`, with the values `x` and `7`, the bash of macOS changed or dropped `IFS`, `LINENO`, `PPID`, `PS1`, `PS2`, `PWD`, `OLDPWD`, `OPTIND`, `OPTERR`, `HISTCMD`, `BASH`, `BASH_COMMAND`, `BASH_EXECUTION_STRING`, `BASH_SUBSHELL`, `BASH_VERSINFO`, `BASH_VERSION`, `COMP_WORDBREAKS`, `POSIXLY_CORRECT`, `RANDOM`, `SHELLOPTS`, and `SHLVL`; dash changed `IFS`, `PPID`, `PWD`, and `OPTIND`. The list adds the POSIX shell variables `PS4`, `ENV`, and `CDPATH` and the bash variable `BASHOPTS`. `CLAUDE_CONFIG_DIR` and `CODEX_HOME` reached the program unchanged in both shells. The launch keeps the shell: it drops stderr for every harness launch, and no caller needs these names (orchestrator decision of 2026-10-19).
  - `Port.open/2` unsets a variable whose value is empty, and raises `ArgumentError` for a `=` or a NUL in a name and for a NUL in a value. The conversion to a charlist raises for invalid UTF-8. A raise would put the value in a crash report.
- **The bytes of a value.** The port writes a charlist in the native name encoding of the BEAM. With `utf8`, the value goes as its characters. With `latin1`, the encoding of a BEAM in a locale that is not UTF-8, it goes as its bytes. So the program gets the UTF-8 bytes of the value in both (probe of 2026-10-19 with `+fnl` and `+fnu`).
- **Never logged.** With the default Logger config, Helyx puts no value of `env` in a log line, an event, an error, or a crash report. The error of a bad `env` names the option only. The provider states (`Helyx.Provider.ClaudeCode.State`, `Helyx.Provider.Codex.State`) leave the field out of `inspect`, so the crash report of a provider process, which can show its state ("Log and crash reports" in `docs/features/session-lifecycle.md`), does not show it. The open of the port runs in `Helyx.Reason.no_args/1`, so a raise of `Port.open/2`, such as `:emfile`, shows no options. The session keeps `:provider_opts` in its state, whose crash report is redacted. Accepted, as for message text in `docs/features/session-lifecycle.md`: with the SASL reports on (`handle_sasl_reports: true`), the supervisor report shows the start arguments of the session, and the proc_lib crash report its message queue, which can hold an attach call. Both hold `:provider_opts`, and so the values of `env` (Codex review of #751, round 1).
- **The stored id has no digest of `env`.** A digest of a secret would go into the session file. A resume with another state folder therefore asks the program for a harness session that is not in that folder. That is the program's own case of a lost harness session: Claude Code gives the lost result and Codex `no rollout found`, and the provider starts a fresh harness session with the replay (`docs/features/long-lived-harness.md`). This was not run with a real program.
- **The login.** That the login works with another state folder is a probe of the owner: no test reaches the network. Research: t3code sets `CLAUDE_CONFIG_DIR` and never `HOME`, because a changed `HOME` moves the macOS keychain lookup (`docs/research/t3code-harness-adapters.md`). The ChatGPT login of Codex is in `$CODEX_HOME/auth.json` (`docs/research/provider-parity.md`).

## Interface changes

- `Helyx.Session.start/2`, `Helyx.Session.resume/2`: the option `:provider_opts`, default `[]`. A value that is not a keyword list gives `{:error, :invalid_provider_opts}`, before any file or process is made.
- `Helyx.Provider` moduledoc: the options of `init/3` include the session's `:provider_opts`; a Core option comes first, so a provider option of the same name does not change it.
- `Helyx.Tool.context/0`: the key `provider_opts`, the session's `:provider_opts` (#797).
- `Helyx.HarnessIO.persist/1`: the `:persist` check of both harness providers.
- `Helyx.HarnessIO.env/1`: the `:env` check of both harness providers. It gives the map as charlist pairs, which the provider state keeps in the field `env`. `Helyx.HarnessIO.options/1` runs both checks and gives the state fields `persist?` and `env`. `Helyx.HarnessIO.launch/4` gives `state.env` to `Helyx.Watchdog.start/4`, whose new option `:env` (default `[]`) goes to `Port.open/2`. The bash tool gives none.
- Claude Code launch: `--no-session-persistence` with `persist: false`. Codex `thread/start`: `ephemeral: true` with `persist: false`.
- The attach of a resume (`Helyx.Session.Server.Open`) asks the running session `{:attach, provider_opts}`, in place of `:live`.
- `Helyx.Session.Server.State`: the field `provider_opts`, and the three single-mode plugins in one field `plugins`, so the struct keeps 31 fields (Credo `StructFieldAmount`).

## Replaced mechanism

- The attach of a resume asked `:live`, and any running session answered. It now asks `{:attach, provider_opts}`, and only a session with the same `:provider_opts` (compared exactly, so another order is other options) answers `:ok`; `:live` stays for `Helyx.Sessions.list_live/1`. A wire client cannot give `:provider_opts`, so its `resume` of a session that a product started with them gives `start_failed`.
- The default path of the harness providers does not change. With `persist: false`, the resume of a harness session is replaced by a fresh start with the replay, a path that exists for a lost session.
- The program inherited the environment of the BEAM as it is. It now gets the `env` map on top of it. With the default `%{}`, the environment is the same as before.

Users see: with `persist: false`, no `:resume_id` event, so no notice of a cut replay.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| `:provider_opts` | a keyword list (`Helyx.Session.Input.provider_opts/1`); its length is unbounded, accepted: the product's own code gives it, not a client. The session copies it into each `init/3` and into the context of each tool call, and the agent tool copies it into each child session (#797); the caps on tool calls and sessions bound the number of copies, not their size | `{:error, :invalid_provider_opts}` when it is not a keyword list |
| `:persist` | a boolean (`Helyx.HarnessIO.persist/1`, in `init/3` of each harness provider) | `init/3` fails with `{:invalid_option, :persist}` |
| Codex `thread/start` answer with `persist: false` | `thread.ephemeral` exactly `true` (`Helyx.Provider.Codex.Check`) | `{:malformed, "thread/start"}`; the provider process stops |
| `:env` | a map; each key a shell identifier (`[A-Za-z_][A-Za-z0-9_]*`) that is not one of the shell names of "The check", each value a non-empty string of valid UTF-8 with no NUL (`Helyx.HarnessIO.env/1`, in `init/3` of each harness provider) | `init/3` fails with `{:invalid_option, :env}` |
| the size of `:env` | no bound of Helyx, accepted: the product's own code gives it. The OS bounds the arguments and the environment of one exec together (`ARG_MAX`, 1,048,576 bytes on macOS) | the exec of perl fails with `E2BIG`, the port exits with status 7 before the marker, and the program does not start: `{:not_started, "the perl watchdog gave no marker: "}`. The text holds no value. A Claude Code turn fails with it, and a Codex `init/3` returns it |

The other bounds of the program and the replay are those of `docs/features/long-lived-harness.md`.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the conversation of the program | the program | the program's memory, no file | the program's exit | the program's exit (TERM, grace, KILL) | as at a crash |
| the state folder of `env` (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`) | the caller | the caller | the caller removes it after the call; Helyx neither makes nor removes it | as at a normal end | as at a normal end |

## Out of scope

- The program's other files (config, login, logs, caches): the caller sets the state folder of the program with `env` ("The environment of the program").
- The removal of an inherited variable: `env` only adds and replaces.
- Accepted: perl reads its own variables (`PERL5OPT`, `PERL5LIB`, `PERL_BADLANG`) from the same environment, so a caller that sets them changes the watchdog. The product's own code gives `env`, not a client.
- Accepted: perl's locale warning quotes the locale variables (`LC_ALL`, `LC_*`, `LANG`, `LANGUAGE`), and the text of a start that failed can hold that warning (`Helyx.Watchdog`). A bad locale value in `env` can therefore be in a `{:not_started, text}` error, as a bad inherited one can today.
- Accepted: the program's own output can hold a value, such as a path in an error text of a result line. That text is program text.
- A launch without `/bin/sh`: the names that the shell sets itself are refused instead ("The check").
- Open (round 3 of the review): the list covers the bash 3.2 of macOS and dash. The check accepts six names that bash 5 as `/bin/sh` (Fedora, RHEL, Arch) changes or drops: `BASHPID`, `BASH_ARGV0`, `SRANDOM`, `BASH_MONOSECONDS`, `EPOCHSECONDS`, `EPOCHREALTIME`. It also accepts two names that macOS changes with no shell: `XPC_FLAGS` (libxpc) and `XPC_SERVICE_NAME` (the fork of the perl watchdog).
- Open, not of this change, with a ticket of the orchestrator: a start that gives no marker or `0` keeps the watchdog handle that `Helyx.Watchdog.start/4` held (round 2 of the review, `docs/reviews/2026-10-19-751-harness-env.md`). An `env` over the OS limit is one way to reach it.
- The option on the wire: a client of the wire protocol cannot set `:provider_opts`.
- The Helyx session file: a session with no `:sessions_dir` writes none.
- That the login works with the option is a probe of the owner: no test reaches the network.
- Codex child threads (the `multi_agent` tools stay on): whether the program stores a child thread of an ephemeral thread was not probed.
