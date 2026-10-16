# Server delay headers of a retry

Date: 2026-10-16. Sources: the OpenAI Python SDK at revision `230a923faba5574ebdc5b45a505a26b6bad79f61`, and RFC 9110. Ticket #479.

## The OpenAI Python SDK

`src/openai/_base_client.py`, lines 811-848, `_parse_retry_after_header`:

- It reads `retry-after-ms` first. The value is in milliseconds.
- Then it reads `retry-after` as a number of seconds.
- The SDK parses both values with `float`, so it accepts a fraction. A value that does not parse goes to the next form.
- Last, it reads `retry-after` as an HTTP date with `email.utils.parsedate_tz`. The delay is the date less the current time.

## RFC 9110

Section 10.2.3 defines `Retry-After` as an HTTP date or a delay in seconds.

## Limit of this evidence

These facts show that an official client supports the three forms. No run shows that OpenCode Go or OpenCode Zen sent each form.
