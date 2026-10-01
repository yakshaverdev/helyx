# 2026-10-01: decisions run

An orchestrate run after a `/hitl` session on 2026-09-30. The owner decided four tickets that the simplification run had left open (#265, #266, #269, #277). The run built three of them.

## Merged

| Ticket | PR | Change |
|---|---|---|
| #265 | #281 | The per-turn external provider mode is gone. A provider is the API kind (local loop) or the harness kind (connected). ADR 0002 and ADR 0007 amended. |
| #266 | #283 | The session file is read as a tree by `parent_id`. Two servers that write one session make two branches that never mix. Repair never truncates. ADR 0001 amended; SQLite and locks declined. |
| #269 | #284 | A resume writes nothing. The reader inserts an `aborted` result after each tool call that has none. |

## Owner decisions

- #265: remove the mode. The owner's model is two kinds: API providers (for now OpenAI-compatible) and harnesses (Claude Code and Codex).
- #266: keep JSONL and read it as a tree. A move between laptop and phone uses one server with a second client (ADR 0006) and must stay resumable. SQLite was declined: a native dependency, a migration, and a file that is not plain text.
- #269, first: fail the resume when its write fails. Then a fourth round. Then, after the owner asked why Helyx writes the aborted results at all: derive them on read and never write at resume.
- #277: an agent reproduces and fixes it.

## #269: four rounds on a write that did not need to exist

The first approach made the resume fail when its write failed. That freed the session id, and each round then found another race between the resume and a change to the file on disk: a stale concurrent resume that appended twice (Codex gate), a torn line (round 2), a header checked on a second open (round 3), and the cwd checked on the scan bytes and a file replaced after the read (round 4). The orchestrator tightened the invariant each time and never asked whether the write was needed. The owner asked. The results can be derived on read, so the write, its failure, and every race went away in one ticket with two review rounds.

System change: the two-findings rule in the ship skill and in the checklist now asks first whether the mechanism can be deleted, for example a stored value that can be derived on read.

## Escapes

| Ticket | Codex | System change |
|---|---|---|
| #269 (first approach) | gate r1: 1 confirmed | The two-findings rule asks whether the mechanism can be deleted |

#265, #266, and #269 (second approach) had no Codex finding in the gate.

## Not built

- #277 went back to `needs-info`: 20 of 20 runs of each candidate test and 8 of 8 runs of the file passed, and the analysis found no timing assumption that fails. Keep `precommit.log` when it fails next.

## New tickets

- #282 (`needs-triage`): two branches can continue one Claude Code or Codex harness session. It existed before #266.

## Next

- Group 3 of the simplification review: the `harness_reply` kind change, then the Steers and Wait extraction from `Session.Server`. No tickets yet.
- GitHub closes an issue from "Closes #n" in a merged PR body: #282, #287 and #288 closed with no manual step, and #282 lists PR #290 as its closing PR. A closed event shows the account that merged as its actor, so the actor does not show a manual close.
