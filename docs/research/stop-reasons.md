# Provider stop reasons for a filtered or refused answer

Research for ticket #539. Gathered on 2026-10-12. It records the wire values that tell a filtered or a refused answer apart from a normal end, for each bundled provider.

## OpenAI Chat Completions (`Helyx.Provider.OpenAI`)

Source: the OpenAI OpenAPI spec, `openapi.yaml` of `github.com/openai/openai-openapi`, branch `manual_spec`, commit `498c71ddf6f1c45b983f972ccabca795da211a3e` (2025-04-29), schemas `CreateChatCompletionResponse` and `CreateChatCompletionStreamResponse`, field `choices[].finish_reason`.

- The enum is `stop`, `length`, `tool_calls`, `content_filter`, `function_call` (deprecated). The stream chunk has the same enum and is nullable.
- The text: "`content_filter` if content was omitted due to a flag from our content filters".
- `length`: "the maximum number of tokens specified in the request was reached".

The provider calls the OpenCode Go and Zen gateways, which take the Chat Completions format. Whether a gateway sends `content_filter` from an upstream model was not observed.

## Claude Code (`Helyx.Provider.ClaudeCode`)

Source: the Claude Agent SDK docs, page `/en/agent-sdk/agent-loop` ("Handle the result"), read on 2026-10-12 through the Claude Code docs server.

- The `result` message has `stop_reason`, `string | null`, "indicating why the model stopped generating on its final turn".
- "Common values are `end_turn` (model finished normally), `max_tokens` (hit the output token limit), and `refusal` (the model declined the request)."
- "To detect refusals, check `stop_reason === "refusal"`."
- On an error result that the loop produced, `stop_reason` is the value of the last assistant response; a result made after a session crash has `null`.

The page `/en/monitoring-usage` lists the API response `stop_reason` values as `end_turn`, `tool_use`, `max_tokens`, `stop_sequence`, `pause_turn`, and `refusal`, and says that a refusal arrives on a successful response stream, not as an HTTP error.

A refusal was not observed in a run of `claude -p`.

## Codex (`Helyx.Provider.Codex`)

Not researched: out of scope for #539, which knows no wire value for it. Every Codex turn ends with `end_turn`.
