# 2026-10-17: #652, one OpenAI-compatible engine

## Done

- `Helyx.Provider.OpenAI` names no vendor. An endpoint is a module with `use Helyx.Provider.OpenAI, id:, base_url:, key_env:, headers:, catalog:`, checked when it compiles (`Helyx.Provider.OpenAI.Endpoint`). `Helyx.Provider.OpenAI.Go` is the one bundled endpoint. Zen and the `opencode` catalog id are removed; the snapshot holds three ids.
- Every request sends `User-Agent: helyx/<version>`. `key_env: nil` sends no `Authorization`, also against Req's `:default_options`.
- `Helyx.ModelInfo.lookup/4` takes the catalog id from the provider.
- The key: unset or empty is `{:missing_env, name}`; a key outside the RFC 6750 `b64token`, or over 4,096 bytes, is `{:bad_env, name}`. Every event of the engine gets a same-length `*` mask of the key and of its `\/` form.
- Feature doc `docs/features/openai-compatible.md`; review record `docs/reviews/2026-10-17-652-openai-compatible.md`.

## What broke

Three review rounds each found a new path for the key into an error text: a shorter replacement that moved a cut key into the text, the SSE errors and a rejected delta, the JSON escapes. The mechanism moved from "replace in the HTTP error body" to "mask every event at one place". Round 3 found the `\uXXXX` escape, the mixed slash escape, and a charlist of the key. The orchestrator made them accepted holes, with an overlapping copy of the key (finding 24): no real provider is shown to echo a key in these forms. The small-fix round added the tests and comments of 16 to 20.

## Assumptions (owner away)

- An empty key is `{:missing_env, name}`: a variable set to the empty string means no key.
- A key outside the bearer token syntax is a new error, `{:bad_env, name}`: such a key cannot be sent as a bearer token, and before, it failed in the HTTP client with the key in the error.
- The `catalog` option is a closed list (`Catalog.ids/0`): the catalog keeps only these ids, so another id would give unknown prices with no sign. A product that needs another catalog id needs a Helyx change, or a config entry in `:models`.
- The user agent uses the version of the `:helyx` application at each request.
- An overlapping copy of the key (finding 24) is an accepted hole, by the rule that the orchestrator gave for 15: a constructed input, with no real provider that sends it.
- The bounds of the endpoint headers (16 headers, a name of 256 bytes, a value of 4,096 bytes) are a choice: decision 4 asks for a bound and names no number.

## Next

- The new Go URL, when the old path stops.
