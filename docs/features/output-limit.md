# Output token limit of a session

Ticket #836. The owner's decision is in the ticket comment of 2026-11-06.

## Goal

A caller that wants a short answer, such as one line, a label, or a small JSON object, bounds the output tokens, and so the cost and the time, of each answer. Before this change the only bound on one assistant message was the 8 MiB content bound of Core (`Helyx.Session.Turn`), and the OpenAI request body held no output limit, so the default of the server applied.

Decisions:

1. **A start option of the session, not of a turn** (owner, 2026-11-06). `Helyx.Session.start/2` and `Helyx.Sessions.start/2` take `:max_output_tokens`. It sets the most output tokens of every assistant message of the session. No turn sets it, and a running session does not change it.
2. **Core checks the value and keeps it.** The check runs in `Helyx.Session.Input.start_options/2`, after `:model_context`, so nothing is created. The value goes to each `init/3` of the session as an option of Core, `:max_output_tokens`, nil without the option. An option of Core comes before `:provider_opts`, so a provider option of the same name does not change it. Reason: the limit is a provider construct, a rule that every model provider can carry; it is not a key of one provider in `:provider_opts`, whose keys Core does not check.
3. **A provider says that it applies the limit.** `Helyx.Provider` gains the optional callback `max_output_tokens?/0`. A provider whose callback returns `true` applies the limit to each model call; a provider without the callback cannot. A start with the option and a model of a provider that cannot gives `{:error, {:max_output_tokens_unsupported, provider_id}}` before any file or process. Reason: the requirement says that a provider that cannot apply the limit rejects it and does not ignore it; the session start runs no provider process, so the provider says it in a callback, as a tool says `concurrent?/0`. Core calls it once for each provider at its own start, as it calls `id/0`, and keeps the providers that return `true` (`Helyx.Core.limit_providers/1`); a return other than a boolean fails the start of Core with `{:error, {:invalid_max_output_tokens, module}}`. So a session start or a switch runs no plugin code for the check, and a raise of the callback reaches the caller of the Core start, as a raise of `id/0` does.
4. **A model switch keeps the guarantee.** `Helyx.Session.set_model/2` to a model of a provider that cannot apply the session's limit gives the same error, and the model stays as it was. Reason: without it the next turn would run with no limit, which decision 3 forbids. The caller of the switch reads the Core's list and sends the answer with the switch, because it does not know the limit of the session; the session compares the answer with its limit. Review history: a first design called the callback at each start and switch; a raise at a switch either crashed the session or, as an `ArgumentError`, came back as `:session_not_found` (review of #836, rounds 1 and 2).
5. **`Helyx.Provider.Loop` passes the limit to `stream/3`.** It keeps `:max_output_tokens` with `:core`, `:session_id`, and `:cwd`, so each model call gets it in `opts`. The Loop does not declare `max_output_tokens?/0`: whether a model provider applies the limit is the decision of its `stream/3`.
6. **The OpenAI engine applies it in the field that the endpoint names.** `use Helyx.Provider.OpenAI` defines `max_output_tokens?/0` as `true`, and takes the endpoint option `max_tokens_field`: `:max_completion_tokens`, the default, the field of the OpenAI chat completions API, or `:max_tokens`, the older field that a compatible server may read instead. With a limit, the request body holds `"<field>": limit`. Without one, the body is as before.
7. **`Helyx.Provider.OpenAI.Go` keeps the default field.** No source in this repository says which field the OpenCode Go server reads, and a probe of the real server is outside this change. Accepted hole: if the server ignores `max_completion_tokens`, a session on `opencode-go` with the limit runs with the default of the server. An endpoint module sets `max_tokens_field: :max_tokens` when its server needs it.
8. **The harness providers reject the limit.** `Helyx.Provider.ClaudeCode` and `Helyx.Provider.Codex` do not implement `max_output_tokens?/0`, so a start with the option on them gives the error of decision 3. `Helyx.Provider.Fake` does not either.
9. **The summary call gets no limit.** The summary call of a compaction (`summary-compaction.md`) starts a provider process with `max_output_tokens: nil`. Reason: the limit is of the assistant messages of the session; a summary is not one, and a summary cut at a small limit would replace the history with a part of a summary.
10. **An answer at the limit ends as before.** A model call that stops at the limit ends with the stop reason `:max_tokens`, and no tool call of that reply runs (#494, `one-provider-path.md`).
11. **A resume gives no limit.** As `:tools` and `:model_context`, the session header does not keep the option, and `Helyx.Session.resume/2` does not take it. A resume that attaches to a running session gets that session as it runs, with its own limit. Accepted hole: a resumed session runs with no limit.

## Interface changes

- `Helyx.Session.start/2`, `Helyx.Sessions.start/2`: the option `:max_output_tokens`, nil or an integer from 1 to 2,147,483,647. Errors: `{:error, :invalid_max_output_tokens}` and `{:error, {:max_output_tokens_unsupported, provider_id}}`.
- `Helyx.Session.set_model/2`: the error `{:error, {:max_output_tokens_unsupported, provider_id}}`, part of `t:Helyx.Session.model_error/0`.
- `Helyx.Provider`: the optional callback `max_output_tokens?() :: boolean()`, and the option `:max_output_tokens` of `init/3`.
- `Helyx.Core.start_link/1`: the error `{:invalid_max_output_tokens, module}`.
- `Helyx.Provider.Loop`: `stream/3` gets `:max_output_tokens` in `opts`.
- `Helyx.Provider.OpenAI`: the endpoint option `max_tokens_field`, and `max_output_tokens?/0`.
- The wire: no new field or code. The `set_model` op answers `failed` for the new error. A wire client cannot start a session with the limit (see "Out of scope"), so it gets the error only on a session that product code started.

## Replaced mechanism

None. The option is new; without it each start, body, and init option list is as before, plus `max_output_tokens: nil` among the options of `init/3`.

No state without a bound is added: the session state holds one integer or nil.

## Bounds

| What | Bound | Over the bound | Where |
| ---- | ----- | -------------- | ----- |
| `:max_output_tokens` | nil, or an integer from 1 to 2,147,483,647, the largest signed 32-bit integer, which every server that reads the field as an integer takes | `{:error, :invalid_max_output_tokens}`, before any file or process | `Helyx.Session.Input.start_options/2` |
| the provider of the model | a provider whose `max_output_tokens?/0` returns `true`, when the limit is set | `{:error, {:max_output_tokens_unsupported, id}}`: at a start before any file or process, at a switch with the model as it was | the start: `Helyx.Session.Input.model/3`; the switch: `Helyx.Session.set_model/2` reads `Input.limit_supported?/2`, and the session's `set_model` call compares the answer with its limit |
| `max_output_tokens?/0` of a provider | absent, or a return of `true` or `false` | Core does not start: `{:invalid_max_output_tokens, module}` | `Helyx.Core.Plugins.limit_providers/1` |
| `max_tokens_field` | `:max_completion_tokens` or `:max_tokens` | the compile of the endpoint module fails | `Helyx.Provider.OpenAI.Endpoint` |

The limit is not a bound that Helyx enforces on the stream: the server applies it, and the stop reason `:max_tokens` reports it. The 8 MiB content bound of Core still holds for every message.

## Ownership

None: the option creates no external resource.

## Out of scope

- **The wire field and a CLI flag.** The wire `start` op stays `cwd` and `model` (`wire-protocol.md`), as for `:model_context` (`session-model-context.md`, "Out of scope"); a field is a protocol bump. The coding agent and print mode get no flag.
- **A limit of a turn** (decision 1).
- **A child session of the agent tool** gets no limit from its parent.
- **The harness providers** (decision 8).
