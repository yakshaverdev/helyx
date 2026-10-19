# Harness session with no stored state

Ticket #750. The decision is in the triage comment of the ticket (2026-10-19).

## Goal

A product that uses Helyx as a library runs one prompt through a harness provider (`Helyx.Provider.ClaudeCode`, `Helyx.Provider.Codex`), and no file of the program that holds the conversation outlives the call. The login of the program still works: the option changes only what the program stores of the conversation.

Decisions:

- **A provider option of the session, off by default.** `Helyx.Session.start/2` and `Helyx.Session.resume/2` take `:provider_opts`, a keyword list. Core checks only that it is a keyword list, and gives it, after its own options, to `init/3` of every provider process of the session: the turn's and the summary call's. The session file does not keep it: a resume gives its own. A resume that attaches to a session that runs with other `:provider_opts` gives `{:error, :provider_opts_differ}`, because that session keeps its own options. Core does not name a key. Each provider checks the keys that it reads at `init/3` and ignores the others. Reason: Core knows only interface constructs; the options of `init/3` are one. The siblings #751 and #753 add their options on the same path.
- **The option is `persist: false`.** Both harness providers read it; the default is `true`. A value that is not a boolean fails the provider's `init/3` with `{:invalid_option, :persist}`, and the turn fails.
  - Claude Code: every launch of the program has `--no-session-persistence`. `claude` 2.1.302 lists it in `--help`. The help says "only works with --print", but the Agent SDK in the same binary passes it with the stream-json flags and no `-p`, the launch mode of the provider (`docs/research/claude-code-stream-json.md`, "No session persistence").
  - Codex: `thread/start` has `ephemeral: true`. On codex 0.163.0 the schema of `codex app-server generate-json-schema` gives `ThreadStartParams.ephemeral` (boolean or null), and `Thread.ephemeral` is "Whether the thread is ephemeral and should not be materialized on disk". `ThreadResumeParams` has no `ephemeral` (`docs/research/codex-app-server.md`, "Ephemeral threads"). The answer to `thread/start` must have `thread.ephemeral` exactly `true`; any other answer fails the line check with `{:malformed, "thread/start"}`, and the provider process stops. Reason: only the program's answer confirms that it does not store the thread.
- **The resume rule.** A harness session with no stored state cannot be resumed. So the coding agent keeps the default.
  - The provider gives no `{:resume_id, id, cut}` event for it. The session stores no resume id, and each later provider process of the session starts a fresh harness session with the replay, as at the first turn. So does a `Helyx.Session.resume/2` of a session that ran with `persist: false`: its file holds no resume id. Reason: an id that names nothing to resume would make each later start go through the lost-session path.
  - In one provider process, a prompt change starts a fresh harness session with the replay in place of the resume: Claude Code a fresh program with a new id and a new meter, Codex a new program with a fresh ephemeral thread.
  - `init/3` with `persist: false` and a `:resume_id` fails with `:no_state_resume`, and the turn fails with `{:provider_init, :no_state_resume}`. That is one clear error, and nothing runs. It comes when `Helyx.Session.resume/2` with `persist: false` opens a session whose file holds a resume id of the provider, from a run with the default. Reason: that harness session has stored state; Claude Code would read it, and a Codex `thread/resume` takes no `ephemeral`, so the program would write the thread on. The id stays in the file: the next turn on that provider fails the same way. The caller resumes without the option, or starts a new session.
  - Claude Code: a compaction fails at once with `%Helyx.ProviderError{kind: :compaction_failed, text: "no stored state to compact"}`, and the program stays. Reason: the compaction runs in a program without `--disable-slash-commands` that resumes the harness session (`docs/features/harness-compaction.md`), and this harness session cannot be resumed. A Codex compaction runs in the running program, so the provider sends `thread/compact/start` as before; a compaction of an ephemeral thread was not run with a real program (research, "Not run").

## Interface changes

- `Helyx.Session.start/2`, `Helyx.Session.resume/2`: the option `:provider_opts`, default `[]`. A value that is not a keyword list gives `{:error, :invalid_provider_opts}`, before any file or process is made.
- `Helyx.Provider` moduledoc: the options of `init/3` include the session's `:provider_opts`; a Core option comes first, so a provider option of the same name does not change it.
- `Helyx.HarnessIO.persist/1`: the `:persist` check of both harness providers.
- Claude Code launch: `--no-session-persistence` with `persist: false`. Codex `thread/start`: `ephemeral: true` with `persist: false`.
- The attach of a resume (`Helyx.Session.Server.Open`) asks the running session `{:attach, provider_opts}`, in place of `:live`.
- `Helyx.Session.Server.State`: the field `provider_opts`, and the three single-mode plugins in one field `plugins`, so the struct keeps 31 fields (Credo `StructFieldAmount`).

## Replaced mechanism

- The attach of a resume asked `:live`, and any running session answered. It now asks `{:attach, provider_opts}`, and only a session with the same `:provider_opts` (compared exactly, so another order is other options) answers `:ok`; `:live` stays for `Helyx.Sessions.list_live/1`. A wire client cannot give `:provider_opts`, so its `resume` of a session that a product started with them gives `start_failed`.
- The default path of the harness providers does not change. With `persist: false`, the resume of a harness session is replaced by a fresh start with the replay, a path that exists for a lost session.

Users see: with `persist: false`, no `:resume_id` event, so no notice of a cut replay.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| `:provider_opts` | a keyword list (`Helyx.Session.Input.provider_opts/1`); its length is unbounded, accepted: the product's own code gives it, not a client, and the session copies it once into each `init/3` | `{:error, :invalid_provider_opts}` when it is not a keyword list |
| `:persist` | a boolean (`Helyx.HarnessIO.persist/1`, in `init/3` of each harness provider) | `init/3` fails with `{:invalid_option, :persist}` |
| Codex `thread/start` answer with `persist: false` | `thread.ephemeral` exactly `true` (`Helyx.Provider.Codex.Check`) | `{:malformed, "thread/start"}`; the provider process stops |

The other bounds of the program and the replay are those of `docs/features/long-lived-harness.md`.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the conversation of the program | the program | the program's memory, no file | the program's exit | the program's exit (TERM, grace, KILL) | as at a crash |

## Out of scope

- The program's other files (config, login, logs, caches): #751 sets the environment and the state folder of the program.
- The option on the wire: a client of the wire protocol cannot set `:provider_opts`.
- A child session of the agent tool does not get the parent's `:provider_opts`, so it stores its harness state. A product with `persist: false` leaves `agent` out of `:tools`; the use case gives the model no tool.
- The Helyx session file: a session with no `:sessions_dir` writes none.
- That the login works with the option is a probe of the owner: no test reaches the network.
- Codex child threads (the `multi_agent` tools stay on): whether the program stores a child thread of an ephemeral thread was not probed.
