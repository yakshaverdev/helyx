# Review: a very large JSON integer in a frame closes with 1011 (#782)

Scope: the working tree against the branch base `b4efc8b1`. Files: `plugins/bundled/lib/helyx/transport/web_socket/frame.ex`, `plugins/bundled/test/helyx/transport/web_socket_test.exs`, `docs/features/wire-protocol.md`.

Invariant: a text that `Helyx.Transport.WebSocket.Frame.decode/2` gets, as one frame or joined from parts, never raises from its JSON decode. An integer over the largest integer of the BEAM gives the answer of bad JSON, close `4400`: the connection ends with its subscriptions, and no crash report is logged.

## Decision

The ticket says two things that do not hold together: an undecodable frame "gets the same answer as a frame that is not valid JSON", and "the connection stays open, and its subscriptions stay". The answer of bad JSON is close `4400`, and at each close the connection process ends with its writers (wire doc, "Close codes"; test "a close ends the connection process: a request after it in one packet does not run"). The change takes close `4400`. To keep the connection open, bad JSON would need a new answer: a frame with no request id, a schema change, and a new protocol number. That is a contract change, outside this ticket. The ticket's test, "the large integer, then a valid request on the same connection", is not possible under the decision. The test sends the integer at the bound, gets its reply on the same connection, and then sends the integer over the bound and gets close `4400`.

## Measurement

- Elixir 1.19.5 on OTP 28. `JSON.decode/3` catches `unexpected_end`, `invalid_byte`, and `unexpected_sequence`, and `:json` catches a float that `binary_to_float/1` refuses (`1e400` gives `unexpected_sequence`). The integer decoder, `binary_to_integer/1`, is not in a `try`, so an integer over the BEAM limit raises `SystemLimitError`. The spec reviewer ran 300,000 random token strings and the structural cases (nesting 100,000 deep, 1 MiB strings, bad UTF-8, lone surrogates, floats out of range): only a large integer raised.
- The largest integer is 2^4,194,240 − 1 (65,535 words of 64 bits, 1,262,593 digits): it decodes, and the next value raises. 1,262,592 nines decode, and 1,262,593 nines raise. One frame of 1 MiB cannot hold that many digits, so only a frame joined from parts reaches the raise. The ticket's "about 4 million digits" is about 4 million bits.
- Before the fix, the joined frame closed with `1011` and logged a crash report of 8,132 bytes with `SystemLimitError`. After it, close `4400`, and no log line (failure-path probe).

## Simplify

One agent. Applied: the test lost its `capture_log` and its request after the over-limit frame (the close code proves there was no crash, and a send to a closing socket can reset it before the client reads the close); the rescue comment is one line. Rejected: reuse of `Frame.encode/1` for the parts (a map cannot hold an integer over the limit).

## Round 1 (full)

Bounds sensor (`--diff b4efc8b1`):

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | approve, no material finding; one frame and joined parts give `4400`, positive, negative, and nested | none needed |
| Failure path | 1, doc: the bounds row said the largest integer is 1,262,592 digits and about 4,194,304 bits. Reproduced: 2^4,194,240 − 1 (1,262,593 digits) decodes, and `1` with 1,262,592 zeros decodes through a loopback socket | the row states the exact value and the digit rule that the test proves; probe in this record |
| Standards | 0 hard. Judgement calls: one limit had several names ("of the server" in the close-code row); the doc bound was a digit count, not a value; the test does not use the exact maximum; `send_parts/3` exposes `n` only for the recursion | close-code row says "a number out of the range of the BEAM"; bounds row fixed as above; the test keeps the nines (see below); `n` kept, the default is the start |
| Spec | the decision drops two ticket lines (see "Decision"); the bounds row was false (as the failure path found); `1e400` also closes with `4400` and the doc did not say so | decision recorded here and in the report; bounds row fixed; the row now names floats out of range |

The test keeps 1,262,592 and 1,262,593 nines: they prove the digit rule that the doc states for a client ("every integer of 1,262,592 digits or fewer decodes, and 1,262,593 nines do not"). The exact value 2^4,194,240 − 1 is a probe, run again after the doc fix: it decodes, the next value raises, and `1e400` does not decode.

No round reproduced a code defect, so the loop ended after round 1. The fixes are doc text only.

## Precommit

`HELYX_SLOW=1 .claude/skills/ship/precommit.sh` on the precommit host: passed on the first run. Root 758 tests, `apps/coding_agent` 82, `plugins/bundled` 1,043 tests and 4 properties (1 excluded), 0 failures; Credo found no issues; Dialyzer 0 errors in each project. The `plugins/bundled` test output has one line `erl_child_setup: failed with error 32 on line 284` (a broken pipe of a port child) with no failed test.

## Accepted holes

These are on master's decoder and not in this diff.

- CPU: an integer just under the limit takes 200 to 450 ms in `binary_to_integer/1`. One joined frame of 25 MiB holds 20 of them: 4.4 s of decode in the connection process (failure-path probe).
- Memory: nesting costs about 43 bytes for each level. 4 million levels in a 4 MB frame took 171 MB, so a 25 MiB frame of `[` would take about 1.1 GB (extrapolated, not measured).
- The same `SystemLimitError` at other `JSON.decode` callers outside the transport: `lib/helyx/session/file/reader.ex:33`, `lib/helyx/session/file/scan.ex:182` and `:203`, `plugins/bundled/lib/helyx/harness_io.ex:173`, `plugins/bundled/lib/helyx/provider/openai/events.ex:78`. The failure-path reviewer read that `Session.File.load/3` rescues every error and that the head of `Scan` is 64 KiB. The others were not probed.
