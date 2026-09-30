# Review: #274, "a second subscribe replaces the watch" races the Registry cleanup

Scope: `git diff origin/master` on `ticket/274-watch-registry-race`. The test now asserts that exactly one live watch, the second, is under `{Helyx.Session.Watch, id}`. It filters `Registry.lookup/2` to live pids, because the lookup keeps the entry of the killed first watch until the partition handles its `:EXIT`, and the test's `:DOWN` does not order that.

## Checked names

- The test, the `watches/2` helper, and the failed assertion exist as the ticket states.
- Elixir 1.19.5 `registry.ex`: `lookup/2` reads the key ETS table only, with no liveness check (line 660). The partition removes the entries of a dead process in `handle_info({:EXIT, pid, _}, ...)` (line 1784).
- Red before the fix: with the Registry partition suspended across the kill and the second subscribe, the old assertion failed with two entries, and the filtered assertion passed.

## Other lookups after a death

Every `Registry.lookup/2` and `watches/2` site in `test/`, `plugins/bundled/test`, and `apps/*/test` was checked. Line 51 and the `watches == []` checks at 1946 and 2016 wait with `await/2`. Lines 740, 2079, 2112, and 2158 read a live process. Line 2100 reads after the old watch died, but the partition kill in that test drops the key table (the partition creates it in `init/1`), so the old entry cannot be there. No other site has the race.

## Simplify

- Reuse: none.
- Simplification: delete the new assertion, or `await/2` until the lookup holds only `second`. Skipped: `Registry.values/3` checks the caller's key, not the watch key, and a wait tests the Registry cleanup, which is not the property (the ticket).
- Efficiency: none.
- Altitude: the filter must not move into `watches/2`, because the `watches == []` waits check that the entry left.

## Round 1 (full)

Bounds sensor: `bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | wait with `await/2` for the stronger property (judgement call) | kept: the cleanup timing is not the property |
| Standards | a `live_watches/2` helper, and the name `live` (judgement call) | kept: one use |
| Spec | line 2100 may have the same race | not a defect: the partition kill replaces the key table |
| Failure path | none; the filter still fails on two live watches and on no new watch (mutations reproduced), 20 of 20 repeats pass | none |
| Codex | approve, no findings | none |

No round reproduced a defect, so the loop ends after round 1.
