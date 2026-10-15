# Review: #566 A background sub-agent and the usage

Invariant: every claim, number, and citation in the new research section "A background sub-agent and the totals", in the two ceilings of `docs/features/usage-and-limits.md`, and in the devlog follows from the raw lines of three probe runs on `claude` 2.1.296, from the earlier research notes, or from `Helyx.Provider.ClaudeCode.Meter`.

The diff is Markdown only, in `docs/features/` and `docs/research/`: so steps 1 and 2 of `/ship` reduce to the Codex review, with a brief that asks it to check each claim against the probe lines.

Accepted (owner, triage of #566, 2026-10-15): an interrupt that stops a background sub-agent can leave the next cost known and too low; the token sums leave out sub-agent and compaction calls. Not decided: a rule that takes the token sums from the `modelUsage` difference.

## Round 1 (Codex)

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | Codex | Run C: "the other counts agreed the same way" is false for `outputTokens` (1158, against 780 from the lines). Checked in `done.jsonl`: the `output_tokens` of an `assistant` line is the count at the start of its call | Fixed: the reconciliation claims name the input counts only, and the note records the output mismatch and its reason. The feature doc and the devlog say the same |

## Round 2 (Codex)

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | Codex | The devlog said the next cost is known after the stop; in run A `aborted_streaming` makes it nil | Fixed: the devlog names run B for the known cost and run A for nil. A wording finding in the devlog, not a defect in the note or the feature doc (the feature doc says "can"), so the loop ends |

## Gate (orchestrator, 2026-10-15)

Codex adversarial review, base `origin/master` (`abcee1fb`), on `9266cf85`. Gate r1 (Codex): verdict approve, no finding; it checked the claims against the three raw probe logs, the earlier research, and `Meter`.

The option for gap 2 (token sums from the `modelUsage` difference) is ticket #604.
