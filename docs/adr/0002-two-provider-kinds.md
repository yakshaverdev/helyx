# Two provider kinds: model and harness

The user has Claude and Codex subscriptions and no API keys. Anthropic does not permit third-party programs to call its API with subscription credentials, but it does permit a user to sign in to the unmodified Claude Code binary. OpenAI documents the Codex app server for third-party clients. So the Provider interface admits two kinds. A model provider calls a model API, and Helyx runs the turn and the tools. A harness provider drives an external agent program over stdio and records what it did. Both write into the same transcript and emit the same events.

## Consequences

- During a harness turn, Helyx tools are not visible to the model. The harness uses its own tools. Exposing Helyx tools to a harness needs an MCP server and is a later change.
- The first model provider speaks the OpenAI wire format. There is no Anthropic Messages implementation, because the user has no API key to test it with.

## Revision

2026-09-26: The two provider kinds are now one flag named by behaviour, `turn/0`: `:local` (the default) or `:external`. An external turn runs the whole turn and its own tools in one provider call. The session records the tool results and does not run the tools. The provider keeps its own conversation state, which the session resumes by id. The stream runs under the hands. A steer aborts the turn. Claude Code and Codex have external turns. The reasons of this decision do not change. The product term "harness provider" stays and names a provider with an external turn (#123).

2026-09-30 (#265, approved by the owner): a provider is one of two kinds. An API provider has a local turn: Helyx runs the loop and the tools, and the provider implements `stream/3` (today the OpenAI-compatible provider). A harness provider is connected: it exports `harness_init/3` and the harness callbacks of ADR 0007 (today Claude Code and Codex). The export of `harness_init/3` is the only signal. The `turn/0` callback, the per-turn `:external` mode, and the start error `{:bad_provider_turn, id}` are gone, and `stream/3` is optional for a connected provider. No bundled provider used the per-turn mode; only test fakes did. A future harness program with no persistent-process mode, one that cannot keep a process across turns, would need the per-turn path again: a new decision that brings back a stream of the whole turn under the hands and a steer that aborts the turn.
