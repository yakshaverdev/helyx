# 2026-10-13: the models.dev catalog (#560)

## Done

- `Helyx.ModelInfo.Catalog` gives step 3 of the source rule. `ModelInfo.lookup/3` takes the window and the price set of the catalog when config has none, each whole from one source. The provider-to-catalog map moved into `Catalog`.
- `slim/1` makes the snapshot, checks each refresh, and checks the cache file. It checks the window and the price set of each entry alone. The price set gets the config check of `ModelInfo` (`check_prices/1`). A catalog id with no entry left is dropped, so `%{}` means no catalog. The output is the lookup form, `%Helyx.ModelInfo{}` entries, that `:persistent_term` holds. `json/1` gives the `api.json` shape for the disk.
- The refresh: a lookup spawns it when the marker is missing or 24 hours old. It registers its name, checks the marker again, touches it, and fetches in a Task under the 60 s deadline, with `If-None-Match`. The body cap counts the chunks. A 200 with a good catalog goes to a temporary file, then the rename, then `:persistent_term`.
- The snapshot is `slim/1` of the models.dev data of 2026-10-13 (`docs/research/models-dev.md`).
- The test helper turns the refresh off and points the cache at `_build`, so no test reads `~/.helyx/cache`. Two tests assumed no catalog: the Codex turn test now asserts the tokens only, and the OpenAI config test uses a model that is in no catalog.

## What broke

- The first test run showed that a 200 with only bad entries replaced the cache: `slim/1` kept a catalog id with no models. A catalog id with no entry left is now dropped.

- Round 1 of the review: a first load could put the old cache over the data of a later refresh (Codex and the failure-path review). The load and the write now take one `:global` lock. The first lock id named the directory as the requester, so it excluded nothing; the new lock test found it. A non-UTF-8 ETag crashed the encode of the cache file; an ETag is now kept only as 1 to 256 bytes of printable ASCII.

- Round 2: the write of a refresh no longer takes the lock. The refresh loads before its fetch, so only the first load needs the lock. The second half of the lock test went with it. The review also found: a marker in the future stopped every refresh (now stale when over a day away); a slim encode could pass 16 MB and give a cache file that the read rejects (now not written); `req_options` could replace the body cap (now the catalog options come last); the lock test did not cover the re-check under the lock (it now puts data while the load waits).

- Owner decision on finding 2.8: the `:model_catalog` env is now checked at each lookup, with the key in the error, as a `:models` entry is. `:openai_req_options` goes to its own ticket.

## Open

- Review finding 4.1: a `url` in `:model_catalog` with a byte that is not UTF-8 makes `lookup/3` raise in `URI.new/1`. The fix is one rescue in `http?/1`. Findings 4.2 (a false test comment) and 4.4 (a module comment) are open too.
- The second marker check under the registered name has no test: it guards a race between two lookups and the start of the refresh.
- The 16 MB cap of the write has no test: the case needs a slim encode over 16 MB. The data of the four catalog ids is 26 KB.
- Two nodes on one cache directory: the node that does not refresh keeps the data that it loaded at its start (feature doc).
