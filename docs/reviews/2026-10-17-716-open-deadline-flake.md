# Review: #716, the open deadline test of concurrent resumes fails under load

Scope: the working tree on branch `ticket/716-open-deadline-flake` (base `21727f9f`). The test "both get :open_timeout when the open is killed" of `test/helyx/sessions_test.exs` kills the session process itself once the second start is in its mailbox, and `held_pair/2` takes no bounds. `lib/` is unchanged.

## Measured cause

- A copy of the test in `.scratch/` with the deadline in an environment variable. With `open_ms: 100`, 1 of 1 runs failed with `timed out waiting for the attach` at `held_pair/3`, the failure of the ticket. With `open_ms: 1`, 2 of 2 runs failed earlier, at `assert_receive {:in_open, pid, t_in}` after 30,000 ms: the kill came before the perl lock take ended. With `open_ms: 150`, 1 of 2 runs failed the same way.
- With `open_ms: 25_000`, 21 runs measured the two parts that the deadline must outlast. From the start to `{:in_open, _}` (the lock take): 12 to 198 ms. From `{:in_open, _}` to the `:live` call in the mailbox: 1 to 417 ms. The sum reached about 470 ms, against the 500 ms of `@load_open_ms`.

So the deadline counts from before the lock take (`open_file/2`), and it races the second start. When the kill comes first, the queue never holds the call, and `await/2` gives up. The open does what its contract says: no defect in `lib/`.

## Fix

The test sends `Process.exit(pid, :kill)` after the attach is in the mailbox: the same signal as `kill_after/1`, with no race. `test/helyx/session/lock_test.exs:289` and `:301` still run the real deadline. `docs/features/session-lock.md` states that any kill of the session before its open result gives `:open_timeout`, which this test now checks directly.

A mutation that removes the `:killed` clause of `attach/3` (`server.ex:51`) passed the old test and the new test without the refute: the second start runs again, its open blocks, and its own deadline (25,000 ms) also gives `:open_timeout` inside the receive timeout (30,000 ms). `refute_received {:in_open, _}` fails that mutation. In correct code no second `{:in_open, _}` is sent, so the refute cannot flake.

## Simplify

Four agents (reuse, simplification, efficiency, altitude). Fixed: a shorter test name that fits one line and is accurate (no deadline runs), and a shorter comment. Reuse, efficiency, altitude: clean. Altitude names the 500 ms margin of the lock_test deadline tests, see the accepted hole.

## Round 1 (full)

Bounds sensor, base `origin/master` (`a5cb1700`, ahead of the branch base, so it also saw #711 in reverse): `bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer`. Rerun with base `21727f9f`: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`

Codex adversarial review, base `origin/master`: `Verdict: approve`, "No material findings." It reviewed the uncommitted test change.

| Source | Finding | Resolution |
|---|---|---|
| Standards | Judgement: in the first comment, "which" can refer to the kill or to the deadline. | Fixed: two direct sentences. |
| Standards | Judgement: the comment of the refute depends on two bounds (25,000 ms and 30,000 ms) that it did not state. | Fixed: the comment states both and that only this line sees a run again. |
| Standards | Judgement: `refute_received` reads a message of another sender. | Kept: in correct code no such message exists, so it cannot flake; it can only miss a regression, where the message comes 25 s before the result. |
| Spec | None. The real deadline stays tested in lock_test.exs; the guarantee row of `2026-10-17-657-server-management.md` now has two parts: the deadline kill (lock_test) and the kill to `:open_timeout` for every caller (this test). | n/a |
| Failure path | None. 21 of 21 runs passed; a probe in which the second start runs again showed that only the refute catches it (11 of 11). | n/a |

Round 1 reproduced no defect, so the loop ends. The fixes are wording only.

Accepted hole: the deadline tests of `lock_test.exs` keep `@load_open_ms 500`, which also counts the lock take (measured up to 198 ms here). A heavier load can fail them in the same way. Out of the scope of #716 (the test file only).
