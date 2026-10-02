# 2026-10-02: precommit speed (#295)

`mix precommit` took 189 s on master (warm, 10 cores). The goal was 20 to 25 s, with every test kept and no production bound changed.

## Done

- The root `precommit` alias runs every project in parallel. Each project runs `deps.get --check-locked`, format, and compile, then its checks in parallel: Dialyzer and test, and Credo in the root. Each step is its own `mix` process. When it ends, it prints `==> precommit <project>: <command> (<seconds> s)` and its output, so a step that hangs does not hide the others. The plugin and app projects have no `precommit` alias now.
- Dialyzer: `--force-check` checked all 1,184 PLT modules in each project (about 25 s). Now the path dependencies stay out of the PLT (`plt_ignore_apps`) and their beams are analyzed on each run (`paths`). A probe confirmed that Dialyzer still reports a bad call into `helyx`. The list of path dependencies comes from `deps()`. Each project has its own core PLT folder in the Mix home, because Dialyxir writes a core PLT with no lock and the three Dialyzer runs are parallel. The first run on a machine builds three core PLTs once.
- Credo and Dialyzer run under `nice`, so the tests, which wait on timers, get the CPU first.
- Two tiers. 29 tests that wait one second or more of real time, and the code-point scan, have the `:slow` tag. `HELYX_SLOW=1` includes them. `/ship` and the merge gate of `/orchestrate` set it through `precommit.sh`, so every commit runs the full suite. The fast tier runs 25 StreamData cases for each property.
- `CodexTest`, `ClaudeCodeTest`, and `SessionTest` are split into 25 async modules with shared support modules. The test count and the test bodies did not change.
- The provider tests no longer change PATH. `test_helper.exs` of `plugins/bundled` writes a dispatcher folder first on PATH. Its `claude` and `codex` run `../bin/<program>` from the session's working directory. The four tests that need a changed PATH are in the sync module `Helyx.HarnessIO.PathTest`. This replaces the ticket's plan of a program path option in `HarnessIO.find/1`, so no production code changed.
- The code-point scan is its own module, with `parameterize:` over its 13 contexts.
- Every test wait is now safe under the parallel load. The owner's order: no commit while a test can fail at random; speed can come later.
  - A wait that must happen has one cap, 30 s: `assert_receive_timeout` in the three `test_helper.exs` files, read by `Helyx.Test.Events.wait_ms/0`. It replaces the 1 to 5 s literal caps in `assert_receive`, `receive ... after`, `Task.await`, `Task.yield`, and the support helpers. Only a failing test waits this long.
  - A wait for a kill (`gone_within?/2`) has its own cap, 10 s, a deadline in monotonic time. The test programs sleep 30 s or more, so a program that ends by itself does not pass as killed.
  - A check that a wait must not happen uses order where it can: the sweep tests and the parallel release test in `hands_test.exs` use `Helyx.Test.Gate`, and the hold tool of the test provider takes a `%{"gate" => g}` handle. The other checks have a margin in a `@load_` attribute, far below the wrong case.

## Measurements

| Run | Time |
|---|---|
| master | 189 s |
| local laptop, fast tier, 8 runs at 16:54 local time | 21 to 23 s |
| local laptop, fast tier, 3 runs at 17:31 to 17:36 | 28 to 39 s |
| local laptop, fast tier, 3 runs at 18:22, no other test run on the machine | 33 to 35 s |
| local laptop, `HELYX_SLOW=1` | 37 to 43 s |
| precommit host, fast tier, 6 runs | 22 to 24 s (2 failed, see Risks) |
| precommit host, `HELYX_SLOW=1`, 2 runs | 39 to 40 s |
| precommit host, fast tier, 10 runs after round 4 | 21 to 25 s (1 failed: the watch race) |
| precommit host, `HELYX_SLOW=1`, 3 runs after round 4 | 37 to 41 s |
| precommit host, fast tier, 10 runs after the watch fix | 22 to 25 s, all passed |
| precommit host, `HELYX_SLOW=1`, 3 runs after the watch fix | 40 to 41 s, all passed |

The laptop ran on battery with Low Power Mode for all these runs. An earlier version of this log said that the slow runs were on battery and the fast runs on mains power. That was wrong: the power state was read only once, at 17:07. On the laptop, every step of the 18:22 runs took 1.6 to 1.8 times as long as at 16:54, also Dialyzer and Credo, whose inputs did not change. The cause is not known. `fileproviderd` used one core of ten during the 18:22 runs. The precommit host gives stable numbers; use it to compare.

The critical path is the bundled test step (about 13 s alone, 20 s in the parallel run). Its async phase takes 10.7 s, but its longest module takes 3.6 s, so the modules wait on a shared resource. That is not yet known.

## What broke

