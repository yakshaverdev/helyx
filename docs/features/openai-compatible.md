# OpenAI-compatible endpoints

Ticket #652. The decisions are in the ticket and its comment "Decisions (orchestrator, 2026-10-17)".

## Goal

`Helyx.Provider.OpenAI` is the engine for the OpenAI chat-completions wire format. Before this change it was bound to one vendor: it named two OpenCode base URLs, the `OPENCODE_API_KEY` variable, and the `x-opencode-session` header. After it, the engine names no vendor. Each endpoint is a small module that gives its constants to the engine with `use`:

```elixir
defmodule Acme.Provider.Local do
  use Helyx.Provider.OpenAI, id: "local", base_url: "http://localhost:11434/v1"
end
```

A product owner adds one such module under the product root and registers it, and a session runs on `local/<model>`. No Helyx code changes. Registration does not change: Core registers modules and calls `id/0` of each (`lib/helyx/core/plugins.ex`). An endpoint made at run time needs a change to registration, so it stays out of scope.

`Helyx.Provider.OpenAI.Go` is the one bundled endpoint, so `opencode-go/kimi-k2` stays the default of the coding agent. OpenCode Zen is removed. It needs no special code, so it comes back as one endpoint module when someone needs it, and the `opencode` prefix is free for a future harness provider (#651).

## Interface changes

`use Helyx.Provider.OpenAI, opts` defines `id/0` and `stream/3` of a `Helyx.Provider.Loop` provider. The options:

| Option | Value | Default |
| ------ | ----- | ------- |
| `id` | the ref prefix: a string that is a valid `Helyx.ModelRef` provider part, with no `/` | required |
| `base_url` | an `http` or `https` URL with a host and no query or fragment, with any `/v1` prefix. The engine appends `/chat/completions` | required |
| `key_env` | the name of the environment variable that holds the API key, or nil. Nil sends no `Authorization` header, for a local server; it also replaces an `auth` of Req's `:default_options` | nil |
| `headers` | a list of `{name, value}`. A value is a string, or `:session_id` for the Helyx session id of the call | `[]` |
| `catalog` | the catalog id of `Helyx.ModelInfo.Catalog` for the window and the prices: one of the ids that the catalog keeps, or nil | nil |

The engine checks the options when the endpoint module compiles. A bad or missing option raises `ArgumentError` and an unknown option raises `KeyError`, so the compile fails with the name of the option. The key is read at each call.

- **The key.** A variable that is not set, or is set to the empty string, fails the call with `{:error, {:missing_env, name}}` before any request, as before. A value outside the bounds below fails the call with `{:error, {:bad_env, name}}`. The bound is the bearer token syntax of RFC 6750 (`b64token`), so a key that a header cannot hold never reaches the HTTP client, and no JSON encoder must escape its characters; some escape `/` as `\/`. No event of the engine holds the key. So the key reaches no error that the call returns and no error that Core builds from an event (a delta that is not a string), and through them no turn error, no session file, and no log line made from an error. In every string of every event (an HTTP error body, an `api_error` object, a `bad_chunk` payload, a delta, map keys and struct fields too), each byte of each copy of the key and of its JSON form with `\/` becomes `*`, so a copy becomes `*` of the same length. The mask keeps the length, so no bound on a text changes, and a key has no `*`, so a mask cannot make a new copy. In an HTTP error body the mask comes before the cut. Helyx writes no log of the request. Accepted holes, each not masked: a key in `\uXXXX` escapes (JSON allows the form for any character; Gson and .NET `System.Text.Json` write `+` or `=` that way) in an HTTP error body or a `bad_chunk` payload; a key with some slashes escaped and some not; a JSON array of the character codes of the key, which the turn error prints as a charlist. Also not masked in full: a copy of the key that overlaps an earlier copy (a key whose first bytes equal its last bytes, as in `ab…ab`), which `:binary.replace/4` with `:global` skips. Only the bytes past the end of the earlier copy show. The `api_error` path decodes the JSON first, so it masks a `\uXXXX` form. The reason: no real provider is shown to echo a key in one of these forms or as overlapping copies, and a case gets its own handler only with evidence (`AGENTS.md`). These are the third finding on the mask mechanism (review of 2026-10-17, round 3), so the mask stays on the literal key and its `\/` form.
- **The user agent.** Every request of every endpoint sends `User-Agent: helyx/<version>`, with the version of the `:helyx` application. Req's default `req/<version>` is gone. The test seam `:openai_req_options` comes after the options of the engine, so it can still replace the user agent and the `auth`, as it can replace every option (`docs/features/coding-agent.md`). `Authorization` and `User-Agent` are reserved for the engine: an endpoint header with one of these names fails the compile, in any case of the letters. The OpenCode Go docs ask for a client's own user agent (the ticket's first comment).
- **Model info.** `Helyx.ModelInfo.lookup/4` takes the catalog id next to the ref prefix: `lookup(provider_id, catalog_id, model)`. The config entry is still keyed by the ref `<id>/<model>`. A catalog id of nil gives no catalog step, and an endpoint cannot name an id that the catalog does not keep: the compile fails, so a typo does not leave the prices unknown with no sign. So a model with no config entry and no catalog entry has an unknown window and unknown prices, and the call does not fail. A bad config entry still fails the call with its key. The catalog keeps the ids `anthropic`, `openai`, and `opencode-go`; `claude-code` passes `anthropic`, `codex` passes `openai`, and `Go` passes `opencode-go`. The bundled snapshot holds these three ids.
- **A removed prefix.** A saved session or a `--model` that names `opencode/<model>` gets the existing `{:error, {:unknown_provider, "opencode"}}`. Nothing migrates the ref.
- **Retries and waits** (#479) are the same for every endpoint. No endpoint is known to need other values.

`Helyx.Provider.OpenAI.Go`: `id: "opencode-go"`, `base_url: "https://opencode.ai/zen/go/v1"`, `key_env: "OPENCODE_API_KEY"`, `headers: [{"x-opencode-session", :session_id}]`, `catalog: "opencode-go"`. The docs now also list `https://opencode.ai/inference/go/openai/v1`. The old path answers today (`GET .../models` gave 200 on 2026-10-17), so a change of the URL is a follow-up when the old path stops.

## Replaced mechanism

1. The two nested modules `Go` and `Zen`, each with a hard-coded id and base URL, become endpoint modules with `use`. `Zen` is deleted (decision 7). The module attribute `@env_var` and the function `session_header/1` become the `key_env` and `headers` options of `Go`. The `stream/5` of the engine becomes `stream/4` with the endpoint struct; it is `@doc false`, for the code that `use` makes. The provider-to-catalog map of `Helyx.ModelInfo.Catalog` becomes the catalog id that each provider passes; the `opencode` id is deleted with `Zen`. The retries, the waits, the chunk timeout, the error body cut, and the `:openai_req_options` seam do not change.
2. No reply is removed.
3. Tests: the tests of `openai_test.exs` that called `Zen` call `Go` or a test endpoint, with the same assertions on the wire. The route test checks `Go` and a test endpoint. The `opencode/glm-5` case of `footer_usage_test.exs` is deleted: it had the same path as `opencode-go`. The snapshot test of `catalog_test.exs` checks three ids. The `lookup` calls of the catalog and model info tests pass the catalog id.
4. A user sees: `opencode/<model>` is an unknown provider; requests carry the Helyx user agent; an error that echoes the key shows `*` in its place; a key outside the bearer token syntax fails with `{:bad_env, name}`; before, a key with a byte that no header can hold failed with an error from the HTTP client that held the key.
5. No state without a bound is added.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| endpoint headers | at most 16 | the compile fails |
| endpoint header name | 1 to 256 bytes of HTTP token characters; not `authorization` or `user-agent` in any case | the compile fails |
| endpoint header value | a string of 0 to 4,096 bytes of printable ASCII, space, or tab; or `:session_id` | the compile fails |
| `key_env` | nil, or 1 to 256 bytes: a letter or `_`, then letters, digits, or `_` | the compile fails |
| `catalog` | nil, or one of `Helyx.ModelInfo.Catalog.ids/0` (`anthropic`, `openai`, `opencode-go`) | the compile fails |
| the API key | 1 to 4,096 bytes of `b64token`: letters, digits, `-._~+/`, then any `=` | `{:error, {:bad_env, name}}` before any request; the empty string is `{:missing_env, name}` |
| HTTP error body | 16,384 bytes, as before. The drain reads up to the bound plus twice the key size (the longest form of the key), so a key that starts inside the bound is whole when it is masked. The mask keeps every position, so a part of the key at the end of the read stays past the cut, and the bound holds on the text that the turn error carries | cut to valid UTF-8 and marked `[truncated at the N-byte limit]` |

The other bounds of the engine (the SSE line, the tool calls, the chunk wait, the retries, the server delay) are in `docs/features/coding-agent.md` and do not change.

## Ownership

No new resource. The HTTP request and its async body keep their owner: the model Task of `Helyx.Provider.Loop` (`docs/features/coding-agent.md`).

## Out of scope

- Other wire formats: the Responses API and the Anthropic Messages API. Each one is its own engine.
- An endpoint added at run time, and modules made from config.
- `/models` discovery (#550 had it as a design question).
- The harness providers: #651.
- The new OpenCode Go URL: a follow-up when the old path stops.
