# Rejected tool call

Replaced by #380. The `{:rejected_tool_call, call, reason}` event of #146 no longer exists.

## Goal

One tool call whose arguments do not decode does not fail the turn. The call joins the assistant message, gets an error result, and the text and the other calls of the message stay, so the model can correct the call. Issue #146, finding D4 of `docs/reviews/2026-09-26-boundary-review.md`.

## The rule since #380

- A provider whose model gave arguments that do not decode to a JSON object sends a normal `{:tool_call, call}` whose `arguments` is the raw argument text, a binary (`Helyx.Provider`). The same holds for `{:tool_request, id, name, arguments}`.
- `Helyx.Session.Stream.check/1` gives such a call `%{}` as arguments and the rejection reason `the arguments are not a valid JSON object`, next to the reason of an integer over the digit limit. Arguments that are neither a map nor a binary stay a malformed event.
- The session answers the request with `tool call not run: the arguments are not a valid JSON object` (`Helyx.Session.Server.ToolRuns`), and the call never runs.
- `Helyx.Provider.OpenAI` sends the raw text of each call whose arguments are not a JSON object. A call with no id still fails the turn at the Core boundary (#345).

## Bounds

| What | Bound | Where enforced |
| --- | --- | --- |
| raw argument text | the provider's own limit: 10 MiB of tool call bytes for OpenAI | the provider |
| raw text after the check | dropped in the provider process: the transcript, the session file, and the tool result hold `%{}`, and so do Core's error for a malformed call or request and the helper's error for a repeated call id. An error that holds a provider value as sent, such as an OpenAI `bad_chunk`, can hold it within the provider's limits | `Helyx.Session.Stream`; `Helyx.Provider.Loop` |
| result text of this rejection | `tool call not run: the arguments are not a valid JSON object`, 60 bytes | `Helyx.Session.Stream` |
