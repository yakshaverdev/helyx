# Review: evidence class for case-specific checklist lines (#642)

Scope: one paragraph in the intro of `docs/agents/review-checklist.md`. A line that a review adds for one case ends with its source and the class of its input: observed, constructed, or not verified. The class guides the next reviewer and is no keep or delete verdict. A changed mechanism gets a review of each line about it, whatever its class.

The change is Markdown only, in `docs/agents/`, so `/ship` skips simplify and the agent axes and runs the Codex review.

## Round 1 (Codex adversarial review, base `origin/master`)

Verdict: approve. No findings. Codex checked the text against the existing Source lines of the checklist, the joint review of 2026-10-16, and the ship and orchestrate skills.

The round reproduced no defect, so the loop ends.

## Decisions

- Existing lines are not tagged with a class. The ticket names the lines that a review adds. A retrofit needs the evidence of each old line, and that is a separate task.
