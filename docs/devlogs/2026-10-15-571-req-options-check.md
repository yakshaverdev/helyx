# 2026-10-15: #571, `:openai_req_options` checked at the start of each model call

## Done

- `Helyx.Provider.OpenAI.stream/5` checks the `:openai_req_options` env after the `Helyx.ModelInfo` lookup and before the API key. A value that is not a keyword list fails the call with `{:error, {:bad_config, [:openai_req_options]}}`. A keyword list goes to Req unchanged.
- The owner decided in the triage that each plugin checks its own key at start. The three keys of `helyx_plugins` and their checks are in the review record (`docs/reviews/2026-10-15-571-req-options-check.md`).
- A row in "Bounds" of `docs/features/coding-agent.md`.

## What broke

- Rounds 1 and 2 checked the option names against Req's option set. Req accepts names outside it (`headers`, then `plugins`). Round 3 removed the name check: the names and the values are Req's to check, as for the `req_options` of `:model_catalog`.
- One early probe sent two real requests to the OpenCode gateway with a fake API key, because its bad env values had no plug. Later probes used a Req plug.

## Next

- Nothing for #571. A bad Req option name or value still fails in the model call with Req's error (accepted, as in #560).
