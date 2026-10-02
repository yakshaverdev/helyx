# 2026-10-02: precommit investigation (#296)

Worktree: `../helyx-296`, branch `investigate/296-precommit`, base `58471ac`.
All raw logs and probe scripts are in `.scratch/296/` in this worktree.
No production timeout, grace, or cap changed. No test was removed.

Latest result: the patch passed ten fast and three slow host runs, but the
requested battery check missed the 25-second target in all three runs:
28.45, 31.88, and 26.46 s. All tests passed. Low Power Mode was enabled.
The earlier AC result does not establish the battery target. See "Battery
verification requested by the user" below. The user accepted this timing and
requested a commit and PR. Earlier results remain in this record.

## Measurements and method

Use the configured precommit host without recording its address. The initial
cold build took 239.28 s. Keep that outside the warm measurements. Every run
has its full log. Runs of `precommit.sh` include SSH and file transfer. Direct
remote `mix precommit` measurements do not. Do not compare those totals.

The first local baseline passed in 40.87 s at 19:43, on battery with Low Power
Mode enabled. The first parser run passed in 35.13 s. These are observations,
not a controlled speed comparison.

Later runs had other work on both machines. At 20:04 a test VM in another local
worktree was active. At 20:07 the host had three active Dialyzer VMs in another
worktree. This establishes overlap, not the cause of every timing difference.

## 1. What the bundled async modules wait on

Three warm baseline `precommit.sh` runs passed: 22.50, 22.02, 21.58 s.
The standalone suite with seed 296 took 11.7 s: 8.4 s async, 3.2 s sync.
A separate OTP trace session avoids interfering with tests that use tracing.
The first probe used the default trace session and caused three tracer
conflicts. Its log is retained. The corrected probe passed all tests.

The corrected probe counted 263 Perl ports, 385 kill ports and one Elixir
port. It also started 206 `true` commands to measure launch delay. `true`
took 0.594 ms median at idle and 1.381 ms median during tests (4.997 ms p95,
12.107 ms maximum). The sum of time inside `open_port/2` was below one second.
These measurements do not support a multi-second port-start serialization
bottleneck. They do not count subprocesses that shells start inside ports.

An OS exec trace counted 405 JSON::PP parser starts. Stack samples found
Codex handshakes, provider event waits, GenServer calls, and the ExUnit
concurrency gate. Module duration is not suite duration: the suite has 16
async slots, many modules, test-file loading, and modules that start late.
The longest module in this sample was WatchdogTest at 5.15 s. Summed module
time was 71.07 s. The earlier estimate that the suite should end at the
longest module omits these constraints.

## 2. One parser per fake Codex run

Bash process substitution runs one streaming Perl parser. The shell loop
stays in the main shell. This preserves `$$`, exit codes and TERM traps in
the existing fake scripts. Perl flushes each header and original input line.
The shell still records the original line before running its response script.

The same OS exec probe counted 91 JSON::PP starts, down from 405. No other
fixture script changed. All 83 Codex tests, including the slow tests, passed
locally. The standalone async phase changed from 8.4 s to 7.9 s. Full host
precommit totals were 24.04, 22.92, 21.03 s. This does not establish a total
speed gain by itself.

## 3. Fewer OS poll processes

A 50 ms interval reduced calls from OSHelpers.os_alive?/1 from 179 to 79.
The cap stayed 10 s. The standalone async phase stayed 7.9 s. Full host
precommit totals were 22.16, 23.46, 22.56 s. No clear gain. Reverted. PID-file
polling and all production polling stayed unchanged throughout this probe.

## 4. Shared PLT

A scratch prototype used a locked build of a shared PLT that held the Core
and bundled production beams. It took 7.32 s to build. Three warm analyses:

| Project | Current PLT, analysis seconds | Shared PLT, analysis seconds |
| --- | --- | --- |
| Root | 2.768, 2.715, 2.719 | 4.239, 4.251, 4.280 |
| Bundled | 4.648, 4.774, 4.741 | 4.229, 4.240, 4.240 |
| App | 4.476, 4.484, 4.492 | 3.825, 3.779, 3.837 |

