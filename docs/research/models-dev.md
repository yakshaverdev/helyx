# models.dev `api.json`

Probe of 2026-10-13, 08:29 and 08:40 UTC, with `curl` against `https://models.dev/api.json`. The ETag of the data was `"2e9b2ba5d129e1768a1144f35efe7e0b"`. The bundled snapshot `plugins/bundled/priv/models_dev.json` is `Helyx.ModelInfo.Catalog.slim/1` of this data (#560).

## The response

- With no `Accept-Encoding`: status 200, `content-type: application/json`, `content-length: 5593299` (5.6 MB), `cache-control: public, max-age=0, must-revalidate`, and a strong `etag`. Served by Cloudflare.
- With `If-None-Match` and that ETag: status 304, empty body.
- With `Accept-Encoding: gzip`: `content-encoding: gzip`, and the ETag is weak (`W/"…"`).

## The shape

- The top level is an object of 228 providers, keyed by provider id. Each provider has `id`, `env`, `npm`, `name`, `doc`, `models`, and some have `api`. `models` is an object keyed by model id; each model's `id` equals its key in the four mapped providers.
- Model counts of the four mapped catalog ids: `anthropic` 17, `openai` 53, `opencode-go` 36, `opencode` 121.
- `limit` holds `context`, `input`, and `output`. Five `openai` models have `context` 0: `chatgpt-image-latest`, `gpt-image-1`, `gpt-image-1-mini`, `gpt-image-1.5`, `gpt-image-2`. The largest `context` of the four mapped ids is 1,050,000; over all providers it is 99,999,999.
- `cost` holds USD per million tokens: `input`, `output`, `cache_read`, `cache_write`, `input_audio`, `output_audio` (integers and floats). Four models of the four ids have no `cost`.
- `cost.tiers` is a list of price sets, each with `tier: {"type": "context", "size": <tokens>}`, for example `openai/gpt-5.4`: `{"input": 5, "output": 22.5, "cache_read": 0.5, "tier": {"type": "context", "size": 272000}}`. Every tier of the four ids is of type `context`.
- 13 `openai`, 8 `opencode-go`, and 16 `opencode` models also have `cost.context_over_200k`, a price set with no size. In `openai/gpt-5.4` it sits next to `tiers` with the same prices and another threshold (272,000 in `tiers`).
