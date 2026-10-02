# Review: tables for the written-out malformed-input tests (#302)

Date: 2026-10-02. Base: `origin/master` at `a14e973`. Scope: `test/helyx/core_test.exs` and the session tests `stream_test.exs`, `stream_events_test.exs`, `loop_test.exs`, `persistence_test.exs`, `file_test.exs`. Test files only.

## Invariant

Each table row keeps the input and the expected rejection of the test it replaces, with the same pattern or a stricter one, and each row has its own test name. The session table also checks, for every row, that the session answers the next prompt.

Out of scope:

- `plugins/bundled/test/helyx/provider/claude_code/` and `provider/codex/`: #301 builds a contract suite there. The malformed-line tests left for later: codex `turn_lines_test.exs` (a `turn/interrupt` error that is not an object; a turn that Helyx did not ask for), `commands_test.exs` (a command start with no turn id or no string id; a second `item/started`; an `inProgress` completion), `tool_items_test.exs` (an open tool item of another type; a completion with another type), `held_events_test.exs` (a line over the cap); claude_code `limits_test.exs` (a line over 16 MiB, two tests) and `replay_test.exs` (a replay to a program with no init line).
- `openai_test.exs`: a table of its four malformed-chunk tests made the file 19 lines longer, because each row needs quoted chunk builders. The four tests already have names and assert different properties. Not changed.
- Tests that were already a loop over a list of inputs (`read_test.exs` offsets, `boundary_test.exs` specs and cwds, `file_test.exs` limits). They are tables already.

## Converted tests

| Deleted test | Covering row |
|----|----|
| `core_test`: rejects two plugins for a single interface, two model context plugins, two compaction plugins, a missing provider, a module that does not exist, a module that implements no interface | `rejects #{name}`, one row each, same plugin list and pattern |
| `stream_test`: a malformed event is the terminal and stops the stream (`garbage`); a delta that is not valid UTF-8 (`raw_bytes`); a rejected tool call from `reject_*` (4) | `a malformed event is the terminal and stops the stream: #{name}`, 6 rows |
| `stream_events_test`: a malformed stream event fails the turn and the session lives (loop of `garbage`, `wide`, `wide_int`); a model provider that sends a harness event fails the turn | `a malformed stream event fails the turn and the session lives: #{name}` |
| `persistence_test`: a delta / a tool call that is not valid UTF-8 is a malformed stream event | same table, rows `raw_bytes`, `raw_call` |
| `loop_test`: a tool call with a bad field shape; a stop reason outside the format's set; a tool call whose arguments the file cannot hold | same table, rows `bad_call`, `bad_stop`, `bad_args` |
| `file_test`: an entry with a shape this module never writes; a tool call id with a wrong type; a content block with a wrong field type; an entry type the writer never produces; a second header mid-file; the first two cases of a model that is missing or not a string | `an entry with a shape this module never writes is rejected, not raised: #{name}`, 7 rows |

The last two cases of the model test (a later valid change, a bad header model) need more than one line and stay one test: `a later valid model change does not launder a bad one, nor a bad header model`.

## Size

| File | Before | After |
|----|----|----|
| `core_test.exs` | 92 | 83 |
| `file_test.exs` | 928 | 901 |
| `loop_test.exs` | 535 | 501 |
| `persistence_test.exs` | 256 | 238 |
| `stream_events_test.exs` | 401 | 406 |
| `stream_test.exs` | 187 | 188 |
| Total | 2,399 | 2,317 |

−82 lines, below the estimate of −400 ±30%. The estimate counted about 40 tests across the provider, session, and stream tests; about 20 were written out one by one outside the folders of #301, and the provider tests stay (see above).

## Round 1 (full)

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

Simplify (4 agents). Fixed: the `sent` column of the stream table, used by one row only (`harness_event` is its own test again); the names of the `reject_*` rows now state the input. Skipped: one table at the `SessionStream` level only (it drops the session-level proof that the turn fails); the next-prompt check on every session row (a few ms per row, one property for all rows); merge of the `raw_call` and `bad_args` rows (different inputs); plain data instead of `quote` in `core_test` (two forms in one table).

| Axis | Findings | Reproduced defects | Resolution |
|----|----|----|----|
| Standards | 0 hard, 5 judgement calls | 0 | Accepted: a table runs as a whole by line number (run one row with `--only test:"<name>"`); the two stream tables test two layers; `quote` carries the `_` patterns. |
| Spec | 2 partial | 0 | Fewer tests and lines than the estimate: stated above. |
| Failure path | 0 | 0 | All 28 rows run. Two rows changed in a scratch copy failed alone. Each `file_test` line resumes when only its named field is fixed. Not reached: a forced failure of a `core_test` or `stream_test` row. |
| Codex adversarial | 0 | 0 | Approve. |

No round reproduced a defect, so the loop ends after round 1.