The root has no reason to use the larger PLT; that row is a control. The
largest dependent-project saving is about 0.7 s. A bad call into
Helyx.Session.prompt/2 still produced a Dialyzer failing-call warning.
Rebuilding the prototype after Mix reconsolidated protocols failed on a
missing consolidated BEAM referenced by the original dependency PLT. A
correct cache also needs content invalidation and stable input paths. Keep
separate PLTs. The small warm gain does not justify that machinery here.

## 6. Scheduling and new failures

Direct host `mix precommit`, with the parser change:

| Probe | Seconds | Result |
| --- | --- | --- |
| Two schedulers for static checks only | 20.30, 18.03, 17.86 | Pass |
| Two schedulers for all VMs, 16 test cases | 19.11, 20.93, 18.07 | Pass |
| Four schedulers for all VMs, 16 test cases | 18.59 | App failure |
| Tests after static checks | 23.97, 22.59, 24.32 | Pass |

The failure read a corrupt consolidated `List.Chars` BEAM in the graph task.
Dialyxir 1.4.8's `Project.cons_apps/0` calls `Mix.Task.run("compile")` during
its PLT check, even with `--no-compile`. A trace confirmed one compile call
with that option, and none with `--no-compile --no-check`. The prepare step
must check the PLT first. The parallel analysis can then skip the completed
PLT check. Task lookup can also load and compile dependencies before the
task receives its flags. Explicit `loadpaths --no-deps-check` prevents that
second route after preparation has validated and compiled dependencies.

One local prepare failed in Hex 2.4.2's `Registry.Server.persist/2` with
`:eaccess` for the shared `~/.hex/cache.ets`. Hex writes it with
`:ets.tab2file/3`. Other worktrees use the same cache. This is separate from
the protocol-file failure. Preserve the log and distinguish a dependency
cache failure from a failed test.

## 5. Slow-tier inventory

Measured on the host with seed 296, after the parser change. The root suite
passed in 17.6 s. The bundled suite passed in 27.8 s. Durations below include
setup and assertions. Fixed waits are stated separately. No waits changed.