- The root Credo check tests failed in the parallel run. Before, the `mix credo` step in the same VM had started Credo. Now `test_helper.exs` starts it once. A start in a module's `setup_all` ended with that module.
- `Helyx.Session.HandsTest`: a race, 1 in about 10 runs. `await_held/2` counted tasks, but the hold tool holds its two handles in two calls. A cancel between them released only the first. It now counts handles.
- `max_cases` at 10, 20, and 40 gave no gain, so it is the default again.
- Change 7 of the ticket (a short timeout argument) had no target. No Core API that a slow test calls has a timeout argument, so those tests have the `:slow` tag.
- The first `HELYX_SLOW=1` run of `/ship` on the precommit host failed two tests:
  - `test/helyx/session/file_test.exs:729` waited 5 s for a resume that takes 2.1 to 2.2 s alone. It now uses the one cap of 30 s.
  - The TUI test "a frame before the Resize event wraps only the cells on the screen" counted 953 calls of `TUI.item_lines/2`, not at most 5. `:call_count` counts for the whole VM, and the code-point scan, now its own async module, calls the same function at the same time. The test now draws the frame in its own process and traces only that process. A process that traces its own calls counted 0, so the check is now `wraps in 1..5`.
  - Round 3 of the review found a test in `loop_test.exs` that made its folder in the shared OS temp folder with a counter that repeats across runs. A folder that a killed run left made it fail. It now uses `@tag :tmp_dir`. Two waits got a stated load margin: the `:DOWN` wait in `claude_code/limits_test.exs`, and the grace test in `watchdog_test.exs`.
- Round 4 found tests that no longer failed on their bug, and the new full run found one more failure:
  - The 30 s cap of `gone_within?` was as long as the `sleep 30` of the test programs, so a watchdog with no KILL passed. The cap is now 10 s. A probe that removed the KILL failed the test.
  - `sweep_test.exs` did not assert the result of `set_model`. A probe that blocked `set_model` during a sweep passed. Now every call must answer, and the probe fails.
  - "no wait passes the deadline" in `group_test.exs` passed with a TERM grace that ignored the deadline (451 ms late, inside the 2,000 ms margin). It now uses a 10 s grace.
  - The order test of `harness_tools_test.exs` selected the result of `c1` from the mailbox, so it did not check the order. It now takes the results in their order.
  - "a longer grace holds the KILL until its limit" found the group gone at its check at 1 s of a 2 s grace, in a full local run with the slow tier. The watchdog counts 40 waits of at least 50 ms, so the KILL cannot come early: the check ran more than 1 s late. The grace is now 10 s, the wait for the KILL 20 s, and the program sleeps 60 s.
- The acceptance after round 4 (10 fast and 3 `HELYX_SLOW=1` runs on the precommit host) failed once in 13: the TUI test "a lost subscription rebuilds the view from a new snapshot" got `{:error, :session_not_found}` from the subscribe after the lost signal. The cause is in production code, older than this ticket: `Helyx.Session.Watch` sent the lost signal after an answer of the Registry supervisor, and assumed that the supervisor had the exit of the partition before the call of the watch. Signals from two processes have no order, so under load the supervisor can answer before it restarts the partition. The watch now checks that the supervisor lists a live partition that is not the dead one (`docs/features/end-signal.md`, "The watch"). A new test in `end_signal_test.exs` sends the exit to the watch while the partition still runs; it fails on the old watch.

## Risks

- The tests now share the CPU with Dialyzer and Credo. A test with a fixed wait can fail under load. Seen:
  - `Helyx.Watchdog.HarnessStopTest`, the stdin cap flood: "no agent_end" after 5 s. It failed in the first cold run and in 2 of 5 runs on the laptop. Alone it takes 0.4 s, and 1.0 s under load from other projects. It fails only with the bundled suite at the start of its async phase.
  - `Helyx.Tool.BashTest`, a non-zero exit code: "no tool result" after 5 s, once on the laptop.
  - `test/helyx/tool/read_test.exs:219`: 2.4 s against its 2 s margin, once in the first cold run.
  - `Helyx.Watchdog.GroupTest`, "a retry KILLs every group and probes once, with no wait": 524 ms against its 250 ms `@load_ms`, once in 6 fast runs on the precommit host. Of the 6 runs, a second one also failed; its log was lost. The test now has no time bound: the list of kill runs shows that no wait polled.

  All of these now use the one cap or a wider stated margin. Holes that stay: a short `refute_receive` window can pass wrongly under load, but never fail a correct run; `limits_test.exs` catches its bug only while the decode of the queued lines takes over 1 s; `read_test.exs` keeps a 10 s sanity bound.
- Two worktrees that run Dialyzer on one project on a machine with no core PLT can write that project's core PLT at the same time. Dialyxir has no lock. On master all projects of all worktrees shared one core PLT, so this hole is not new. It opens after an OTP or Elixir upgrade, and once after this change, until one run fills the new folders. Dialyxir reads the core PLT only when it builds a project PLT. On the local machine, one run with no project PLTs filled the three folders before the merge (213 s). On the precommit host, the folders fill at the first run that builds a project PLT there. A core PLT in each `_build` closes the hole, but a cold build takes 87 s and 252 CPU-s for each project, so each new worktree would pay that three times.
- Only a commit that does not go through `/ship` can skip the slow tier.

## Next

The investigation of the speed is #296.

- Find the shared resource that the bundled async modules wait on. A candidate: the one `erl_child_setup` of each VM, which starts every port in turn.
- The fake `codex` starts one `perl` for each input line, about 18 ms each. One perl for each run would remove about 500 starts.
- Dialyzer analyzes `helyx` three times and `helyx_plugins` twice in each run, about 16 CPU-s.
- Small follow-up: `final_text/1` in `test/helyx/session/harness_test.exs` repeats the helper of `Helyx.Test.SessionCase`.
