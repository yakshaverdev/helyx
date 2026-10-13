# Review: #560 The models.dev catalog

Invariant: `Helyx.ModelInfo.lookup/3` takes the window and the price set of a model from config, else from the models.dev catalog (`Helyx.ModelInfo.Catalog.lookup/2`), else nothing, each value whole from one source. The catalog data is the output of `slim/1`, which checks each window against the wire bound and each price set with the config check. It lives in `:persistent_term`, loaded at the first lookup of a node from the cache file (at most 16 MB), else the bundled snapshot. A lookup never waits on the refresh. The refresh runs in one unlinked registered process, at most once in 24 hours for each cache directory (the marker is touched before the fetch). It fetches in a linked Task under a 60 s deadline, with a 16 MB body cap counted per chunk and `If-None-Match`. Any failure keeps the last good copy. A 200 goes to a temporary file and a rename.

Accepted (feature doc): two nodes on one directory can both fetch in the same second; the node that does not refresh keeps the data that it loaded at its start; the temporary file of a crashed refresh stays on disk.

## Round 1 (full)

Simplify, four agents. Fixed: `slim/1` checks a price set with the config check of `ModelInfo` (`check_prices/1`), so the price rule exists once; `slim/1` gives the lookup form, and `json/1` gives the `api.json` shape for the disk, so a lookup does no conversion; the lookup returns at once for a provider with no catalog id; the body cap keeps a running byte count; test helpers (`new_node/1`, `@newer` from `@good`). Skipped: the marker `stat` on each lookup (microseconds); a process spawn on each lookup when the cache directory cannot be written (no fetch follows, because the touch fails); a test env with no catalog (the two provider tests use a model in no catalog, or assert the tokens only).

Bounds sensor (after simplify):

```
bounds sensor: 10 candidate functions, 3 flagged, 0 without an answer
  plugins/bundled/lib/helyx/model_info/catalog.ex:52  SIZE  def lookup(provider_id, model) do
  plugins/bundled/lib/helyx/model_info/catalog.ex:190  SIZE  defp snapshot,
  plugins/bundled/lib/helyx/model_info/catalog.ex:242  SIZE  defp fetch(config, etag) do
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex, failure path | **A first load could put the old cache over the data of a later refresh.** Reproduced by the failure path: a lookup suspended in the decode of the cache file, a refresh that ended, then the resumed lookup put the old data back until the next day | Fixed: the first load (the read and the put) and the put of a refresh take one `:global` lock of the directory. Test: "the first load and the write of a refresh take one lock". The test found that the first lock id named the directory as the requester, so it excluded nothing; the id is now `{{Catalog, dir}, self()}` |
| 1.2 | failure path | **A non-UTF-8 ETag crashed the refresh** in the JSON encode of the cache file, so every daily refresh failed while the server sent it | Fixed: one rule at the fetch and at the read of the cache file. An ETag is kept only as 1 to 256 bytes of printable ASCII, else nil. Test: "an ETag that is not 1 to 256 bytes of printable ASCII is not kept" (a byte 0xFF, a multibyte character, 257 bytes, empty, and a newline in the cache file) |
| 1.3 | standards, spec | "Helyx asks for no compression" had no test | Fixed: the 200 test asserts no `accept-encoding` header |
| 1.4 | spec | A marker exactly 24 hours old started a fetch; the doc says "older than" | Fixed: `>`. The tests check 24 h − 60 s and 24 h + 1 s |
| 1.5 | spec | "One refresh process for each node" had no test | Fixed: a test holds the registered name and sees no fetch |
| 1.6 | spec | The id bound had no multibyte case | Fixed: 128 × "é" (256 bytes) kept, 129 dropped |
| 1.7 | spec | The research note listed four `openai` models with context 0 (there are five) and named only `openai` for `context_over_200k` | Fixed |
| 1.8 | spec | The feature doc gave "about 10^6" as the largest window; the shape row said "a positive integer `size`" | Fixed: 1,050,000 in the four ids, with the note; a size from 1 to 10^9 |
| 1.9 | standards | The choice to leave out `context_over_200k` was in the research note | Fixed: in the feature doc |
| 1.10 | standards | Bare maps for the entry (`@none`, `@type entry`) | Fixed: `%Helyx.ModelInfo{}`. The `%{etag, data}` map stays inside the module |
| 1.11 | standards | `entry_key(:prices, ...)` repeated `check_prices/1`; `@ids` | Fixed: `entry_key` calls `check_prices/1`; `@catalog_ids` |
| 1.12 | standards | Long sentences in the feature doc and the devlog | Fixed |
| 1.13 | spec | "Each value is dropped alone" is wider than "a bad entry is dropped" | Kept: the ticket row itself drops the window alone (a value above 10^9) and the price set alone (a tier of another type); AGENTS.md, "Reject the smallest unit" |
| 1.14 | spec | `fetch_ms` is a fourth env key | Kept: the deadline test needs it; the feature doc names it |
| 1.15 | spec | Under the whole-fetch deadline, and the 30 s `receive_timeout`, have probes only | Kept: every refresh test runs under the deadline; Req.Test cannot show the receive timeout |
| 1.16 | standards | `@price_keys` repeats `@counts` of `ModelInfo` | Kept: the catalog maps the JSON names to the atoms |

Round 1 reproduced defects (1.1, 1.2). The fix changed 73 code lines in `catalog.ex` and one in `model_info.ex`, and added functions, so round 2 is full.

## Round 2 (full)

Simplify: the write of a refresh took the lock for no reason. `run/1` loads before its fetch, so the entry is set before the write, and no first load can put after it. The write now calls `put/2` with no lock, and the second half of the lock test went with it. The ETag bound is its own attribute, `@max_etag_bytes`.

Bounds sensor (base `origin/master`; this ticket has no earlier commit):

```
bounds sensor: 10 candidate functions, 2 flagged, 0 without an answer
  plugins/bundled/lib/helyx/model_info/catalog.ex:47  SIZE  def lookup(provider_id, model) do
  plugins/bundled/lib/helyx/model_info/catalog.ex:199  SIZE  defp snapshot,
