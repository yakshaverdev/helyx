# Review: #649 A stable id on every message and an origin on every user message

Invariant: every message that joins a session has one id from its first event to the snapshot and the file, and every user message that Core admits has an origin (`:user`, `:background` with the run id, or `:product` with a checked id); the file reader reads an old user entry as `:unknown` and rejects a malformed origin, a repeated message id, and a message id with `:`.

Feature doc: `docs/features/message-identity.md`. ADR 0006, revision of 2026-10-17.

Accepted holes:

- Request ids with a duplicate check stay deferred (ADR 0006 §4): absence of an origin id in the snapshot proves nothing while a prompt waits in a queue.
- `Background.lost/1` finds the ended and the started runs by the text of the messages (from before #649): a user prompt that starts with the end line of a run stops its lost end, and a tool result whose text starts with the start line counts as a start. A file from before #649 has only the text.
- The ids of entries that are not messages (header, model change, resume id, compaction) are not checked for repeats or format: they reach no client, and the chain check stays as on master.

Bounds sensor, round 1:

```
bounds sensor: 13 candidate functions, 0 flagged, 0 without an answer
```

## Round 1 (full)

Base `origin/master` (`490b4413`).

Simplify, four agents. Applied: `Codec.encode/1` keeps its guard on the id, with no fallback that makes an id; the tests append through the helper `Helyx.Test.SessionFile.append_message/2`, which sets an id when the message has none. Skipped:

- the `{:end, _}` tag of the queue stays: `Queue` treats its items as opaque, and its tests use opaque items;
- `texts` and `text` stay beside `messages` and `message`: the ticket keeps them;
- `Helyx.Message.user/2` stays in the data module: Core-internal, one caller per origin kind;
- the `Message.text/1` copy per sent steer: one per steer, at most 32;
- the hand-built raw entries of `file_test.exs` stay: they are the old format on purpose;
- `Transcript.pair/2` returns the place of each call: the derived id needs it.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex | `String.to_existing_atom/1` of the origin kind depends on the load order of the atoms | Fixed: `decode_origin_kind/1` has one clause per literal kind |
| 1.2 | Codex | A present `"origin": null` read as `:unknown` | Fixed: `Map.fetch/2` tells a missing key from a null; null rejects the file. Test `file_test.exs:140` |
| 1.3 | standards, spec, failure path | The feature doc said that `append_message/2` makes an id | Fixed: it writes the id of the message; a message with no id raises |
| 1.4 | standards, spec | "Entry ids each once" claimed more than the reader checks | Fixed: only message entry ids, stated with the reason |
| 1.5 | standards | `background-bash.md` and `print-background-wait.md` named `{:background_end, text}` | Fixed: `message` |
| 1.6 | standards | The 256-byte origin bound reused the bound of another field | Fixed: its own attribute `@origin_id_max_bytes` |
| 1.7 | standards | The trim of the `Helyx.Session` moduledoc for the 400-line limit dropped rules | Fixed: the two rules that no feature doc held are in `session-lifecycle.md`, "Turn states"; the others were in "The wait" and "Provider death" |
| 1.8 | standards | The test name "a steer keeps its id and origin through the provider's user_message and a drop" named a drop it does not test | Fixed: renamed |
| 1.9 | spec | No test that a rejected steer keeps its id and origin; a probe showed that it does | Fixed: test `provider_process_test.exs:761` |
| 1.10 | spec | `steer_unconfirmed` checked only the `:user` origin | Fixed: test `provider_process_test.exs:777` |
| 1.11 | spec, failure path | A stored message id `A:0` could equal a derived id of a repair result | Fixed: the reader rejects a message id with `:` (round 2: any id that `Id.valid?/1` rejects). Test `file_test.exs:201` |
| 1.12 | spec | The ids map of the reader had no bounds row | Fixed: row added, bounded by the 64 MiB file limit and the heap cap |
| 1.13 | standards | The origin is a map, not a struct | Not changed: the ticket fixes the map shape |
| 1.14 | standards | The queue specs still name `text` | Not changed: judgement; the type is `item()`, and `text` is the name of the old queue fields |
| 1.15 | standards | `Helyx.Message.user/2` calls `Helyx.Session.Id` | Not changed: Core-internal; one generator of ids |
| 1.16 | spec | The submit path has no test of its own | Not changed: the rejected-steer test (1.9) checks the context message of the next turn, which comes from the submit path |

Round 1 reproduced defects (1.2, 1.11). The fix touches more than one code file (`codec.ex`, `reader.ex`, `message.ex`), so round 2 is a full round.

## Round 2 (full)

Base `origin/master`: the state before the round-1 fix was not kept as a commit, so the round reviews the whole change again.

Simplify, four agents. Applied:

- The reader checks a message id with `Helyx.Session.Id.valid?/1` instead of a test for `:` (reuse, altitude). Every entry id came from `Id.new/0` since the first session file (`011edde4`, 9 random bytes, 12 characters). The check also bounds the id that reaches a client. The fixtures of `file_test.exs` with short ids now use ids of that format (`entry_id/1`), and `helyx_test.exs` too.
- The codec writes `"id": null` for a `:user` origin, so one encode clause and one decode match with `map_size(object) == 2` replace the key count (simplification, altitude, efficiency).
- The dead guard of `decode_origin/2` and the dead `Map.delete(acc, :ids)` of `Reader.done/2` are gone: `File.load/3` reads the fields by name.
- `origin?/1` and `resume_id?/1` share one private predicate `text_id?/2`; `map_size` is in the clause guards.
- The new `steer_unconfirmed` test uses `of_type/2`; `file_test.exs` uses its `SessionFile` alias.

Skipped: drop `texts` and `text` from the events (simplification, efficiency): the ticket keeps them for the TUI composer. Check the ids of every entry in `add/4` (altitude): the other entries reach no client, and a message id that equals a `model_change` id leaves the chain check as it is on master; recorded as an accepted hole.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | Codex | Approve, no findings; 53 targeted tests and reader probes passed | n/a |
| 2.2 | failure path | No defect. Probes: a repeated call id in a resumed message gives unique derived ids over two resumes; a lost background end joins with its origin, is written, and resumes with unique ids | n/a |
| 2.3 | standards | The "origin on another role" case had a malformed origin, so it did not test the role rule; no tool result case | Fixed: a valid origin on an assistant and a tool result entry, with a control that the same entries resume with no origin. Test `file_test.exs:140` |
| 2.4 | standards | No test that a message with no id does not encode | Fixed: test `file_test.exs:113` |
| 2.5 | spec | Five rows of the guarantee table named helper or blank lines | Fixed: the rows name the tests |
| 2.6 | spec, standards | `Background.lost/1` finds the ended and started runs by the text, not by the origin (read from the code, not probed) | Not changed: the mechanism is from before #649, and a file from before #649 has only the text. Recorded as an accepted hole |
| 2.7 | standards | Queue specs and variables still say `text`; ids are made in four places | Not changed: judgement, as 1.14 and 1.15 |
| 2.8 | standards | `origin/master` is ahead by #653, so `git diff origin/master` shows its reverse | Not this change: the branch is rebased before the merge |

Round 2 reproduced no defect, so the loop ends. Its fixes are tests and this record.

## Guarantee table

| Guarantee (feature doc) | Test or probe |
| --- | --- |
| Each message has one id from `message_start` to the snapshot, with no `sessions_dir` | `message_identity_test.exs:17` |
| The partial message of the snapshot turn has the id of its `message_start` | `message_identity_test.exs:37` |
| `:product` origin on `prompt`, `steer`, `follow_up` | `message_identity_test.exs:57` |
| Any other origin, an empty id, 257 bytes: `{:error, :invalid_origin}`, nothing queued; 256 bytes and multibyte pass | `message_identity_test.exs:76` |
| A taken steer keeps its origin, and its id reaches the snapshot | `message_identity_test.exs:108` |
| A rejected steer keeps its id and origin into the next turn's context and the snapshot | `provider_process_test.exs:761` |
| `steer_unconfirmed` carries `message` with its origin beside `text` | `provider_process_test.exs:711` (with the helper `unconfirmed/1` at `:596`), `provider_process_test.exs:777` |
| `queue_dropped` carries `messages` beside `texts` | `message_identity_test.exs:130`, `loop_test.exs:471`, `provider_process_test.exs:935` |
| A background end has origin `:background` with the run id; a lost end too | `background_delivery_test.exs:97`, `background_test.exs:47` |
| A resume reuses the ids and origins of the file | `message_identity_test.exs:145`, `file_test.exs:51` |
| A user entry with no origin reads as `:unknown` | `file_test.exs:131` |
| A malformed origin (null too), or a valid origin on an assistant or tool result entry, rejects the file | `file_test.exs:140` |
| A repeated message id rejects the file | `file_test.exs:188` |
| A message id that `Id.new/0` never makes (`:` too) rejects the file | `file_test.exs:201` |
| A message with no id does not encode | `file_test.exs:113` |
| Derived ids `<assistant id>:<n>` by the place among the calls, also for a repeated call id | `transcript_test.exs:60`, `transcript_test.exs:136` |

## Precommit

The first run failed on two Credo findings and on the host. Credo: the alias order in `records.ex`, and the nesting depth of `Transcript.pair/2`, where `Enum.find/2` now takes `&match?({%Message.ToolCall{id: ^id}, _place}, &1)` in place of an anonymous function with the same test. Both are one line each, with no change in behaviour, so no review round follows them. The host: `deps.get` of `plugins/bundled` stopped with `{:error, :eaccess}` on the Hex cache of the host (`Hex.Registry.Server.persist/2`), not a defect of the change.
