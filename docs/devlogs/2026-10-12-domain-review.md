# 2026-10-12: Domain review of Core, and its decisions

A deep review of Core and its seam to the bundled plugins, then one decision per finding with the owner, then tickets.

## Done

- Ran the review: six lenses (Opus), proofs up to level 4, three cross-model reviewers (Opus, Fable, Sonnet). Output: `docs/reviews/2026-10-12-domain-review.md`. The baseline of 2026-09-26 has no regressions.
- Checked each finding against other agent harnesses before the decision, with read-only research agents. This changed four outcomes: A1 (cut, do not fail the turn), C2 (give the dropped text back), Q4 (one turn per follow-up), and C4 (a struct, not a string-key rule).
- Recorded the decisions in section 12 of the report.
- Opened #508 to #515 as `ready-for-agent`. #512 is blocked by #510, and #513 by #512, because they change the same session state. Commented the C4 decision on #488.

## What broke

- One research agent stopped on a network error and was resumed.
- An outside review of the decision list found three gaps, all fixed before the tickets: the glossary ticket documented the batch that the queue ticket removes, `Stream` checks the size before the scrub (which can triple the text), and the restore of dropped text had no rule for an existing draft.

## Rules from the owner

- Repo docs stand on Helyx reasons. They do not cite other harnesses. Research and discussion may.
- A doc edit that describes a behaviour change goes in the ticket that changes the code.

## Next

- `/orchestrate` runs #508 to #515.