```

Both flags are false: `lookup/2` reads through `read/1`, which reads at most 16 MB + 1 byte; `snapshot/0` reads the bundled file of this repository.

Codex adversarial: approve, no material finding. It probed the ETag and JSON decode cases.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | failure path | **A marker with an mtime in the future stopped every refresh** until the clock reached it (a clock set back, a restored directory). Reproduced: a marker 30 days ahead gave no fetch | Fixed: the age is `abs(now - mtime)`, so a marker more than a day away in either direction is stale. Test: the marker test touches it a day and a minute ahead and sees a fetch. The mutant without `abs` fails it |
| 2.2 | spec | **The cache file could pass 16 MB**, though the doc states the cap: the encode of the slim data can be longer than the body (`1e5` encodes as `1.0e5`). The next node then rejects the file. Reproduced by a probe of the encode growth; real data is 26 KB for the four ids | Fixed: an encode over 16 MB is not written, and the node keeps its last good copy. No test: the case needs a 16 MB body |
| 2.3 | failure path | `req_options` came after the catalog options, so config could replace `into:` (the body cap), `retry:`, and `receive_timeout:`. Reproduced with `Req.new/1` | Fixed: the catalog options come last. The tests still pass their plug through `req_options` |
| 2.4 | failure path | The lock test passed with the re-check under the lock removed | Fixed: the test puts data while the load waits and asserts the load keeps it. The mutant fails it |
| 2.5 | standards, failure path | The feature doc and the devlog said that the write takes the lock | Fixed |
| 2.6 | standards | The `@load_ms` comment named only a fetch | Fixed |
| 2.7 | spec | `:global.trans` retries with a backoff of up to 8 s, so two first lookups at one time can wait that long for each other | Kept, and stated in the feature doc: it is not a wait on a refresh |
| 2.8 | failure path | **The `:model_catalog` app env is not checked**: a bad value raises in `ModelInfo.lookup/3`. Reproduced | Open: `:openai_req_options` is not checked either. A check of every app env key of `helyx_plugins` needs a decision (devlog, Open) |
| 2.9 | spec | The Codex turn test asserts only the tokens | Kept: the catalog tests cover the catalog values |

Round 2 reproduced defects (2.1 to 2.4, 2.8). The fix changed about 15 code lines in `catalog.ex`, under 100, with no new function, so round 3 is reduced.

## Round 3 (reduced, the last round)

Codex adversarial on the five round 2 fixes: approve, no material finding. A Req probe confirmed that the catalog options win over `req_options`.

Round 3 reproduced no defect, so the loop ends. Open: 2.8.

## Round 4 (reduced, an exception to the round limit that the owner approved)

The owner decided on finding 2.8: fix it in this ticket. The `:model_catalog` env gets the start check of a `:models` entry. A bad value fails each lookup with `{:error, {:bad_config, [:model_catalog, key]}}`, so the provider start fails with the key. `:openai_req_options` goes to its own ticket. The owner approved one more reduced round (spec and failure path) over the round limit of `/ship`.

The fix: `Catalog.lookup/2` returns `{:ok, info}` or the error, and checks the env with `ModelInfo.check/3` (now `@doc false` public) at every lookup, also for a provider with no catalog id. One rule over all bad shapes: a keyword list of the four known keys, each value in its stated bound, else the path of the first bad key. Test: "a bad :model_catalog value fails each lookup with its key".

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 4.1 | failure path | **A `url` with a byte that is not UTF-8 makes `lookup/3` raise.** `URI.new/1` raises `FunctionClauseError` from `:uri_string` on such a binary, in `http?/1`. Reproduced: `"https://models.dev/api\xFF.json"` | Open, by the owner's rule for this round: report, do not fix. One rule fixes it: `http?/1` rescues the parser exception by name and gives false; the test adds a `url` with byte 255 |
| 4.2 | spec, failure path | The test comment "the last `url` wins" is false: `check/3` reverses the keys, so the first duplicate key wins. The test stays off the network only because "fake" has no catalog id | Open, by the same rule. Fix: the comment says that "fake" has no catalog id. Real config has no duplicate keys, because `Config` merges keyword lists |
| 4.3 | spec | `req_options` is checked only as a keyword list; an unknown Req option crashes the refresh process, not the lookup | Kept: the docs say "a keyword list", and the old code did the same |
| 4.4 | spec | The module comment still says "`fetch_ms` for tests" | Open, by the same rule: one word |

The check form matches the `:models` check (one rule, the same error shape, the same `with` in `ModelInfo.lookup/3`). Round 4 reproduced one defect (4.1). It is not fixed in this commit.

## The fix of 4.1, 4.2 and 4.4

The owner decided to fix 4.1, 4.2 and 4.4 now, with no further review round. The owner approved the fix with the Codex gate of the orchestrator as its review. 4.3 stays kept.

- 4.1: the `url` rule accepts only a valid UTF-8 string (`String.valid?/1` before `URI.new/1`), as part of the one `url` rule. The test adds `"https://x/" <> <<255>>`. The mutant without `String.valid?/1` fails the test.
- 4.2: the test comment says that no refresh starts because "fake" has no catalog id.
- 4.4: the module comment calls `fetch_ms` the whole-fetch deadline.
