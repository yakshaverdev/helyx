# Review: #652, one OpenAI-compatible engine with endpoint modules

Feature doc: `docs/features/openai-compatible.md`.

## Round 1 (full: simplify, standards, spec, failure path, Codex)

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 11 candidate functions, 2 flagged, 0 without an answer
  plugins/bundled/lib/helyx/model_info/catalog.ex:59  SIZE  defp entry(id, model, config) do
  plugins/bundled/lib/helyx/provider/openai.ex:198  SIZE  defp post(req, key, retries) do
```

Simplify (4 agents) fixed: the `catalog` option is checked against `Catalog.ids/0` (3 agents: an id that the catalog does not keep gave unknown prices with no sign); the halt flag of `drain/2` is derived; the header value has two clauses; the test user agent is one helper; the one-item `for` of `footer_usage_test.exs` is inlined. Skipped: one shared `http?/1` with the catalog (the two URLs can get other rules); reading the key back from `req.options[:auth]` (the seam can replace it); a compile-time user agent (no cost to measure); moving the ref-prefix rule into Core (out of scope); dropping the header bounds (decision 4 asks for them).

| # | Axis | Finding | Reproduced | Resolution |
| - | ---- | ------- | ---------- | ---------- |
| 1 | Codex, spec, failure path | A key longer than `[redacted]` made the body shorter, so a part of a key at the end of the read moved inside the cut: 74 to 85 key bytes in the error text | yes, by all three, with a `Req.Test` plug | The mask is now `*` of the same length as the key, so every position stays, and a part of the key at the end of the read stays past the cut. Test: "a part of the key at the end of the read stays past the cut" |
| 2 | Codex, spec | A 200 SSE error object (`api_error`) or a `bad_chunk` payload carried the echoed key unchanged into the turn error | yes | Every `{:error, reason}` of the stream gets the mask in each string of the reason, map keys too. Test: "a key in an error of the stream after a 200 is masked" |
| 3 | Codex | `key_env: nil` sent a bearer key from Req's `:default_options` | yes | `auth: nil` replaces it. Test: "with no key_env, no auth of Req's default options is sent" |
| 4 | Failure path | A `base_url` with a query compiled, and the path went into the query | yes | A query or a fragment fails the compile. Test cases in "an endpoint option outside its bound fails with its name" |
| 5 | Standards | `claude_code.ex` and `codex.ex` grew by one line each against their `FileLength` entries | read | One wrapped comment joined in each file (round 2: the formatter put back the blank line of `codex.ex`, so a comment is joined there) |
| 6 | Standards | `Catalog.entry/3` had a clause for an id outside the list, which the compile check makes unreachable | read | Back to the `nil` clause |
| 7 | Standards | Stale `lookup/3` and `lookup/2` names | read | Fixed in `model_info.ex`, `model_info_test.exs`, `usage-and-limits.md` |
| 8 | Standards, spec | The doc said the key reaches no log and no session file with no test | read | The doc now states the guarantee on the returned error, which the turn error, the session file, and a log line come from, and says that Helyx writes no request log |
| 9 | Spec | The seam `:openai_req_options` can replace the user agent | probe | Accepted: it is the test seam that replaces every option (`coding-agent.md`); the doc says so |

Judgement calls not taken: an AGENTS.md line for a bundled module that a product adds with `use` (the engine has no id and is not a plugin; the feature doc names the pattern); a reason in the moduledoc of `Go` (removed).

## Round 2 (full: simplify, standards, spec, failure path, Codex)

Simplify (2 agents over the fix) found nothing to change. Skipped: a head-tail list walk for improper lists (no event or error holds one); a `Catalog.lookup(nil, _)` clause before the config check (the doc says that every lookup checks `:model_catalog`).

| # | Axis | Finding | Reproduced | Resolution |
| - | ---- | ------- | ---------- | ---------- |
| 10 | Spec, failure path | A key with `"` or `\` echoed in JSON came out escaped and not masked; PHP writes `/` as `\/` | yes | The key bound is now the RFC 6750 `b64token`, so JSON escapes only `/`, and the `\/` form is masked too. The drain reads twice the key size past the limit, the size of the longest form. Tests: the `:bad_env` cases, "a key that the server echoes in JSON with an escaped slash is masked", "an escaped key across the limit is whole when it is masked" (fails with a read of one key size) |
| 11 | Failure path | A key that ends in `*` came back from three copies after two mask passes | yes | A `b64token` has no `*`, so a mask cannot make a copy |
| 12 | Codex | A delta that is not a string, with the key in it, reached Core, and Core's `{:bad_stream_event, event}` held the key | yes | The second finding on one mechanism, so the mechanism changed: the mask now runs on every event of the engine, at the one place that all output passes, and walks struct fields too. Test: "a key in any event is masked, also in a delta that Core rejects" |
| 13 | Standards | `codex.ex` still had one line over its count: `mix format` put the blank line back | read | A two-line comment joined |
| 14 | Spec | The feature doc names `lookup/4` and shows a call with three arguments | read | Correct: the fourth is the config with a default |

