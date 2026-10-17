# Review: skills after a summary compaction (#745)

Scope: `git diff origin/master` on `ticket/745-skills-compaction`. Feature doc: `docs/features/skills.md`, "After a summary compaction"; `docs/features/summary-compaction.md`.

Invariant: at each context build with a stored summary, `Helyx.ModelContext.Default` derives from the transcript the skills loaded before the first kept message and not loaded again after it, and puts one id-less user message with their transcript texts (newest first, at most 5 texts and 32,768 bytes, one line for each other skill while the lines fit) in front of the first kept message; `Helyx.Compaction.Summary` keeps id-less messages from before the cut after its summary and leaves them out of the summary input.

## Simplify

Four agents (reuse, simplification, efficiency, altitude).

| Finding | Resolution |
| --- | --- |
| `load_name/1` and `loaded?/2` were two parsers of one header | fixed: `loaded?/2` uses `load_name/1`; `header/1` and `starts?/2` removed |
| `carry_skills/2` scanned the transcript with no summary | fixed: a `nil` clause |
| the kept part was scanned before the code knew of any load | fixed, then undone in round 2: the branch made `carried/2` too complex for Credo (10, max 9); the kept part is one more pass of the transcript |
| `body/1` ran for skills that can only get a line | fixed: it runs only while fewer than 5 texts are taken |
| `with_summary/2` repeated the cut of `start/2` | fixed: it uses `start/2` |
| one `Helyx.Summary.split/2` in Core for the three cuts | skipped: it grows Core for a two-line split |
| system-prompt section in place of a message (altitude) | skipped: decision 2 of the ticket puts a message after the summary, and a changed system prompt restarts the Claude Code program (`provider/claude_code/program.ex`) |
| the summary plugin test repeats the integration test | skipped: the unit test also checks the summary input |
| the id rule is stated in three docs | skipped: each doc states its own side of it |

## Round 1 (full)

Bounds sensor (`--diff origin/master`):

```text
bounds sensor: 9 candidate functions, 0 flagged, 0 without an answer
```

Codex adversarial review: verdict approve, "No material findings."

Standards: 0 hard violations of code rules; 1 hard finding on tests (no test at the exact 32,768-byte bound); judgement calls: the header format is in the heredoc and in the regex, the split of `carry_skills/2` and `start/2`, the implicit protocol between the two plugins, the name `again`, the comment "upper bound".

Spec: 0 missing requirements of code. The `Default` moduledoc said "one line for each other skill", which the stop at the bound contradicts. Untested rules: the exact byte bound, the order of the lines and the stop, the newest load of one skill. The cost row of the bounds table was not exact.

Failure path: 0 reproduced defects. Probes: the exact bound and one byte over it (ASCII and 3-byte characters), the two plugins together with `:overflow` and a second summary, 50,000 loads in about 55 ms. Not reached: the replay of a harness after a model switch, the prompt cache, small windows.

| Finding | Resolution |
| --- | --- |
| no test at the exact bound and one byte over it | fixed: `default_test.exs`, "a text that fills the bound to the byte is carried; one byte more gets a line" |
| no test of the line order and the stop | fixed: the many-skills test checks that the lines are a run from the newest down |
| no test of the newest load of one skill | fixed: "a skill loaded twice before the cut carries its newest text" |
| `Default` moduledoc overclaimed the lines | fixed: "while the lines fit" |
| bounds-table cost row | fixed |
| name `again`, comment "upper bound" | fixed: `kept_names`, "the size of the joined text" |
| header format in two places | kept: the regex is the one parser; the heredoc writes the format |
| implicit protocol "no id means added by the ModelContext" | kept: stated in `Helyx.ModelContext` and both feature docs; every transcript message has an id (`message-identity.md`) |
| no session test that Core passes `:summary` to the ModelContext | kept: `Prepare.start/2` and `Stream.prepare/4` pass the same `opts` to both plugins, and `Helyx.Compaction.Summary` tests already depend on it |

The round reproduced no defect. The fixes are tests, docs, one rename, and one comment.

## Precommit 1

Failed: Credo, `Helyx.Skills.carried/2` cyclomatic complexity 10, max 9. All tests passed (root 744, coding_agent 82, bundled 4 properties and 1007 tests). Fix: the branch `if loads == []` before the kept names is removed, 2 lines in one file, no function added or removed: a reduced round.

## Round 2 (reduced: spec and failure path)

Invariant given to both agents: the invariant above; find another path that breaks it.

Spec: 0 defects. The fix does not change the result. One stale row from before #745: the bounds row of `Helyx.Tool.transcript/0` said "the whole transcript"; fixed to the kept part.

Failure path: 0 reproduced defects. Probes through `Helyx.Session.Stream.prepare/4` with both plugins: a second summary with `:overflow`, a 2-byte body at the exact bound and one character over, 20 user loads of about 900 KB in 58 ms. Not reached: a steer between a call and its result, the replay of a harness, the prompt cache, a resumed session, small windows. The Simplify row of this record was stale; fixed.

The round reproduced no defect, so the loop ends.

## Guarantee table

| Guarantee | Proof |
| --- | --- |
| an added message has no id and goes in front of the first kept message | `default_test.exs`, "the skills of the summarized part go in one message …" |
| texts newest first; `/name` arguments stay out | same test |
| no summary, or an unknown first kept id: no change | "with no summary, or no load before the cut, the messages do not change" |
| a load after the cut, an error result, another tool: not carried | "a skill loaded again after the cut, …" |
| at most 5 texts; a text over the bound gets a line | "at most five bodies, then one line per skill; …" |
| at most 32,768 bytes; lines newest first; stop at the first line that does not fit | "the message is at most 32768 bytes with many skills" |
| exact bound and one byte over | "a text that fills the bound to the byte is carried; …" |
| newest load of one skill | "a skill loaded twice before the cut carries its newest text" |
| the summary plugin keeps the message after its summary, and not in its input | `summary_test.exs`, "a later summary covers the messages since the last one and updates it"; `default_test.exs`, "the summary plugin keeps the message after its summary" |
