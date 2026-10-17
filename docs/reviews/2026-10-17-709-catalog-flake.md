# Review: #709, the catalog fetch deadline test fails under load

Scope: `git diff origin/master` on branch `ticket/709-catalog-flake` (base `52064784`). The test "the whole fetch has a deadline; the Task is killed and the last good copy stays" of `plugins/bundled/test/helyx/model_info/catalog_test.exs` sets `fetch_ms: @load_ms` (300 ms), not 50 ms. `catalog.ex` is unchanged.

## Measured cause

- A copy of the test file in `.scratch/` with `fetch_ms: 1` failed 3 of 3 runs with `Assertion failed, no matching message after 30000ms` at `assert_receive {:fetch, task, conn}` (`await_refresh/0`, line 61), the failure of the ticket.
- A probe of 20 refreshes in one VM, from the lookup to the plug: with `fetch_ms: 1`, 14 of 20 reached the plug (0.9 to 1.9 ms) and 6 of 20 ended at the deadline with no plug call. With `fetch_ms: 50`, 20 of 20 reached the plug (0.8 to 1.3 ms) and ended at 51 to 54 ms.
- The failure-path agent measured the first fetch of a new VM: 15.0 to 18.3 ms in 5 of 5 runs, because the VM loads the Req and Plug modules.

So the deadline kills the Task before it reaches the plug, the plug sends no `{:fetch, ...}`, and the test waits 30 s. The refresh ends at the deadline and keeps the last good copy: `catalog.ex` does what its contract says. The test asserted an upper bound of 50 ms with no margin for load.

## Simplify

Four agents (reuse, simplification, efficiency, altitude). Fixed: the comment for the new use moved from the `@load_ms` attribute to the line that uses it. Altitude: the second option of the ticket (no plug message) has no sync point, because `await_end/0` needs the refresh to hold its name, and the refresh registers after the lookup returns.

## Round 1 (full)

Bounds sensor, base `origin/master`: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`

Codex adversarial review, working-tree scope: `Verdict: approve`, "No material findings."

| Source | Finding | Resolution |
|---|---|---|
| Failure path | The comment said "about 1 ms with no load"; the first fetch of a new VM takes 15 to 18 ms. Reproduced (5 of 5). | Fixed: the comment states 20 ms for the first fetch and 1 ms after it. |
| Standards | Judgement: `@load_ms` now has two uses, a refute margin and a deadline that must not come first; its comment at the attribute names only the first. | Kept: the comment at the deadline line states the second use. One margin for load in the file. |
| Standards | Judgement: the comment wording was not one statement per sentence. | Fixed with the row above. |
| Spec | None. The reproduction with `fetch_ms: 1` failed 2 of 2 runs at line 61. The test still proves the deadline: with no deadline `await_end/0` fails at 30 s, with no kill `refute Process.alive?(task)` fails. | n/a |

Round 1 reproduced no defect, so the loop ends. The comment fix is wording only.

Accepted hole: a load that holds the fetch Task more than 300 ms before the plug still fails the test with the 30 s wait. The refute margins of the file accept the same bound.
