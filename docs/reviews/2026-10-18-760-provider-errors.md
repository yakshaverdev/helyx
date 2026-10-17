# Review: every provider error with a text shows the provider id and the text (#760)

Scope: the working tree against `HEAD` (`dcca6b86`), the branch point. `origin/master` moved ahead during the work (#766), so a diff against it shows that merge in reverse; the reviewers and Codex took the change as `git diff HEAD` (`--base HEAD`). Feature docs: `docs/features/session-lifecycle.md` ("Turn end", step 5), `long-lived-harness.md` ("Errors"), `openai-compatible.md` and `coding-agent.md` (bounds tables), `harness-compaction.md`, `provider-parity.md`.

Invariant: every bundled provider error that holds a text of the program or the server is a `Helyx.ProviderError` whose message is `<provider id>: <text>`, the text valid UTF-8 of at most 2,000 bytes, and the user reads that message on every path: a turn error, a stop under `:provider_stop` or `:provider_init`, and Core's stop tuple `{:provider_error, kind, reason}` (`Helyx.Reason.crash/1`). The OpenAI key never reaches that text. An error with no text keeps its term.

## Decisions

- `Helyx.HarnessIO.Error` becomes `Helyx.ProviderError`, a bundled helper with no harness name, because the OpenAI path uses it too. It owns the text bound (`max_text_bytes/0`, the 2,000 bytes of `Helyx.Watchdog`) and the cut (`cap/1`); `HarnessIO.cap_error/1` is gone.
- `reason/4` takes the term for no text, so every path keeps its old no-text term (`{:initialize, ""}`, `{:codex, method, ""}`, `{:http_status, status, ""}`).
- Core: `Helyx.Reason.crash/1` unwraps an exception as it unwraps a crash, and also Core's own `{:provider_error, kind, reason}`. Without it the stop at an error answer, the path of a Codex `turn/start` refusal, showed the inspected tuple (round 1).
- OpenAI: the HTTP error body is read to the text bound, not 16,384 bytes, and has no `[truncated …]` mark: the exception cut holds 2,000 bytes and has no mark on the harness paths.
- #756 check: the log line of a failed turn and the user text come from one reason, as before. The reason holds the same text as the tuple did; an OpenAI body is now at most 2,000 bytes, and the log keeps its cap of 160 characters for each string. This change adds no message text to the log. #756 stays open.

## Simplify

| Round | Finding | Resolution |
| ----- | ------- | ---------- |
| 1 | The OpenAI body bound repeats the 2,000 of the exception | Fixed: `ProviderError.max_text_bytes/0` |
| 1 | `drain/2` masks and cuts, and the event map masks and the exception cuts again | Fixed: `drain/2` only reads |
| 1 | Two `Stream.map` stages for each event | Fixed: one stage masks and converts |
| 1 | A private `error/3` wrapper in `turn.ex` | Fixed: inlined |
| 2 | Double cut of `compact_error`; a `reason/3` overload; `{:provider_error, {kind, reason}}` | Skipped: the first cut bounds state; judgement calls |
| 3 | The test bound repeats 2,000; `replace_invalid` copies a valid body | Skipped: the test fixes the stated value; about 2 KB on an error |

## Round 1 (full)

Bounds sensor (`--diff HEAD`): `bounds sensor: 6 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path, Codex | With key `test-key`, the body `"bad test" <> <<255>> <> "-key"` gave the text `bad test-key`: the cut dropped the byte after the mask | Fixed: the body is repaired before the mask (round 2 changed how) |
| Spec | A Codex `turn/start` refusal reached the user as `{:provider_error, :turn, %Helyx.ProviderError{...}}` | Fixed: `crash/1` unwraps that tuple; test `provider_process_test.exs`, "an error answer with an exception" |
| Codex | `stream_events_test.exs` expected the inspected `{:task_exit, exception}` | Fixed: the fixture message shows its stack field, so the test still proves the clean: `held :stacktrace` |
| Spec | An `api_error` lost its other fields; a string `api_error` kept its term | Fixed in round 1, reverted in round 2 (see there) |
| Standards | A doc row named the deleted `@max_error_body_bytes`; a comment on the wrong function; the middle man `HarnessIO.cap_error/1`; a history note in a bounds table; untested no-text terms | Fixed; tests for `{:initialize, ""}`, `unexpected response`, `{:codex, "turn/start", ""}`, `{:http_status, 401, ""}` |
| Spec | An exception under any atom tag loses the tag | Accepted: the rule of a crash; the doc states it |

A first wider clause (`{tag, kind, reason}` with two atoms) also unwrapped `{:failed_to_start_child, :child, crash}` and broke `provider_process_test.exs:338`; it was narrowed to `{:provider_error, kind, reason}` before round 2.

## Round 2 (full: four code files)

Bounds sensor: `bounds sensor: 6 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Failure path, spec, Codex | Key of 100 bytes; a chunk of 1,200 invalid bytes, 1,002 `a` and 99 key bytes, then `Z`: the text held 99 key bytes, because the dropped bytes moved the part past the read under the cut | Fixed, second finding on one mechanism, so the mechanism changed: each invalid sequence becomes U+FFFD, never shorter, so no byte moves back. Test "invalid bytes before a part of the key at the end of the read move nothing back" |
| Codex | An `api_error` with a `details` list of 10,001 items as `kind` took the walk budget, and the text was `Helyx.ProviderError` | Fixed: `kind: :api_error`, no other field. Test "an api_error with a large object keeps its message" |
| Standards | The string `api_error` clause has no evidence of a real gateway | Fixed: removed; a string keeps its term |
| Standards, spec | `{:interrupt, ""}`, `{:compaction_failed, ""}` and a crash in `{:provider_error, …}` untested; a sentence order in step 5 | Fixed: tests and the sentence |

## Round 3 (full: the second finding on one mechanism)

Bounds sensor: `bounds sensor: 7 candidate functions, 0 flagged, 0 without an answer`. Failure path: no reproduced finding (fuzz of 800 bodies and 600 `api_error` objects). Standards: no hard violation.

| Axis | Finding | Resolution |
| ---- | ------- | ---------- |
| Codex | A key that is a part of the field name `message` (such as `age`) masks the name, so the lookup misses and the `api_error` keeps its term, which is not cut at 2,000 bytes | **Open.** The fix (take the message before the mask, then mask it, then cut) changes the arity of `text_error/2` and is a further finding on the mask, so it does not meet the small-fix round. No key reaches a text: the term is masked, as on `HEAD`. |
| Spec | Step 5 and "Errors" said every Codex error answer is the exception; a `thread/resume` error keeps `{:malformed, "thread/resume"}` | Fixed: the doc names `failure/2` and the exception |
| Spec | No test of an `api_error` message over 2,000 bytes | Fixed: test "an api_error message is cut at 2,000 bytes, after the mask" |
| Spec | An exception under `:bad_stream_event` or `:bad_return` shows its message, not the tag | Accepted: the generic failure path still fires (the provider stops, the turn fails); a crash under those tags lost its tag before too |
| Standards | Long sentences and a phrasal verb in step 5; the expansion of the repair has no stated bound; the `empty` term repeats the kind | Fixed the verb and the bound (at most three times the read); the rest are judgement calls |

## Precommit

The first run failed on Credo: `claude_code.ex` had 509 lines, more than the 507 in `.credo.exs`, and the `Helyx.ProviderError` alias in `openai.ex` was out of order. The answer to `initialize` became an `if` on the subtype (the same test, two lines less), and the alias moved. The second run passed: `732 tests, 0 failures`, `80 tests, 0 failures`, `2 properties, 892 tests, 0 failures (1 excluded)`, Credo `found no issues`, Dialyzer `Total errors: 0` in each project.

## Accepted holes

- `{:not_started, text}`, the watchdog text of a program that did not start, keeps its term: it is no error answer of the program, and `HarnessIO` has no provider id there.
- A string `api_error` keeps its term: no evidence that a real gateway sends one.
- The HTTP status and the subtype or status of a result are in the reason for the log only.
- The log line of a failed turn still holds the error text (#756).
- The open finding of round 3.
