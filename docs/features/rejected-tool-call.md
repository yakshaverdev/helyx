# Rejected tool call

Replaced by #636. The `{:rejected_tool_call, call, reason}` event of #146 and the same-turn error result of #380 no longer exist.

## The rule since #636

- The arguments of a tool call or a Helyx tool request are a plain map. Other arguments are a malformed event, and the turn fails through the generic path (`{:bad_stream_event, event}`, `Helyx.Session.Stream.check/1`). The user can send the prompt again.
- A provider whose model gave arguments that do not decode to a JSON object can send them as their raw text, a binary. `Helyx.Provider.OpenAI` does. The error of such a call holds `%{}` in place of the text, so no transcript entry, session file entry, log line, or client event holds it.
- Removed capability: before #636, such a call got an error result and the turn continued, so the model could correct the call. No observed run showed a model that sends arguments that are not a JSON object.
- An integer over the digit limit is still found before the first JSON encode (#79). That call goes on with `%{}`, and the session answers it with `tool call not run: an integer in the arguments has more than 100 digits` (`Helyx.Session.Server.ToolRuns`).

## Bounds

| What | Bound | Where enforced |
| --- | --- | --- |
| raw argument text | the provider's own limit: 10 MiB of tool call bytes for OpenAI | the provider |
| raw text after the check | dropped in the provider process: Core's error for a malformed call or request and the helper's error for a repeated call id hold `%{}`. An error that holds a provider value as sent, such as an OpenAI `bad_chunk`, can hold it within the provider's limits | `Helyx.Session.Stream`; `Helyx.Provider.Loop` |
