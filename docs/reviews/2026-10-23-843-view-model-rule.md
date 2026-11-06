# Review: #843, ViewModelRule keeps failed and aborted replies

Base: `20c31aeb` (merge base with master). The change was uncommitted during the review. It changes tests only.

Invariant: `Helyx.Test.ViewModelRule.transcript/1` leaves out only notice and information cells, so the comparisons in `second_client_test.exs` and `view_model_snapshot_test.exs` check the partial reply of a failed or aborted turn, which the snapshot holds (ADR 0006 section 3).

## Round 1 (full)

Simplify: no change.

Bounds sensor (`bounds_sensor.py --diff 20c31aeb724d818b75b0c575a628d12bd5601c9b`):

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

Agents: standards, spec, failure-path, and the Codex adversarial review (verdict: approve, no material findings).

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | standards, spec | "since #432" and "(#432)" in code comments are history, which belongs in the ADR | n/a, wording | fixed: removed |
| 2 | standards | The `join_during_streaming` comment said `transcript/1` leaves notices out of the live side, but the call runs on both sides | n/a, wording | fixed: "both sides" |
| 3 | standards | "so it counts" does not say what it counts toward | n/a, wording | fixed: "so the comparison includes it" |
| 4 | spec | The two test headers name notices only, but `transcript/1` also drops information cells | n/a, wording | fixed: both headers name information cells |
| 5 | standards | All three headers restate the rule, so a change to the rule has to edit three files | n/a, judgement | accepted: each test header says what its comparisons check, and these headers already restated the rule before this change |

Probes: the spec agent folded a turn with an `:error` reply and its notice, removed the reply cell, and found that `transcript/1` of the broken copy no longer equals the real one. The failure-path agent aborted a gated session during the partial reply. `transcript(from_snapshot(snap)) == transcript(live)` held with the aborted message on both sides, and it failed when the `:aborted` message was removed from `snap.messages`. The spec agent ran the full plugin suite: 1101 tests, 4 properties, 0 failures (56 excluded).

Round 1 reproduced no defect, so the loop ended after one round.

Guarantee table (spec agent):

| Guarantee | Proof |
| --------- | ----- |
| `transcript/1` drops notices and information cells on both sides | `view_model_rule.ex`, `display_only?/1`; probe: a copy without the notice compares equal |
| A failed partial reply with text only is in the transcript, and the comparison checks it | `view_model_snapshot_test.exs:194-207`; `second_client_test.exs:52,58` |
| An aborted partial reply is in the transcript, and the comparison checks it | `view_model_snapshot_test.exs:210-222`; `second_client_test.exs:64-83` |
| A copy with the failed reply removed does not compare equal | spec probe, see above |
| A snapshot shows no notice, so during streaming only the live side has notices to drop | `second_client_test.exs:96`; `view_model_snapshot_test.exs:291` |
