# Review: the order of a Claude Code replay (#248)

Base: `origin/master` at `d065f38`. Invariant: each replayed line after a `shouldQuery: false` user line, and the turn's line, go to a fresh `claude` program only after the `result` of that user line. So the program writes its session and the model request in the input order.

## Simplify

- The user lines were found by their bytes through a `MapSet` of every user line, also the lines that the cap cut. Fixed: `cap_replay` keeps a suffix of the lines that are not `false`, so the kinds of that suffix pair with the kept lines.
- `replay?` was found by a compare with the turn's line alone. Fixed: `replay/2` returns whether it kept lines, as before.
- The `cond` with `hd`/`tl` became a clause that matches the held chunks (the field `chunks`). Then the standards axis merged the two `result` clauses into one `case`. The rebase onto #246 replaced that clause (see round 2).

## Round 1 (full)

Bounds sensor: `bounds sensor skipped: TYPESAFE_API_KEY is not set`.

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Standards | Two `result` clauses repeat the `msg_lifecycle_v1` check; one sentence of the feature doc is not plain; the order test needs `perl` | Merged into one clause; sentence rewritten; `perl` accepted (the watchdog needs it too) and named in the test comment |
| Spec | Moduledoc does not say where a steer goes while a replay is held; the order test checks only the second chunk; the feature doc does not list a `--resume` of a session written before #248 | Moduledoc sentence added; the check runs at both replayed user lines; item added to "Not observed" |
| Failure path | None reproduced. Probes: a replay over the byte cap with multibyte text and tool calls (cut 21, order kept, chunks end at tool results); an interrupt while 2 chunks are held; two steers while chunks are held, after a failed replay `result` | None |
| Codex | Approve, no material findings | None |

Not reached by the failure path: the real program for the cases that were not observed, a program that never answers a replayed user line, a port exit or close while chunks are held, an empty user message between chunks.

The round reproduced no defect, so the loop ends. The fixes after it are wording, doc, and one judgement change (the merged clause), with the file's tests run again.

## Round 2 (reduced, after the rebase onto #246)

`origin/master` moved to `3f83767`. #246 replaced the replay `result` clause with a gate for every turn: a `result` before `started` of the turn's line is skipped with `msg_lifecycle_v1`, and stops the program without it. The merge keeps that gate. A skipped `result` also writes the next held chunk (`release/2`). The brief named both invariants and their interaction: a program turn's `result` while chunks are held must not write a chunk. Fix size: one code file and a new function, so a full round by the rules; the coordinator asked for one reduced round.

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Spec | `release/2` stood between clauses of `translate/2`: a compile warning, which fails precommit | Moved below the last `translate/2` clause; `mix compile --force --warnings-as-errors` is clean |
| Spec | A missing or null `origin` alone released a chunk; the checklist asks for the exact safe value | A chunk goes out only on `num_turns` exactly 0 and no `origin`; the feature doc says so |
| Spec | No test of a failed replay line | Test added: "a failed replay line writes the next chunk too" |
| Spec | The review record named the old base and the old clause | Fixed |
| Failure path | None reproduced. Probes: an interrupt while chunks are held; a steer, then an interrupt, while chunks are held; a `result` of the turn's own line before `started` after all chunks went out | None |

The interaction test "a program turn's result during a held replay writes no chunk" was said to fail when the `origin` check is removed. Round 3 found that this was not true, because its program result had `num_turns` 1.

The one defect of the round was a compile warning; precommit checks it. No further round ran.

Precommit: the first run failed one test outside this diff, `Helyx.Provider.FakeTest` "a bad script item fails only its own turn" (a 5 s wait for `agent_end` under load). The file passed 3 of 3 runs alone, and the second precommit run passed.

## Round 3 (reduced, after the rebase onto #241)

`origin/master` moved to `27d96d3`. #241 added `Turn.held`, the text of an error `result` held for an unresolved steer. The field of the held replay chunks was renamed from `held` to `chunks`. The brief named both invariants: a `result` that writes a chunk must not change `held`, and a program turn's `result` must change neither. `held` changes only in `turn_result/2`, after `started`; a chunk goes out only before `started`, so the two never meet.

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Spec | The program turn test used a program result with `num_turns` 1, so the `num_turns` check alone kept the chunk, and the test did not check the `origin` check | The program result now has `num_turns` 0. The test fails with the `origin` check removed, and passes with it |
| Spec | The comment of `release/2` said "no `origin`"; the code also takes a null `origin` | Comment fixed |
| Spec | The struct comment did not say that steers can follow the turn's line in the last chunk | Comment fixed |
| Spec | No test of a program turn's error `result` while chunks are held, then a steer | The steer test now sends a program error `result` and a failed replay `result` before `started`, and checks that the steer's start gives no notice |
| Failure path | None reproduced. Probes: a replay `result` with a null `origin` and `num_turns` 0; a steer, then an interrupt, while chunks are held | None |

No code defect was reproduced. The fixes are test and comment changes, so no further round ran.

## Codex gate

Round 1 on the #246 base: approve, no material findings. Round 2 after the rebase on #241: approve, no material findings.
