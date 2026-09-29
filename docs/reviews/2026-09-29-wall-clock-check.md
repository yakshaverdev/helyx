# Review: a mechanical check for wall-clock upper bounds (#221)

Base: `origin/master` at `09d22d7`. Three rounds. Round 3 still reproduced a defect, so the loop stopped at the limit and the defect is open (see "Open").

## Change

The Credo check `Helyx.Credo.WallClockUpperBound` in `credo/wall_clock_upper_bound.ex`. `.credo.exs` loads it with `requires` and adds it to `checks.extra`. The root `mix credo --strict` in `mix precommit` covers `lib/`, `test/`, `plugins/`, `apps/`, and `credo/`, so it covers `plugins/bundled` too. A `mix precommit` in `plugins/bundled` alone does not run Credo (as before). The check is not compiled into the project. Its test loads it with `Code.require_file/2`.

The six upper bounds that the check found on master:

- `test/helyx/session_test.exs`: `@budget_ms 400` is now `@load_ms 400`, with a comment that states the margin against the 800 ms sweep. The expected time of the calls is near zero, so the whole bound is the margin.
- `test/helyx/session/hands_test.exs`: the grace test and the retry test assert a lower bound and `< deadline + @load_ms` with `@load_ms 1_000`. The retry handle grew from 1 500 ms to 5 000 ms, so a retry that waits for the release still fails. The "just past the deadline" test keeps its 350 ms handle and has no time bound: a kill after the end of the release confirms the handle, so the error text shows that the kill came first.
- `plugins/bundled/test/helyx/tool/read_test.exs`: two `micros < 2_000_000` are now `micros < @load_us`, with a comment.

Invariant: every `assert`, `refute`, or `assert_in_delta` in a `test`, `def`, `defp`, `setup`, or `setup_all` scope that bounds a time value from above is reported, unless the bound references a module attribute whose name starts with `load_`. The check sees one file of syntax. It cannot follow a time value through a `case` clause, a message, a process, another module, a function parameter, or a pipe into the operator. It can report too much: a name is a time value in its whole scope, and a comparison of two time values is reported.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

Simplify (four agents): one fix, `Credo.Code.Module.def_name/1` in place of a local helper. Skipped: a shared fixpoint helper, a single `time_call?` clause, a helper for the hands_test asserts (it would hide the bound from the check), and a worklist in place of the fixpoint (sub-second at this size).

Standards: judgement calls. Fixed: `credo/` added to the path exception in AGENTS.md, the names `time`, `l`, `r`. Kept: the `@load_ms` rename in `session_test` and `read_test` (the expected time is near zero, so the bound is the margin).

Spec: no missing item. `group_test.exs:71` compares timestamps from messages; its comment shows that load cannot fail it, and it is a stated hole. The plugins project has no Credo of its own, as before.

Failure path: 3 reproduced. (1) The hands_test "just past" test lost its "one over" case with a 5 000 ms handle: a kill 100 ms late passed. Fixed: back to 350 ms, no time bound. (2) An order of two times was reported. (3) The result element of `:timer.tc` was a time value. Also `assert_in_delta` and the prefix `loaded` were holes.

Codex: 2 reproduced. `not` did not turn the assertion around. The `:timer.tc` result was a time value.

Fix: `not` and `!` turn the operator, only the first element of `{elapsed, result} = :timer.tc(...)` is a time value, `assert_in_delta` is checked, the prefix is `load_`, more time calls, and a comparison of two time values was allowed as an order.

## Round 2 (full: new functions)

Simplify: no fix. Skipped: a prewalk in place of the recursive `bounds/2` (a prewalk cannot turn the operator only below a `not`), a per-call result position for `:timer.tc` (one call needs it).

Standards: judgement calls only, no fix.

Spec, failure path, and Codex: reproduced. The order exception let a deadline such as `start + 300` pass (a second finding on the order mechanism, so the mechanism was removed). `assert_in_delta` with the time value second passed. `with {_t, n} <- :timer.tc(...)` took `n` as a time value. `Kernel.<` passed.

Fix: the order exception is removed (a true order uses `# credo:disable-for-next-line`), both value arguments of `assert_in_delta` are checked, `Kernel.<`, `<=`, `>`, `>=` calls are read as operators, the `:timer.tc` clause covers `<-`, and the doc states the holes that report too much.

## Round 3 (full: more than 15 lines)

Simplify: two cosmetic findings, skipped.

Standards: two duplicated literal lists, judgement calls, not fixed at the limit.

Spec, failure path, and Codex: reproduced. A qualified spelling of an operator hides a bound: `Kernel.not(elapsed >= 5)`, `Kernel.!(...)`, `Kernel.in(elapsed, 0..5)`, `:erlang.<(elapsed, 5)`, `:erlang.not(...)`. `assert (elapsed >= 5) == false` is an adversarial form.

## Open

Round 3 reproduced a defect, so it is not fixed here. This is a second finding on the operator-spelling mechanism. The fix of the mechanism is one clause in `bounds/2` that rewrites a `Kernel` or `:erlang` remote call to its local form, so that `not`, `!`, `in`, and the comparisons all go through the same clauses. `== false` can be a stated hole. No such form is in the repo today (the check reports no issue on master plus this change).

## Orchestrator decision on the round 3 defect

Accepted hole, not fixed: a bound written as a named operator call (`Kernel.not/1`, `Kernel.in/2`, `:erlang.</2` and the like) passes the check. The check is a lint for honest mistakes in tests, not a boundary against a hostile author; no test in the repository uses these forms. A form that `mix format` and Credo accept as normal style is in scope.
