# 2026-10-18: every provider error with a text shows the provider id and the text (#760)

## Done

- `Helyx.HarnessIO.Error` is now `Helyx.ProviderError`. It owns the 2,000-byte text bound and the cut. Every bundled provider error with a text of the program or the server uses it: the harness turn error result, every Codex error answer to a request (`failure/2`), the Claude Code error answer to `initialize` or to an interrupt, a failed compaction, `HarnessIO.no_history/1`, the OpenAI HTTP error body, and the `message` of an `api_error` object.
- `Helyx.Reason.crash/1` unwraps an exception under an atom tag and in Core's `{:provider_error, kind, reason}`, so a provider stop shows the message too.
- The OpenAI error body is read to the 2,000-byte bound. Each invalid sequence becomes U+FFFD before the key mask, and the cut comes after the mask.

## What broke

- Round 1: the UTF-8 repair in the cut joined a key that an invalid byte split after the mask. Round 2: dropping invalid bytes before the mask moved a key part from past the read under the cut. The fix: no step between the read and the cut makes the body shorter.
- A large `api_error` object as `kind` took the walk budget of `Helyx.Reason`, and the message was lost.
- A first wide unwrap of any `{atom, atom, reason}` hid `{:failed_to_start_child, :child, crash}`.

## Assumptions (owner away)

- The neutral name `Helyx.ProviderError`, as a bundled helper next to `Helyx.Watchdog`: Core stays the same size, and one module serves all providers.
- `HarnessIO.no_history/1` became an exception too, although its text is Helyx's: the user story asks for the provider id on every error with a text.
- The OpenAI HTTP status stays out of the user text, as the status of a Codex result does.
- `{:not_started, text}` and a string `api_error` keep their terms.

## Next

- Round 3 left one open finding: a key that is a part of the field name `message` makes an `api_error` keep its term (`docs/reviews/2026-10-18-760-provider-errors.md`).
- #756: the log of a failed turn still holds the error text.