| Test | Measured seconds | Wait and replacement assessment |
| --- | --- | --- |
| Session.HandsTest: a retry has a deadline of one second | 1.103 | 100 ms release plus 1 s retry deadline. Keep the real deadline check. |
| Session.PersistenceTest: the session supervisor after a resume (#103) keeps no copy after a start and after a failed start | 1.996 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Session.PersistenceTest: the session supervisor after a resume (#103) keeps no copy when the caller dies during the start | 1.224 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Session.FileTest: a file of many short lines is not split into a list of all of them | 2.769 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Session.FileTest: the heap cap of the decode a text-heavy session near the file limit fits the default cap | 1.143 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Session.EndSignalTest: the end signal (#189) a restart of the events Registry (registry) gives a lost signal, and the session runs | 5.616 | 5.5 s negative window, then 50 ms. Must exceed the old 5 s timeout; a shorter gate loses that regression. |
| Session.HarnessTest: idle close is never sent while a turn runs, and the idle time starts again at its end | 5.002 | 3 s negative window plus a 2 s idle timeout. Keep the stated 1 s load margin. |
| Session.HarnessTest: failures a prepare that blocks is killed at the bound and keeps the harness process | 2.003 | 2 s test option. Its load margin also protects the following successful turn. Keep it. |
| Session.EndSignalTest: a session that is not running (#188) a subscribe that times out leaves no entry | 5.002 | 5 s API timeout. Keep the real timeout; no test-only production option. |
| Session.EndSignalTest: the end signal (#189) a restart of the events Registry (partition) gives a lost signal, and the session runs | 5.603 | 5.5 s negative window, then 50 ms. Must exceed the old 5 s timeout; a shorter gate loses that regression. |
| Provider.ClaudeCode.LimitsTest: the replay cap history lines of exactly 400,000 bytes all go; one byte more cuts | 2.939 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Provider.ClaudeCode.ReplayTest: a replay writes the lines after a replayed user line only at its result | 2.622 | Two 1 s negative input polls. A gate could coordinate replay chunks, but must prove no early input at both points. |
| Provider.ClaudeCode.LimitsTest: lines of 16 MiB and one byte under are read | 0.563 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Provider.ClaudeCode.LimitsTest: a line over 16 MiB stops the provider | 0.162 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Provider.ClaudeCode.ReplayTest: a program turn's result during a held replay writes no chunk | 1.204 | One 1 s negative input poll. Same constraint: retain the failure when a program result releases replay input. |
| TUI.WidthScanTest: no grapheme is wider on screen than the width rule counts | 7.481, 7.509, 7.624, 7.655, 7.752, 7.765, 7.830, 7.862, 7.891, 7.897, 7.905, 6.212, 5.551 | No fixed wait. Full Unicode scan in 13 contexts. A gate cannot replace its coverage. |
| Provider.Codex.ConnectTest: a handshake answer with the wrong shape fails the connect | 1.032 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Provider.Codex.TurnLinesTest: a turn or item line with no string threadId stops the harness process | 1.539 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Provider.Codex.InterruptTest: a turn/completed with a status that does not end the turn stops the harness process, and a pending interrupt gets no answer | 0.547 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Watchdog.GroupTest: a longer grace waits up to its limit before the KILL | 1.001 | 1 s configured grace. A value above the default 500 ms could shorten it, but gives only a small gain. |
| Provider.Codex.HelyxToolsTest: the Helyx tools a stored id resumes only a thread with the session's tool set | 0.678 | No fixed long wait. Repeated protocol cases, file decoding, or memory checks. A gate cannot replace this work. |
| Tool.BashTest: abort kills the child of a shell that already exited | 1.046 | 1 s shell sleep gives the test time to suspend its Task. A file gate after suspension can replace this race window. |
| Watchdog.GroupTest: a group that survives KILL is still held, and the deadline bounds the wait | 1.015 | 1 s deadline and a 2 s load margin against a 5 s wrong wait. Keep the separation. |
| Provider.Codex.CommandsTest: an abort gives the program time to end its commands | 3.108 | 3 s TERM handler, inside a 5 s grace. Keep it above the shorter wrong grace and preserve time for cleanup. |
| Provider.ClaudeCode.TurnTest: an abort with work still queued stops the program with TERM after a 5,000 ms grace, and no end of input | 5.146 | 5 s production grace. The assertion checks that duration; keep it. |
| Watchdog.GroupTest: a KILL wait ends after 5,000 ms | 5.001 | 5 s production wait. Both the lower bound and final probe are tested. Keep it. |
| Provider.Codex.CommandsTest: a failed turn with an open command stops the harness process, and the next turn starts a new program | 3.132 | 3 s TERM handler, inside a 5 s grace. Keep it above the shorter wrong grace and preserve time for cleanup. |
| Provider.Codex.CommandsTest: a line over the cap while a command runs gives the program the same time | 3.072 | 3 s TERM handler, inside a 5 s grace. Keep it above the shorter wrong grace and preserve time for cleanup. |
| Watchdog.GroupTest: the watchdog is KILLed only after the command group is gone | 5.001 | 5 s fallback wait. A gate can prove ordering but does not prove the real fallback bound. |
| WatchdogTest: a longer grace holds the KILL until its limit | 10.038 | 1 s observation during a 10 s grace, then poll for KILL. Keep the 9 s load margin; the earlier 2 s version failed under load. |
| Provider.Codex.CommandsTest: an inProgress completion of a command ends the turn, so an abort sends no turn/interrupt | 3.074 | 3 s TERM handler, inside a 5 s grace. Keep it above the shorter wrong grace and preserve time for cleanup. |

## Additional incremental Dialyzer probe

OTP has native incremental analysis. A scratch probe used the same dependency
and project BEAMs and limited warnings to the same project files. On the
laptop it took 76.724 s to create its 1,184-module cache, then 2.149 and 3.077 s
with that cache warm. No warnings were reported. This needs a separate design
for cache inputs, upgrades, failure handling and warning preservation before
it can replace Dialyxir. It is not in the patch. Reference: the installed
OTP 28.5.0.6 `dialyzer_options.erl` and the
[OTP Dialyzer API](https://www.erlang.org/doc/apps/dialyzer/dialyzer.html).

## First investigation: draft and verification

At the first stop, the worktree held an uncommitted draft, not an accepted fix for #296.
It changes the root precommit runner, CodexFake, and one LoopTest:

- Check the PLT during preparation. Run parallel analysis with `--no-check`.
- Load dependencies without another check in the parallel steps. Preparation
  has already fetched, validated and compiled them.
- Disable scheduler busy waiting in child VMs. Keep the scheduler count and
  default test concurrency. An explicit `ERL_FLAGS` value takes precedence.
- Use one Perl parser per fake Codex run.
- Use the existing Gate tool to identify the running Task before killing its
  session. The old test scanned its process dictionary before the Task had
  initialized it. The new test keeps both process-death assertions.

The OS polling interval, production code, production limits and slow tags
are unchanged. No test was removed. The existing Codex tests check EOF, exit code 3, repeated
requests, asynchronous replies, aborts, TERM traps and process-group cleanup.
No commit, merge, issue edit or external message was made.

An earlier candidate, with a four-scheduler cap and before the LoopTest fix,
passed ten fast runs and three slow runs. These runs do not validate the final
draft. Every fast run
reported 386 root tests, 466 bundled tests plus one property, and 17 app tests.
Every slow run reported 396 root tests, 499 bundled tests plus one property,
and 17 app tests. The real-Claude test remains excluded as before.

| Host gate | Total seconds, including transport |
| --- | --- |
| fast | 22.97, 23.72, 37.06, 25.06, 21.44, 21.52, 28.97, 36.15, 41.92, 50.66 |
| slow | 71.15, 70.90, 76.67 |

These are reliability results under varying load. The host had other active
worktrees during part of the gate. They do not prove a speed gain over the
initial baseline.

That earlier laptop attempt also passed all tests, but missed the target:

| Run | Start, local time (UTC+08:00) | Power | Seconds |
| --- | --- | --- | --- |
| 0 (warm-up) | 2026-10-02T20:11:38+08:00 | Battery, Low Power Mode | 56.03 |
| 1 | 2026-10-02T20:12:34+08:00 | Battery, Low Power Mode | 44.61 |
| 2 | 2026-10-02T20:13:19+08:00 | Battery, Low Power Mode | 44.49 |
| 3 | 2026-10-02T20:14:04+08:00 | Battery, Low Power Mode | 30.16 |

A separate scratch reproduction of Hex's persistence call produced six
`:eaccess` errors in 90 concurrent writes, with no permission change. The
source calls `:ets.tab2file/3` on one shared filename without a lock:
[Hex 2.4.2 registry server](https://github.com/hexpm/hex/blob/v2.4.2/lib/hex/registry/server.ex#L269).
This cache race is not fixed by the candidate.

## First investigation: scheduler probe and new test race

A same-count comparison alternated the default busy-wait settings and no
busy waiting. It did not change scheduler count or test concurrency.
The direct host runs were 46.94, 55.12, 49.60, 46.59 s, in that order; all
passed. Other worktrees ran on the host during this comparison. It does not
establish a host speed gain. Local observations were 53.29, 35.20, 53.79,
29.56 s; all passed. Per the issue, these laptop numbers cannot establish
a speed gain. The scheduler change remains a draft hypothesis.

The flags are `+sbwt none +sbwtdcpu none +sbwtdio none`. They change idle
scheduler spinning, not the number of schedulers. See the installed OTP
28.5.0.6 and the [ERTS command options](https://www.erlang.org/doc/apps/erts/erl_cmd.html).

An earlier no-spin run failed LoopTest: its scan returned no Task with a
`:helyx_hands` dictionary entry. Starting a Task does not prove that its
function has run. The existing Gate tool sends its own PID after entry. The
changed test waits for that message and then makes the same session-kill and
process-death assertions. A focused run passed the initial test plus 20
repeats. All four same-count local precommits above include this fix.

## First investigation: gate and laptop check

The final host gate passed its first fast run in 19.76 s. Its second run
failed during bundled dependency preparation with Hex 2.5.1 `:eaccess` in
`Registry.Server.persist/2`. No bundled tests ran in that attempt. The gate
stopped on that failure. It did not complete ten fast and three slow runs.
Logs: `.scratch/296/final-fast-{1,2}.{log,time}`.

This is the same shared-cache failure observed with local Hex 2.4.2. The
[Hex 2.5.1 persistence code](https://github.com/hexpm/hex/blob/v2.5.1/lib/hex/registry/server.ex)
also writes one cache file. Hex has no separate `HEX_CACHE_HOME` option in
these versions. `HEX_HOME` changes the configuration location too; changing
it blindly would drop user repository and credential settings. No cache
isolation or retry was added. This requires a separate fix, not permission
changes or repeated runs until the gate passes.

Three consecutive local precommits of the final draft all passed. Each
reported 386 root tests, 466 bundled tests plus one property, and 17 app tests.

| Run | Start, local time (UTC+08:00) | Power | Wall seconds |
| --- | --- | --- | --- |
| 1 | 2026-10-02T20:33:44+08:00 | Battery, Low Power Mode | 25.74 |
| 2 | 2026-10-02T20:34:09+08:00 | Battery, Low Power Mode | 27.72 |
| 3 | 2026-10-02T20:34:37+08:00 | Battery, Low Power Mode | 5073.43; sleep interrupted |

`pmset` recorded Clamshell Sleep at 20:34:38. Run 3 is not a valid speed
measurement. Its bundled step reported 27.9 s of monotonic time. Preserve
both values; do not subtract an estimated sleep period. Logs and power
records are `.scratch/296/final-local-*`; sleep evidence is in
`.scratch/296/power-events.log`.

## Acceptance state at the first stop

At the first stop, the investigation had found two code races and one shared Hex cache race. It did
not meet #296's acceptance criteria. The local target is unproven, the final
host gate failed, and the final candidate has no controlled total speed gain.
Do not ship the draft as a completed performance fix.

An isolated file-write trace confirmed that `Project.cons_apps/0` writes
seven consolidated protocol files, including `List.Chars`. This proves the
unsafe writer exists. It does not identify the writer of the observed corrupt
file after the fact.

Studies 1–5 completed within two hours each. Study 6 had less than two hours
of active work before laptop sleep. Its elapsed time crossed the limit during
the sleep interval. No further scheduling experiment was run before the first response. The user
then requested continued work; that work is recorded below.
Rejected probes and full logs remain in `.scratch/296/`.

Next: fix or isolate Hex registry persistence while preserving user config;
then make a quiet host comparison against the base. Keep only changes with a
measured total gain, complete the final ten-fast/three-slow gate, and repeat
the three local measurements without sleep. No production bound needs to
change for these steps.

## Continued work after the user reopened the laptop

The user requested continued work after the first stop. This section replaces
the earlier open-acceptance state. All earlier logs, including failures, remain.

### Final changes

- Prepare projects one at a time. Checks for a prepared project can overlap
  the next preparation. A Mix OS-process lock serializes preparation across
  worktrees that use this runner. It uses Mix 1.19's existing internal `Mix.Sync.Lock` API, with no
  new dependency or credential/cache-location changes. Standalone Hex commands
  and older runners do not take this lock.
- Keep the PLT check in preparation. Disable dependency checks and compilation
  in the parallel checks, including `mix test`. `--no-compile` still loads and
  runs all test files; it skips application compilation already done in prepare.
- Disable scheduler busy waiting. Keep the native scheduler count and ExUnit
  concurrency. Explicit `ERL_FLAGS` still takes precedence. The two- and
  four-scheduler probes remain experiments, not final code.
- Keep one streaming Perl parser per fake Codex process.
- Keep the gated Task-readiness fix in LoopTest.
- Stop Core synchronously in the resume-message tests before the next test
  uses its default name. The stop uses the shared 30-second test wait cap. The old linked-process shutdown could still be running
  when ExUnit started that next test. Keep every original error assertion.
- Read a watchdog failed-start error through the existing 2,000-byte cap or
  port exit. The failed-start marker and the text can arrive in separate port
  messages. The old code returned only the first fragment; one run returned
  493 bytes where the existing integration test expected the capped 2,000.
  The collector retains at most the notice cap, closes the port, and uses the
  existing harness initialization deadline. No production bound changed.

The startup-error fix is in the shared HarnessIO helper, so both ClaudeCode
and Codex use it. Its design is recorded in `long-lived-harness.md`. Removed
an obsolete ClaudeCode comment about leaving a failed-start port open; this
comment-only change does not change the tested code.

### New failures and regression checks

The serial-preparation candidate passed ten fast host runs, then passed one
slow run and failed the next. The failed app test got `:already_started`
because Core from the previous test had not finished stopping. Logs are
`.scratch/296/resumed-gate-*`; no failing run was discarded.

A static-check scheduler probe failed the existing startup-error length test.
Its log is `.scratch/296/resumed-static2.log`. This is the fragmented error
read above, not a shortened timeout or an assertion removed for speed.

Focused verification after the fixes:

- Startup-error, PATH, and ClaudeCode turn tests, including slow tests: 17
  tests passed in the initial run and all ten repeats.
- Resume-message tests: seven tests passed in the initial run and all twenty
  repeats.
- The new deterministic startup-error tests cover one chunk, split chunks,
  a marker with no initial error text, one-byte chunks, short errors, and
  invalid UTF-8. They do not use sleeps. Both fail against a mutation that
  returns only the marker's initial text, as the old call did.
- A runnable precommit probe starts two separate worktrees with fake child
  commands. It checks exclusive preparation, failure propagation, skipping
  checks only for the failed project, and paths with spaces, quotes, and glob
  characters. It passed. Script: `.scratch/296/runner-check.py`.

### Laptop result

Three consecutive full `mix precommit` runs of the final code passed:

| Start (UTC+08:00) | Power | Seconds |
| --- | --- | --- |
| 2026-10-02T22:58:52+08:00 | AC, Low Power Mode off | 12.23 |
| 2026-10-02T22:59:04+08:00 | AC, Low Power Mode off | 11.13 |
| 2026-10-02T22:59:15+08:00 | AC, Low Power Mode off | 14.95 |

All are below the 25 s target. Each ran 386 root tests, 468 bundled tests plus
one property, and 17 app tests. Logs and power records are
`.scratch/296/verified-local-*`.

Earlier battery runs of the serial-preparation candidate took 31.80, 29.66,
and 27.34 s. A four-scheduler battery probe took 24.05 s. After AC power was
connected, that scheduler probe took 13.02, 16.41, and 14.32 s. These are not
controlled code comparisons. Do not claim the final battery target is met,
or assign all of the difference to power. The accepted local result above
is explicitly on AC power.

### First complete host gate

Ten fast runs and three `HELYX_SLOW=1` runs of `precommit.sh` passed. Every
fast run has 386 root tests, 468 bundled tests plus one property, and 17 app
tests. Every slow run has 396 root tests, 501 bundled tests plus one property,
and 17 app tests. The real-Claude exclusion is unchanged.

| Tier | Seconds, including transport |
| --- | --- |
| fast | 23.36, 22.91, 36.16, 36.52, 31.54, 32.42, 35.54, 35.56, 37.80, 36.71 |
| slow | 56.43, 42.96, 42.37 |

Full logs: `.scratch/296/verified-gate-*`. A host process sample confirmed
other worktrees were active during the gate. Treat this as the reliability
gate, not the speed comparison.

### Warm-cache host comparison

Alternate the base (`58471ac`) and the candidate. Each source switch gets a
separate full warm-up run before measurement. All six warm-ups and all six
measured runs passed. The only later code change set the synchronous test
cleanup's failure wait to the shared 30-second cap; successful cleanup was
already below that cap. The final gate below includes that change.

| Pair | Base seconds | Candidate seconds |
| --- | --- | --- |
| 1 | 31.09 | 29.31 |
| 2 | 32.85 | 27.88 |
| 3 | 30.28 | 17.53 |
| Median | 31.09 | 27.88 |

The measured median fell by 3.21 s (10.3%). These are direct
remote `mix precommit` times, without transport. The host was shared with
other worktrees. This is not an isolated-host benchmark, and it does not
separate the contribution of each change. Full logs, including warm-ups:
`.scratch/296/compare-final-*`; summary: `.scratch/296/compare-final.log`.

A dedicated trace also checked the graph tests, which call Mix compilation
inside the test VM. With the prepared build and the new flags they wrote no
consolidated protocols and made no Hex registry persistence call. All four
graph tests passed. Log: `.scratch/296/graph-hex-probe.log`.

### Final acceptance

The final source passed a fresh ten-fast/three-slow host gate after the test
cleanup received its explicit wait cap. Counts stayed 386/468/17 for fast and
396/501/17 for slow, plus the bundled property. No test was removed, no
assertion was weakened, and no slow tag or production bound changed.

| Tier | Seconds, including transport |
| --- | --- |
| fast | 20.96, 23.25, 46.62, 41.21, 22.78, 20.79, 22.19, 21.04, 22.55, 20.23 |
| slow | 41.43, 50.22, 40.11 |

Three consecutive local runs of that final source also passed:

| Start (UTC+08:00) | Power | Seconds |
| --- | --- | --- |
| 2026-10-02T23:13:19+08:00 | AC, Low Power Mode off | 12.59 |
| 2026-10-02T23:13:32+08:00 | AC, Low Power Mode off | 12.35 |
| 2026-10-02T23:13:44+08:00 | AC, Low Power Mode off | 13.32 |

Logs: `.scratch/296/accepted-gate-*` and `.scratch/296/accepted-local-*`.
The final app cleanup test also passed its initial run and twenty repeats
with the explicit wait cap (`resume-bounded-final-check.log`).

The 25-second local target is met on AC power. Battery performance is not
claimed. No power setting was changed by this work. The continued studies
finished within two hours after the user's request to continue. The patch
remains uncommitted in the separate worktree. No issue, PR, merge, or external
message was published. Recheck the runner probe when upgrading Mix because
its cross-process lock is an internal Mix API.

## Battery verification requested by the user

The user requested a new check on battery power. The code was unchanged.
Three consecutive local `mix precommit` runs all passed. Each ran 386 root
tests, 468 bundled tests plus one property, and 17 app tests.

| Start (UTC+08:00) | Power at start and end | Low Power Mode | Seconds |
| --- | --- | --- | --- |
| 2026-10-02T23:30:27+08:00 | Battery | Enabled | 28.45 |
| 2026-10-02T23:30:55+08:00 | Battery | Enabled | 31.88 |
| 2026-10-02T23:31:27+08:00 | Battery | Enabled | 26.46 |

The 25-second battery target is not met. The earlier AC measurements do not
satisfy that condition. No power setting or source file changed for this
check. Full output and power records: `.scratch/296/battery-now-*`.

## Commit and PR requested

The user accepted the battery results and requested a commit and PR.
Before review, the branch advanced to `origin/master` at `511d68b` without
conflicts. Earlier benchmark and repeat-run counts above describe the
source before that update. The ship review and final gate are recorded
in `docs/reviews/2026-10-02-296-precommit.md`.

The ship review also reproduced overlap between two precommit runs in one
checkout. A full-run checkout lock now prevents that overlap. The next
review found that `MIX_EXS` could give the same checkout a different path.
The key now uses the directory's device and inode. Normal, alias, and
separate-worktree probes pass. The reviews also confirmed that SIGKILL can
leave child Mix VMs alive on both master and this branch. That existing
interrupted-run cleanup limit remains and is stated in the PR.

The final slow ship gate passed after the update to master and the locking
fixes: 419 root tests, 504 bundled tests plus one property, and 17 app
tests, all with zero failures. All static checks passed. This final gate
is separate from the earlier ten-fast/three-slow measurements.
