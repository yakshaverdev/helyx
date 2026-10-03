# Review: a predicate rejects a long integer in tool arguments (#435)

Date: 2026-10-04. Base: `origin/master` (`249ffc2`). Scope: `lib/helyx/session/stream.ex`, `lib/helyx/data/message.ex`, `docs/features/coding-agent.md`, `docs/features/session-stream.md`.

## Invariant

At the stream boundary, `Helyx.Session.Stream.check/1` finds an integer of more than 100 digits at any depth of tool call or tool request arguments with `Helyx.Message.big_integer?/1` before any JSON encode, and the call goes on with arguments `%{}` and its rejection reason; a `done` or `message_end` usage with such an integer is a malformed stream event that fails the turn through the generic path. Error reasons, Task exit reasons, and the resume path of the session file keep `Helyx.Message.cap_integers/1`. Accepted holes, stated in the feature doc: a provider that raises or exits with such an integer, and an integer over the BEAM size limit at the JSON decode of a provider.

## Line counts

| File | Before | After |
|----|----|----|
| `session/stream.ex` | 237 | 234 |
| `data/message.ex` | 231 | 245 |

## Round 1 (full)

Bounds sensor:

```text
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

Simplify (4 agents): fixed the `cap_integers/1` doc, which still named `value == cap_integers(value)` as the test; put the accepted holes back in the feature doc row in one sentence. Not taken: the resume codec to `%{}` and to a failure (the ticket keeps the resume validation); one walker for both functions (they return different things); the encode measurements in the row (the ticket says measurements and history go).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 8 judgement calls | 0 | Fixed: `usage?/1` renamed `valid_usage?/1`; the new struct in `tool_call/1` named `checked`, not `call` again; the `wide_usage` model moved after the group of `refuse_int`. Not taken: the measurements (ticket); one walker (above); the resume codec (ticket); the mixed names "wide" and "large" in old tests (outside the diff). |
| Spec | 2 partial, 0 wrong | 0 | Fixed: the tool request test uses `10 ** 100` (101 digits); `message_test.exs` tests `big_integer?/1` on a key, a tuple, an improper list, and a struct; `session-stream.md` lines 42 and 69 name the predicate and the new result; the row says again that a struct is malformed. |
| Failure path | 0 | 0 | Limits at, one under, and one over 100 digits, negative values, keys, tuples, improper lists, struct fields, multibyte keys; usage in `done` and `message_end`; predicate and cap agree on 12 values; 100,000 integers of 100 digits checked in 76 ms. Not reached: a real gateway that sends such a usage; the plugin tests (run in precommit). |
| Codex adversarial | 0 | 0 | Verdict approve. |

No reproduced defect, so the loop ends.
