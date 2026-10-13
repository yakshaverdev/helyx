# Usage and model limits

Ticket #488. The domain review of 2026-10-12 (`docs/reviews/2026-10-12-domain-review.md`, C4 and Q3) decided the struct. The facts of the serving side are in `docs/research/codex-app-server.md` ("Token usage and the context window") and `docs/research/claude-code-stream-json.md`.

## Goal

The user sees the tokens and the cost of the session so far, the share of the prompt that came from the cache, and how full the context is. Row 2 of the footer shows these values. Helyx never guesses a value: a value that no source gives is not shown.

Decisions and their reasons:

- **One struct, `Helyx.Usage`, for every provider.** Each provider maps its own wire fields into it at its boundary. The reason: a client reads one shape, live and after a resume. Today each provider sends its own keys, and a resume turns atom keys into string keys.
- **The usage carries the context window.** The field is `context_window` of `Helyx.Usage`, not a new field of the `done` event. The reason: the usage already travels from the `done` event into the message, the session file, the snapshot, and the client. So the window needs no new event field and no new snapshot field, and a resume gets it back. The window is the one that applied to the model call, so a later change of the window does not change an old message.
- **The usage carries the context tokens of the last model call** (`context_tokens`). The reason: a harness turn has many model calls, and the token fields hold the sum of the turn. The context % needs the size of the last prompt, not the sum.
- **The source rule** (decided by the owner, #488). For the context window and the prices of a model, Helyx takes the first source that has the value: (1) the serving side, (2) config, (3) the models.dev catalog, (4) nothing. The window and the price set are two values. A price set comes whole from one source. The reason: prices from two sources make a price list that no source states.
- **The cost of a turn** is the cost that the serving side reports. Otherwise it is the usage times the prices from the source rule. A token count above zero with no price makes the cost unknown. The reason: a cost without that part is a guess.
- **The footer shows session totals** (decided by the owner on 2026-10-13). The tokens, the cache share, and the cost add up over every assistant message of the current branch, across resumes. The context % comes from the last model call.
- **A total with an unknown part shows the known sum as a lower bound**, as `≥$1.23 list`. The reason: the sum of the known costs is a fact, and the mark says that the true cost is not lower. No value is guessed. When no cost is known at all, the footer shows `$?`, so an unknown cost never looks like a session with nothing to count. To show no cost would hide a known fact for the rest of the session after one message with no price.
- **No max output.** The ticket lists it in config. No part of this ticket reads it, so it stays out until compaction (#490) or a thinking clamp needs it.

## Interface changes

### `Helyx.Usage` (Core, `lib/helyx/data/usage.ex`)

```elixir
defstruct input: 0, output: 0, cache_read: 0, cache_write: 0,
          cost: nil, cost_kind: nil, context_tokens: nil, context_window: nil
```

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `input` | `non_neg_integer()` | prompt tokens that were not read from or written to the cache, summed over the model calls of the message |
| `output` | `non_neg_integer()` | output tokens, reasoning tokens included, summed the same way |
| `cache_read` | `non_neg_integer()` | prompt tokens read from the cache |
| `cache_write` | `non_neg_integer()` | prompt tokens written to the cache |
| `cost` | `number() \| nil` | USD; nil when unknown |
| `cost_kind` | `:billed \| :list \| nil` | `:list` for a list price, `:billed` for what the serving side billed; nil exactly when `cost` is nil |
| `context_tokens` | `non_neg_integer() \| nil` | the prompt and the output of the last model call: the context that the next call starts from |
| `context_window` | `pos_integer() \| nil` | the context window of the model of the last call |

A token field that the wire does not report is 0. A wire field that the provider maps is listed in the provider table below. A token sum is in `input`, `output`, `cache_read`, `cache_write`; `context_tokens` is never a sum.

**Nil and unknown are two values.** A nil usage means that there is nothing to count: a message that the session closed in the middle of a turn, or a provider that never reports usage (`fake`). A usage with `cost: nil` means that the accounting is missing or partial: the footer counts it as a cost that is not known. The unknown usage is `%Helyx.Usage{}`, with zero tokens and `cost: nil`. A provider that reports usage gives a usage at every `done`, never nil: when the serving side reported nothing or only a part since the previous `done`, the usage holds the tokens that it knows and `cost: nil`.

**Value bounds.** Two sets of bounds keep every sum finite and checked:

| Bound | Token count | Cost | Context window | Where |
| ----- | ----------- | ---- | -------------- | ----- |
| wire bound: one value that a provider maps from the serving side | an integer from 0 to 1,000,000,000 (10^9) | a float or an integer from 0 to 1,000,000 USD (10^6) | an integer from 1 to 10^9 | the provider, at the wire |
| struct bound: a field of `Helyx.Usage` | an integer from 0 to 10^15, for each token field and for `context_tokens` | a float or an integer from 0 to 10^12 USD | an integer from 1 to 10^9 | `Stream.check/1`, the session file reader |

The reasons: the largest context window in the models.dev catalog of 2026-10-12 is about 10^6 tokens, so 10^9 is a thousand times above any count of one model call, and 10^6 USD is far above the cost of any one turn or program process. A config price is at most 10^6 USD per million tokens ("Config"), so the computed cost of one call is at most 4 × 10^9 × 10^6 / 10^6 = 4 × 10^9 USD, under the struct bound. A BEAM float is finite (no infinity, no NaN) and holds at most about 1.8 × 10^308, so a sum of two costs under 10^12 cannot overflow. Every source of a window or a price uses the wire bound: the serving side (each provider), config (`lookup/2`), and the catalog (the slim function). So a window from any source passes the struct bound, and a price from any source gives a cost under it.

`Helyx.Usage.add/2` adds a later usage to an earlier one. Both are within the struct bound. The four token fields add up. When either cost is nil, the cost and the kind are both nil: an unknown part makes the sum unknown. Else the costs add up, and the kind is `:list` when either kind is `:list`, else `:billed`. `context_tokens` and `context_window` come from the later usage. The sum saturates: a token sum over 10^15 becomes 10^15 and makes the cost and the kind nil, and a cost sum over 10^12 makes the cost and the kind nil, because the exact value is then not known. Each operand is at most 10^15 or 10^12, so the sum before the clamp is at most 2 × 10^15 (an integer, which BEAM never overflows) or 2 × 10^12 (a float, far from overflow). So the result is always within the struct bound and passes `Stream.check/1`, whatever the number of calls before a `done`: 10^15 / 10^9 = 10^6 calls at the wire bound reach the clamp, and the clamp marks the cost unknown. Every sum of usage in a provider goes through it.

### Provider contract (`lib/helyx/interfaces/provider.ex`, `lib/helyx/provider/loop.ex`)

- `{:done, %{stop_reason: stop_reason(), usage: Helyx.Usage.t() | nil}}` and `{:message_end, stop_reason(), Helyx.Usage.t() | nil}`. Nil means that there is nothing to count (see "Nil and unknown are two values"). A provider that reports usage never gives nil at `done`.
- `Helyx.Message.usage` becomes `Helyx.Usage.t() | nil`, default nil. The session closes a message with no usage (a close at a tool result or a steer) with nil, not `%{}`.

### Core checks

- `Helyx.Session.Stream.check/1` accepts nil or a `%Helyx.Usage{}` with exactly the eight fields, the token fields integers within the struct bound, `cost` nil or a number within the struct bound, `cost_kind` as the table says, `context_tokens` nil or an integer within the struct bound, and `context_window` nil or an integer within the struct bound. The range checks are integer and float comparisons, with no encode, and they also keep every integer under the digit limit of `Helyx.Message`. Anything else fails the turn through the generic path (`{:bad_stream_event, event}`). A map in the usage slot is malformed.
- `Helyx.Session.File.Codec` writes the usage as a JSON object with string keys, nil fields left out, and `cost_kind` as `"list"` or `"billed"`. The reader decodes the object into the struct with the same rules as `check/1`. A `usage` key that is present and fails a rule decodes as the unknown usage `%Helyx.Usage{}`, and the message stays: the usage is the smallest unit, and the footer still marks the cost as not known. A usage of a file from before this change (the provider's own keys) is such a usage. Only a message with no `usage` key decodes as nil. So the footer shows the same values and the same `≥` mark after a resume as live.

### Per provider

Each provider checks every wire value that it maps against the wire bound ("Value bounds"). A value outside the bound takes the same path as a wire value with a bad shape in that provider, so no new path exists for it: for `claude-code`, the `result` adds nothing to the tokens and makes the cost nil; for `codex`, the notification adds nothing and sets the flag, so the cost of the next `done` is nil; for `opencode-go` and `opencode`, the chunk fails the shape check of `Helyx.Provider.OpenAI.Events`, and the call fails with `{:bad_chunk, payload}`, as today. A count that the mapping subtracts (`inputTokens` minus `cachedInputTokens`, `prompt_tokens` minus `cached_tokens`) and that comes out below 0 is a value outside the bound. Unlike a contract break of plugin output into Core, the wire value comes from an external program or network, and the provider is its boundary (`AGENTS.md`, "Validate at boundaries"). Core still answers a struct outside the struct bound with the generic failure.

The invariant: **the usage of each `done` covers every model call that the serving side reported since the previous `done` of the same provider process.** A model call is in exactly one usage. So a Helyx turn that the provider keeps open across several program turns adds up all of them, and the usage of a turn that ended with no `done` (aborted or failed) goes into the usage of the next `done`, not out of the totals. The reason: the footer shows session totals, and a call that is in no usage makes the totals too low with no mark. The provider keeps the sum in its process state and starts a new sum after each `done`. A provider keeps a flag with the sum: set when a turn ended with no `done` and the provider cannot show that the serving side reported every call of it (an abort or an error that cut a model call, a program turn that failed). A `done` with the flag set gets `cost: nil`, so the footer marks the total. Today only `claude-code` sets it, for a call cut while it streamed; the flag of `codex` and the OpenCode `Loop` waits for #559 and is not current behaviour. A new provider process starts with no sum and no flag: the usage of a process that ended before its next `done` is in no message. This is a known ceiling ("The footer").

| Provider | Tokens | `context_tokens` | `context_window` | `cost` |
| -------- | ------ | ---------------- | ---------------- | ------ |
| `claude-code` | the sum of the `usage` of every `result` line since the previous `done` (each `result` `usage` is for one program turn): `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`. A Helyx turn can span several `result` lines: an unresolved steer or a positive `queued_turn_count` keeps it open (`claude_code.ex`, `turn_result/2`) | the sum of the four counts of the last `assistant` line's `message.usage` | `modelUsage.<model>.contextWindow` of the `result` that ends the turn, where `<model>` is the only key, or the key equal to the last `assistant` line's `message.model`; else config, catalog `anthropic`, nil | `total_cost_usd` of the `result` that ends the turn minus the mark, kind `:list`. The mark is the `total_cost_usd` of the `result` of the previous `done` of the same program process; for the first `done` of a program process it is 0 for a fresh harness session, and for a resumed one the sum of the costs that the session file holds for the `done` events of that harness session (see below). It is nil when any part is unknown: a `result` since the previous `done` with no valid `usage` or with a `modelUsage` entry whose `costBasis` is not `"list"`, a `total_cost_usd` that is not a non-negative number, a total below the mark, a mark that is not known, or a `result` since the previous `done` with `terminal_reason` `aborted_streaming` (a call cut while it streamed is in no total, research note 2026-10-13). A `result` with no valid `usage` adds nothing to the tokens and makes the cost nil; the `done` still carries the usage |
| `codex` | the sum of `tokenUsage.last` over the `thread/tokenUsage/updated` of the thread's turns since the previous `done`: `inputTokens` minus `cachedInputTokens`, `outputTokens`, `cachedInputTokens`, `cacheWriteInputTokens`. One Helyx turn is one Codex turn: a steer joins the running turn (`turn/steer`), and the program rejects a steer after the turn ends. The program sends one notification after each model call (research note), so the sum covers the calls of the turn | `last.totalTokens` of the last notification | `tokenUsage.modelContextWindow` of the last notification; else config, catalog `openai`, nil | the sum over the notifications of `last` times the prices (config, catalog `openai`), each call priced alone, kind `:list`. A `done` with no notification since the previous `done` carries the unknown usage. A turn that ended `interrupted` or `failed` sets the flag (waiting for #559; not current behaviour) |
| `opencode-go`, `opencode` | the `usage` chunk of one model call: `prompt_tokens` minus `prompt_tokens_details.cached_tokens`, `completion_tokens`, `cached_tokens` (0 when absent), cache write 0. Each model call of a Helyx turn gives its own `done` to `Helyx.Provider.Loop`, and each message gets the usage of its call. One path drops a usage today: a call with no block and no tool call while a steer is held sends no `message_end` (`loop.ex`, `terminal/2`, the last branch). `Loop` keeps that usage and adds it to the usage of the next message of the turn. A call that an abort or an error ends reports no usage, and `Loop` sets the flag (waiting for #559; not current behaviour). A call whose stream has no `usage` chunk gives the unknown usage | `prompt_tokens` plus `completion_tokens` | config, catalog `opencode-go` or `opencode`, nil | the usage times the prices (config, catalog), kind `:list` |
| `fake` | nil usage: it makes no model call | | | |

Four facts had to be verified before the code. The probes of 2026-10-13 (#557, research notes `codex-app-server.md`, `claude-code-stream-json.md`, and `opencode-usage.md`) give:

- Whether Codex `inputTokens` includes `cacheWriteInputTokens`: still not verified. `cacheWriteInputTokens` was 0 in every run. Until a run that writes cache shows it, a Codex notification with a nonzero `cacheWriteInputTokens` makes the cost of the turn nil (waiting for #559; not current behaviour).
- The usage chunk of each OpenCode gateway: not recorded, because the machine of #557 had no OpenCode key. The mapping of the table above follows this doc, not a recorded chunk. A recorded chunk of each gateway, one with a model that writes cache, still goes into a research note.
- The key of `modelUsage` for a model of a `claude-code/<alias>` ref: the one key equals the `message.model` of the `assistant` lines (`opus` and `haiku`). The rule of the table finds the entry.
- How Codex reports the model calls of a sub-agent: the child's calls are not in the parent's `last`. The child's `thread/tokenUsage/updated` carries the child thread's id and turn id, and the provider drops a notification of another turn (`codex.ex`, `turn_notification/3`). So the tokens of a sub-agent are not in the totals. This is a permanent ceiling. A usage whose turn started a sub-agent (a `subAgentActivity` item) has cost nil (waiting for #559; not current behaviour), so the footer marks the total with `≥`; the token sums have no mark of their own, and the cost shows `≥$…` or `$?`.

The program process of `claude-code` keeps the `total_cost_usd` of the `result` of its last `done` and the usage sum since then. A `result` that ends no `done` (an aborted turn, a steer wait, a positive `queued_turn_count`) adds its usage to the sum and does not move the mark, so its tokens and its cost go into the next `done`.

A program that resumes a harness session (`--resume`) reports `total_cost_usd` and `modelUsage` over the whole harness session, earlier programs included (research note, 2026-10-13). So the mark of its first `done` is derived, and nothing new is stored: Core gives the provider the sum of the usages of the assistant messages since the resume id of the harness session (`init/3` option `:resume_usage`, `Helyx.Session.Transcript.resume/3`). The session file connects each message to its harness session by place: the resume id entry comes before the first message of its harness session, and a message of another provider makes the next one start fresh. The mark is the cost of that sum. A stored cost that is not known makes the mark not known, and the first `done` gets `cost: nil`; so does a total below the mark. Accepted ceiling: work that the harness session did outside Helyx is in the total of the resumed program and in no stored message, so the first `done` after the resume counts it once. The same holds for a turn that the program started by itself and that the session dropped because it was busy (#240): its `done` is in no message, so its cost is in no stored message, and the first `done` after the resume counts it once. A fix needs a record on disk, and the rule stores nothing new. The owner accepted this limit on 2026-10-13.

### `Helyx.ModelInfo` (bundled helper, `@moduledoc false`, ADR 0005)

- `lookup(provider_id, model)`: `{:ok, %{context_window: pos_integer() | nil, prices: prices | nil}}` or `{:error, {:bad_config, [:models, ref, key]}}`. It applies steps 2 to 4 of the source rule. A provider calls it at its start (`init/3` of a harness provider, the start of `stream/3` of a model provider, because `Helyx.Provider.Loop` owns `init/3`), and the serving side wins at the `done`.
- `cost(token_counts, prices)`: `{cost, :list}` or nil, for one model call. `prices` are USD per million tokens: `input`, `output`, and the optional `cache_read`, `cache_write`, and `tiers`. A tier `{size, prices}` applies when the prompt of the call (`input + cache_read + cache_write`) is over `size` tokens; the largest such size wins.
- The provider-to-catalog map: `claude-code` → `anthropic`, `codex` → `openai`, `opencode-go` → `opencode-go`, `opencode` → `opencode`. A provider with no row has no catalog step.

### Config

```elixir
config :helyx_plugins, :models, %{
  "codex/gpt-6.1-sol" => [
    context_window: 475_000,
    prices: [input: 2.0, output: 10.0, cache_read: 0.1, cache_write: 2.5]
  ]
}
```

The key is a model ref. Both keys of an entry are optional; `prices` needs `input` and `output`. Config is a boundary: the entry of the ref in use is checked at `lookup/2`, and an unknown key or a bad value is `{:error, {:bad_config, [:models, ref, key]}}`, which fails the session start (harness) or the first model call (model provider), with the key in the error. An entry of another ref is not checked: the smallest unit fails.

### The catalog (`Helyx.ModelInfo.Catalog`, bundled helper, `@moduledoc false`)

- The bundled snapshot `plugins/bundled/priv/models_dev.json` holds, for the four mapped catalog ids only, each model's `limit.context` and its prices with tiers (about 34 KB on 2026-10-12, against 1.1 MB for all 227 providers). One function slims a full `api.json`; the same function makes the snapshot and checks a refresh.
- The data lives in `:persistent_term`, loaded at the first lookup of a node from the cache file, else from the snapshot. A refresh replaces it.
- A lookup starts a refresh when the attempt marker (`models.dev.attempt` in the cache directory) is missing or older than 24 hours. The refresh is one unlinked process with a registered name, so a node runs at most one. It touches the marker first, so a refresh that fails or crashes also counts. It fetches `https://models.dev/api.json` with `If-None-Match` and the stored ETag. A 200 is slimmed, checked, and written to a temporary file, then renamed over the cache file; a 304 keeps the cache. Any failure keeps the last good copy. A turn never waits on a refresh.
- Application env of `helyx_plugins`, key `:model_catalog`: `dir` (default `~/.helyx/cache`), `url` (nil turns the refresh off; the test config sets nil), and `req_options` (tests give a `Req.Test` plug). No test fetches models.dev.
- A limit value of 0 is unknown (seen: `openai/chatgpt-image-latest`, context 0).

### The footer (`Helyx.TUI.Footer`, `Helyx.TUI.ViewModel`)

Row 2 becomes: the model, the run state, the usage values, the queue counts, and `scrolled`. The usage values are:

- `in <n> out <n>`: the sums of `input + cache_read + cache_write` and of `output` over the session, when the sum of all four token fields is above 0. Every model call has prompt tokens, so a sum of 0 means that no usage reported tokens (only unknown usages), and a `0` would show an unknown count as a known one.
- `cache <p>%`: the sum of `cache_read` over the sum of the prompt tokens of the session, when that sum is above 0.
- The cost (decided by the owner on 2026-10-13), from the usages of the session that are not nil:
  - every usage has a cost: the sum, as `$1.23`;
  - some usages have a cost and some have `cost: nil`: `≥` and the sum of the known costs, as `≥$1.23`;
  - no usage has a cost, and at least one usage exists: `$?`;
  - no usage exists (every message has a nil usage, or there is no message): no cost field.
  `list` comes after a sum when any known cost is `:list` (`$1.23 list`, `≥$1.23 list`). It never comes after `$?`.
- `<p>%`: the context %, yellow over 70, red over 90, else dim.

The session is every assistant message of the snapshot and of the events after it: the current branch, across resumes, and across model switches. The totals count the usage that the providers reported. A message with a nil usage adds nothing: there is nothing to count in it. A usage with `cost: nil` adds its tokens and makes the cost show as `≥$…` or `$?`; this holds live and after a resume, because the session file keeps the usage. The usage of a turn that was aborted or failed is in the usage of the next `done` of the same provider process, with `cost: nil` when the provider cannot show it complete ("Per provider"). Known ceiling: a turn that ends with no `done` in a provider process that ends before its next `done` (the program exits, the provider process stops, a model switch, the end of the session) is in no message, so its usage is not in the totals and no mark shows. The session file has no record of a turn end, so a resume cannot find such a turn; a fix needs a turn-end record on disk, which is out of scope here. The token sums carry no mark of their own: a usage with `cost: nil` can hold all the tokens of its calls (no price) or a part of them (missing accounting), and the struct does not tell the two apart. The `≥` or the `$?` of the cost is the one mark of missing accounting in the row. The view model folds the totals in `add_message/2`, so the live path and the snapshot path give the same values, and a resumed session shows what the live one showed. The context estimate is `context_tokens` of the last usage plus a quarter of the bytes of the text, thinking, and tool result text of the messages after it. Bytes, not characters: `byte_size/1` costs nothing, and text that is not ASCII then counts high, so the % errs high. The context % is the estimate over `context_window` of the same usage. It shows only when both are known and the model of that message is the current model of the view model: after a model switch, the old window is not the window of the new model.

## Replaced mechanism

The usage map of a provider is replaced by `Helyx.Usage`.

1. Each item of the old mechanism and its replacement:
   - The `usage: map()` of the `done` and `message_end` types: `Helyx.Usage.t() | nil`.
   - `Stream.check/1`, `done` and `message_end`: a plain map, under the digit limit, that JSON can encode, becomes the struct check of "Core checks". The struct holds only integers, numbers, two atoms, and nil, so the JSON check goes.
   - `Records`: a message closed at a tool result or a steer gets `%{}`; it gets nil.
   - `Codec.encode/1`: `map_size(usage) > 0 && usage` becomes the struct encode, with nil left out. `decode_usage/1`: any map with the integer cap becomes the checked decode; a bad usage is the unknown usage, where before a bad usage was `%{}`.
   - `Message` default `usage: %{}`: nil.
   - `Helyx.Provider.ClaudeCode.Turn.usage` (the last `message.usage`, of the last program turn only), `Helyx.Provider.Codex.Items.usage` (the last `tokenUsage.last`, reset at each turn end), `Helyx.Provider.OpenAI.Events` `usage/1` (atom keys `:input`, `:output`), and the `%{}` of `Helyx.Provider.Fake`: the mappings of the provider table. The usage sum moves from the turn state to the provider process state, so a turn end with no `done` does not reset it.
   - `Helyx.Provider.Loop`, `terminal/2`: the branch that dispatches with no `message_end` drops the usage of its call; `Loop` keeps it for the next message.
2. No reply is removed.
3. Tests of the old mechanism: `test/helyx/session/stream_test.exs` and `stream_events_test.exs` (a usage map passes or is malformed) keep the property with the struct; `test/helyx/session/file_test.exs` (usage round trip, a bad usage decodes as missing) keeps it with the struct; the provider tests that assert the raw usage (`openai/events_test.exs`, `openai_test.exs`, `codex/turns_test.exs`) assert the struct. `test/support/interfaces.ex` and the fakes send the struct or nil.
4. Seen by users and clients: row 2 of the footer shows the usage values. `Message.usage` in events and snapshots changes type (ADR 0006: the bundled TUI is the only client, so the change ships in one release). The usage of a session file written before this change decodes as the unknown usage, so after a resume the cost of such a session shows as `≥$…` when a later message has a known cost, else as `$?`, and its token sums leave out the old messages.
5. No state without a bound.

## Bounds

| What | Bound | Over the bound | Enforced in |
| ---- | ----- | -------------- | ----------- |
| a wire value of usage | the wire bound: a token count from 0 to 10^9, a cost from 0 to 10^6 USD, a window from 1 to 10^9 | the bad-shape path of the provider ("Per provider") | each provider |
| a usage from a provider | the struct bound: each token field and `context_tokens` from 0 to 10^15, a cost from 0 to 10^12 USD, a window from 1 to 10^9; the struct rules of "Core checks" | the turn fails (`bad_stream_event`) | `Helyx.Session.Stream.check/1` |
| a usage from the session file | the struct bound and the same rules | the unknown usage `%Helyx.Usage{}`, the message stays | `Helyx.Session.File.Codec` |
| models.dev response body | 16 MB, counted as the chunks arrive | the fetch stops, the last good copy stays | `Helyx.ModelInfo.Catalog` |
| models.dev fetch | 30 s for each chunk (`receive_timeout`), 60 s for the whole fetch, in a Task of the refresh process | the Task is killed, the last good copy stays; no turn waits | `Helyx.ModelInfo.Catalog` |
| refresh rate | one attempt for each 24 hours for each cache directory (the marker), and one refresh process for each node (the registered name). Two nodes on one directory in the same second can both fetch: accepted | no fetch | `Helyx.ModelInfo.Catalog` |
| models.dev shape | the four mapped catalog ids only; each model entry is checked: an id of 1 to 256 bytes, `limit.context` an integer from 1 to 10^9, the wire bound of a window (0 is unknown; a value above 10^9 drops the window of the entry), each price a number from 0 to 1,000,000, at most 8 tiers, each of type `context` with a positive integer `size` | a bad entry is dropped, not the catalog; a price set with a tier of another type is dropped | the slim function |
| cache file read | 16 MB, then the checks of the slim function | the snapshot is used | `Helyx.ModelInfo.Catalog` |
| config entry | `context_window` from 1 to 1,000,000,000; each price a number from 0 to 1,000,000; only the known keys | `{:error, {:bad_config, [:models, ref, key]}}` | `Helyx.ModelInfo.lookup/2` |
| Claude Code cost | a `total_cost_usd` within the wire bound (0 to 10^6 USD), at or above the mark (the total at the previous `done` of the process, or the stored sum at a resume) | the cost of the `done` is nil | `Helyx.Provider.ClaudeCode` |
| usage sum of a provider process | one `Helyx.Usage` of fixed size; `add/2` saturates at the struct bound | a token sum stays at 10^15, and the cost and the kind are nil | `Helyx.Usage.add/2` |
| footer usage values | a token count shows in at most 6 columns (`999`, `12.3k`, `12.3M`, `12.3B`, `>999B`); a cost in at most 10 (`$?`, `$0.0042`, `$12.34`, `$99999.99`, `≥$99999.99`, `>$99999`, `≥>$99999`), then ` list` when it applies; a % in at most 5 (`>999%`) | the capped form | `Helyx.TUI.Footer` |
| footer row | one row | cut at the width, as today | `Helyx.TUI.Footer` |
| context estimate | an integer count of bytes in the view model; it grows with the transcript, as the cells do | none | `Helyx.TUI.ViewModel` |
| session totals | four integer sums and one float cost sum in the view model; each usage is within the struct bound. The integer sums are BEAM integers, which do not overflow. The cost sum gains at most 10^12 for each message, so it reaches the float limit (about 1.8 × 10^308) only after more than 10^296 messages, which no transcript can hold | none; the footer shows the capped form (`>999B`, `>$99999`) | `Helyx.TUI.ViewModel` |
| endpoint `/models` | the body cap and the timeout of models.dev | applies in #550 | #550 |

Each numeric limit gets tests at the limit, one under, and one over; the token and cost formats also get a multibyte check of the row cut.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| refresh process | `Catalog`, at a lookup, with `spawn/1` (no link) | itself, by its registered name | it ends after one fetch and one write | the VM frees the name; the marker holds the next try for 24 hours | none: no turn owns it; it ends with the VM |
| fetch Task | the refresh process (`Task.async/1`) | the refresh process, linked | its reply | the link ends it | killed at the 60 s deadline |
| HTTP connection | Req, in the fetch Task | the Finch pool of Req | back to the pool | Finch closes the connection of a dead caller | the same |
| temporary cache file | the refresh process, with a name that holds the OS pid and a unique integer | the refresh process | renamed over the cache file | stays on the disk, accepted: at most one file of at most 16 MB for each crashed refresh, and at most one refresh a day | the same |
| `:persistent_term` entry | the first lookup of a node | the node | replaced by a refresh, at most once a day | stays | none |

## Out of scope

- The model list and a model picker. The source rule for the list is recorded in #488: Claude Code control `initialize` (`models`), Codex `model/list`, and an endpoint's `/models`.
- The rows of the general endpoint provider (#550): its `/models` as the serving side, and a catalog id from config.
- Ollama `/api/show`; config covers a local window.
- Codex rate limits (`account/rateLimits/updated`).
- Compaction (#490), which uses the context % as its trigger, and the max output.
- A thinking level clamp.
- A per-turn view of tokens or cost.
- Images in the context estimate.
- A turn-end record in the session file, which the known ceiling of "The footer" needs.

## Delivery

The change is larger than one `/ship` can review within its limits (three rounds, 45 minutes): about 700 lines of code over Core, four providers, a network refresh with files and a process, and the TUI. It goes in four tickets, in this order:

1. **`Helyx.Usage` and the serving side.** The struct, `Stream.check/1`, the codec, `Message`, the provider types, `Helyx.Usage.add/2`, the four provider mappings with the usage sums of the invariant, the serving-side window, and the Claude Code cost, the usage that `Loop` keeps, and the resume test. First the four checks of "Per provider" above. No footer, no config, no catalog. About 250 lines of code.
2. **The footer.** The fold of the session totals and the estimate in `ViewModel`, the formats and colors in `Footer`, and the per-provider footer tests from recorded streams. After 1. About 150 lines.
3. **Config and the price math.** `Helyx.ModelInfo.lookup/2` with steps 2 and 4 (no catalog yet), `cost/2` with tiers, the config check, and the Codex and OpenCode costs. After 1; in parallel with 2. About 150 lines.
4. **The catalog.** The snapshot and its slim function, `:persistent_term`, the refresh process, the cache file, and the bounds and ownership rows above. After 3. About 200 lines.

The acceptance of #488 splits the same way: the resume test in 1; the footer values per provider in 2; each step of the source rule in 3 and 4; the offline catalog in 4.