Not reached by the budget, from the agents: a slow error body (`drain/2` waits up to 120 s for each chunk, as before this change); the `{:task_exit, _}` path.

Accepted holes: Req's own `Inspect` of a request keeps the first 3 characters of the key if a request struct shows in a raised error (`{:failed, _}` of `Helyx.Provider.Loop`); an `authorization` header in the `headers` of Req's `:default_options` is not removed (only `auth`); a key that a server splits over two text deltas is not masked (it is no error, and a server has no reason to send it).

## Round 3 (full: simplify, standards, spec, failure path, Codex)

Simplify (1 agent, four angles) fixed: one compiled `:binary` pattern for the two forms of the key, built once for the stream, in place of a list rebuilt for each string; one map clause for maps and structs. Kept: the joined comment of `codex.ex` (it holds the `FileLength` count).

| # | Axis | Finding | Reproduced | Resolution |
| - | ---- | ------- | ---------- | ---------- |
| 15 | Spec, failure path | JSON allows `\uXXXX` for any character; Gson writes `=` as `\u003d` and .NET writes `+` as `\u002B`. A key echoed that way in an HTTP error body or a `bad_chunk` payload is not masked, and the drain reads only twice the key size past the limit | yes, with a `Req.Test` plug (the encoder defaults are the agents' knowledge, not read in source) | **Open.** The third finding on the mask mechanism, in round 3, so the small-fix round does not apply. Code committed as reviewed in this round. The feature doc states the hole |
| 15b | Codex | A key with two slashes, of which the server escapes only one, is not masked; the pattern holds only the form with no slash escaped and the form with every slash escaped | yes (Codex, local plug) | **Open**, with 15: an escape-aware mask of JSON strings covers it |
| 15c | Codex | A JSON array of the character codes of the key (an `error` or a `delta.content`) passes the mask, because the walk sees each integer alone; `Helyx.Reason.text/1` prints the list as a charlist, so the turn error shows the key | yes (Codex, local plug) | **Open**: mask a printable integer list that holds the key, and keep the list shape |
| 16 | Spec | No test streams through an endpoint with `catalog:` and checks a catalog window or price | read | Open: a test-only follow-up |
| 17 | Spec | No test shows that `:openai_req_options` can replace the user agent | read | Open: a test-only follow-up; round 1 probed it |
| 18 | Standards | The comment "the longest match wins" above `mask/1` describes a case that cannot occur, and the comment above `key?/1` says that JSON escapes only `/` | read | Open: a comment fix with the follow-up; no code changed after this round |
| 19 | Standards | The feature doc says that the mask covers struct fields, with no test | read | Open: a test-only follow-up; the code walks a struct as a map |
| 20 | Standards | The moduledoc "each copy becomes `*`" can read as one `*` | read | Open: wording with the follow-up |

Proposed fix of 15 and 15b for the follow-up: mask a pattern in which each byte of the key matches itself or its `\u00hh` form in either hex case (and `\/` for `/`), and read six times the key size past the limit. A regex over a 4,096-byte key needs a check of the compile limit, and a compile error must not carry the key.
