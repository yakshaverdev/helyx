# Helyx simplification review

Accidental complexity, waits that should be events, and TigerStyle. Master at `5956944`, 2026-09-30. Seven review agents plus a verification pass.

## Summary

- **~400–500** lines of `lib/` to cut (4–5% of 11,200)
- **~300** lines of tests to cut
- **427** lines in `Session.Server.handle_info/2`, 46 clauses
- **7** correctness bugs found on the way
- **0** sleep-polling loops in `lib/`

- **The two-harness hypothesis was mostly wrong.** Most of the 2,200 adapter lines come from real protocol differences. Claude Code uses stream-json. Codex uses JSON-RPC. Replay, steer, interrupt, and tool bridging all differ. The shared code is already in `HarnessIO`. The duplicated or dead code in the adapters is about 100–120 lines.
- **The real accidental complexity is in five places:**
  1.  A third provider mode (`:external` per turn) that only test fakes use.
  2.  Session server state spread over seven fields that store request refs, with routing by clause order.
  3.  Dead code from older designs: the HarnessIO exit wait and the counted watchdog input.
  4.  Numbers defined in more than one place.
  5.  Tests that sleep or poll where an event exists.
- **The larger gain is structure, not line count.** The session server holds about seven state machines in one GenServer. Section 2b shows the plan for `server.ex`: about 100–150 lines are deleted, and about 270 lines move into two modules that own their own data. About 900–950 lines remain. The rest of the size is behaviour that ADR 0007 requires.

## 1. Delete or merge, ranked by value

| \# | Finding | Where | Lines | Risk | Check |
|----|----|----|----|----|----|
| 1.1 | **Delete the per-turn `:external` provider mode.** Both real harnesses are connected. The only modules with `turn: :external` and no `harness_init` are test fakes. The mode keeps a steer that aborts the turn, `Hands.stream/4`, `start_stream(:external, …)`, and several `turn_mode` branches. needs ADR 0002/0007 change | `server.ex:173-175, 1058, 1136-1144, 1268` `hands.ex:117` `provider.ex:228-267` | 60–100 | med | verified |
| 1.2 | **After 1.1, "exports `harness_init/3`" is the only signal for a connected provider.** Delete the `turn/0` callback, its try/catch, `:bad_provider_turn`, and the two `stream/3` stubs that return `{:error, :connected}`. | `provider.ex:229-249` `claude_code.ex:216, 230` `codex.ex:240, 253` | ~30 | low | verified |
| 1.3 | **Delete the dead exit-wait code in HarnessIO.** `drain`, `wait`, `remaining`, `overdue?`, `arm_exit_wait`, and `@exit_wait_ms` have no callers. `done?` is written in 7 places and read by no production code. | `harness_io.ex:14, 131-151` `codex.ex` (7 writes) | ~40 | low | verified |
| 1.4 | **Delete the counted stdin input of the watchdog.** Production passes only `nil` (bash) or `:open` (harnesses). The counted mode is left from \#10, and only one test uses it. | `watchdog.ex:31-48` and one perl branch | ~25 | low | verified |
| 1.5 | **Replace the `Helyx.Interface` macro with one map.** Four real interfaces use it, and the README fixes the extension surface. Only test interfaces use the generic machinery. | `interface.ex` `core/plugins.ex:16-42, 73-80` | ~40 | med | verified |
| 1.6 | **Move tool-call pairing out of the TUI.** `ViewModel.results_in_call_order/1` copies the rule of `Transcript.open_calls/1` in the client. That goes against "clients are thin". The snapshot can carry the pairing, and ADR 0006 §5 allows a new field. | `view_model.ex:239-314` | ~55 | med | verified |
| 1.7 | **Share the harness spawn and release code.** Both adapters build the same `/bin/sh -c 'exec "$0" "$@" 2>/dev/null'` argv, pass `:open` and a 5,000 ms grace, and repeat the same `release/3`. Add `HarnessIO.spawn/4` and one `release`. | `claude_code.ex:221-225, 381` `codex.ex:244-248, 265` | ~22 | low | verified |
| 1.8 | **Share the port-message handling.** The `{:data}`, `{:exit_status}`, and `{:DOWN, :port}` clauses are written three times, and the copies differ (bug 4.1). | `claude_code.ex:337-368` `codex.ex:318-333, 421-439` | ~15 | low | verified |
| 1.9 | **Simplify the Credo check `WallClockUpperBound`.** It is 280 lines of taint analysis plus a 179-line test. It guards **10 assertions in 5 files**. A smaller syntactic check is a proposal only. Nobody has shown that it keeps the variable tracking and the assertion coverage of the current check. Treat the size estimate as unverified. | `credo/wall_clock_upper_bound.ex` | unverified | med | corrected |
| 1.10 | **Simplify `helyx.graph`.** Only its own test uses `--mermaid` and the module filter, and `grep` does the job of the filter. The task uses the process dictionary (`Process.put(:helyx_graph_registered, …)`) to carry a value out of `after`. A `try` value is simpler. | `helyx.graph.ex:37-56, 88-99, 124, 134` | ~27 | low | verified |
| 1.11 | **Count lines once in the read tool (not a direct deletion).** The read tool counts lines a second time, with a separate rule (`line_count`, `newlines`, `empty_window`). `Text.truncate/3` drops the lines before `first` and computes the total only when it cuts. For an offset past the end, it returns `""` with no count, and that is the case where the read tool needs the count. To share the work, change the return value of `truncate/3` or add a helper that keeps the total and the empty-file rule. | `read.ex:71-96` `text.ex:84-101` | \<20 | med | corrected |
| 1.12 | **Merge the duplicated `Gate` tool and gated provider.** Two TUI test files define them. | `second_client_test.exs:20` `view_model_snapshot_test.exs:15` | ~70 | low | verified |
| 1.13 | **Merge `collect_until` into one shared helper.** Nine files define their own copy, with four different timeouts. | tests | ~60 | low | corrected |
| 1.14 | **Delete `Session.model/1`.** It has no production caller, and it is not in the ADR 0006 contract. Its 15 test callers can use `snapshot.model`. | `session.ex:438` | ~8 | low | verified |
| 1.15 | ~~**Delete the cwd NUL check in bash.**~~ **Withdrawn. Keep the check.** `Bash.run/2` is a public entry point, and `Session.start/2` does not guard a direct call to it. A test covers exactly this case, and AGENTS.md says to keep a documented safety check. | `bash.ex:71` `bash_test.exs:126` | 0 | low | corrected |
| 1.16 | **Remove the forwarding hop in `release`.** `HarnessIO.release` delegates to `Watchdog.release`, which delegates to `Watchdog.Group`. | `harness_io.ex:94` `watchdog.ex:324` | ~4 | low | verified |
| 1.17 | **Remove the armed-kill handshake in `spawn_armed`.** It sends a message and waits for it. `:timer.kill_after(ms)` inside the Task arms the same kill before any plugin code runs. | `hands.ex:359-371` | ~5 | low | verified |
| 1.18 | **Move the connected-harness protocol out of `provider.ex`.** About 110 of its 170 moduledoc lines describe that protocol. Put the protocol in a plain behaviour, `Helyx.Provider.Harness`. A model-provider author then reads only `id/0` and `stream/3`. | `provider.ex:87-171` | 0 net | low | agent |
| 1.19 | **Move the per-call-id bookkeeping into the harness loop.** Both adapters keep a `used` set and the same error strings. Add one `{:tool_reject, …}` action instead. This changes the interface and the \#203 rule. | `claude_code.ex:765-795` `codex.ex:703-734` `harness.ex:273-301` | ~25 | med | agent |
| 1.20 | **Simplify the OpenAI tool-call byte accounting.** Append arguments as a binary, and cap the call count directly. Then delete `@call_entry_bytes`, `@call_fragment_bytes`, `entry_bytes/2`, and `bin_size/1`. Keep the 10 MiB cap. | `openai.ex:202-212, 383-431` | ~20 | med | agent |
| 1.21 | **Merge the harness test helpers.** `pump/3` and `drive/3` are the same, and so are the two `settle/2` helpers. | `claude_code_test.exs:257, 563` `codex_test.exs:215, 231` | ~25 | low | agent |
| 1.22 | **Remove the late-join overlap.** Two test files check the same ADR 0006 §3 rule. Keep `second_client_test`, and reduce the snapshot test to the shapes that the other file does not cover. | `view_model_snapshot_test.exs` | ~60 | low | agent |
| 1.23 | **Remove the contract-version screen from the TUI.** A version mismatch cannot happen in one node, but the TUI has 6 clauses for it. Match `contract_version: 1` at mount instead. needs ADR 0006 change | `tui.ex:73, 196, 262, 545` | ~20 | low | verified |

## 2. Session server structure

`Session.Server` holds about seven state machines: session activity, the local turn loop, the connected turn phase, the steer ledger, the harness request ledger, the wait sequencer, and the harness connection lifecycle. The steps below are ranked by value, not by line count.

| \# | Finding | Lines | Risk | Check |
|----|----|----|----|----|
| S1 | **Harness request refs live in seven places.** They are `turn.start`, `turn.pending`, `turn.steers[].from`, `turn.results`, `aborting.idle`, `aborting.steers`, and `aborting.reply`. Clause order routes each reply. Replace them with one `requests: %{from => kind}` map and one dispatch clause. `Wait.steers` also holds non-steers today. **Root cause:** the harness loop drops the request kind from its reply (section 2b), so the cheapest form of S1 starts there. **Corrected:** the kind helps dispatch only. An empty set of open refs does **not** mean that cleanup is complete. For example, an interrupt reply other than `:ok` clears `reply`, but the wait must still see `:harness_down` after the hands release the handles (`server.ex:557-576`). Keep the completion conditions (`hands`, `harness`) as explicit fields, and keep the metadata that late replies need (for example the turn id of a steer). | ~20–30 | med | corrected |
| S2 | **Make the steer ledger a pure module.** Today it uses tuple sentinels: `nil` means "taken", and `:answered` means "answered, not taken". Eleven functions change it by hand. Use `Helyx.Session.Steers`, which returns `{ledger, effects}`. The tests that read `:sys.get_state` then become pure tests. | ~40 | med | agent |
| S3 | **Join `turn` and `aborting` into one field.** No code path sets both, but nothing enforces that. Use `activity :: :idle | %Turn{} | %Wait{}`. Also rename `aborting`: it is set for 6 causes, and only one of them is an abort, which conflicts with the CONTEXT.md meaning of **Abort**. | ~10 | med | agent |
| S4 | **Remove `provider_pids`.** The set grows by one pid per abort. `Task.shutdown` unlinks before it kills (Elixir 1.19.5 `task.ex:1379`). A flush with `receive {:EXIT, ^pid, _} after 0` after the shutdown removes the need for the set. | ~10 | med | verified |
| S5 | **Small cleanups.** Add one `base_opts(state)` helper; the keyword list is built three times. Replace the `queues` closure argument, which is a hidden flag. Rename `run_harness_tool` to `run_on_hands`. Use `:snapshot`, not `{:snapshot}`. Remove the `held \\ 0` default in `Queues.push/4`. | ~5 | low | agent |

## 2b. Why `server.ex` is 1,329 lines, and what it needs

Not everything in `server.ex` is needed, and the part that is needed does not all belong in one module. The size is a symptom. The cause is state that no module owns.

### What the lines contain

- **1,329** total lines
- **272** comment lines (20%)
- **200** blank lines
- **~860** lines of code
- **427** `handle_info/2`, 46 clauses
- **98** `handle_call/3`, 14 clauses

### The code by concern

| Concern | What it includes | ~Lines | Needed? |
|----|----|----|----|
| **Connected harness** | `tool_request`, 6 `harness_reply` clauses, `cancel_tool`, `harness_session`, `program_turn`, `harness_ready`, 3 `prepared` clauses, `idle_close`, 4 `harness_down` clauses, `connect`, `submit`, `interrupt`, `arm_idle`, `close_or_start` | ~450 | The behaviour is needed (ADR 0007). The routing by stored refs is not (see the root cause below). |
| **Abort and wait sequencer** | `Wait`, `wait`, `progress`, `settle`, `end_work`, `stop_hands`, the `check_response` clause | ~150 | Needed. It should be a module that owns the `Wait` data. |
| **Steer ledger** | `append_steers`, `held`, `send_steer`, `send_local_steers`, `requeue_steer`, `take_steer`, `end_steers`, `notice`, `drop_wait_steers`, `end_wait_steers`, and 4 `handle_info` clauses | ~130 | Needed. The tuple sentinels (`nil`, `:answered`) are not. |
| **Local turn loop, persistence, emit** | `stream_event`, `stream_end`, the Task reply and `:DOWN`, `tool_result`, `rejected_call`, `end_turn`, `persist`, `do_emit`, the stale-message drop clauses | ~250 | Needed. This is the core of the session. |
| **Per-turn `:external` mode** | the steer that aborts the turn, `start_stream(:external, …)`, `external?`, `turn_mode` branches | ~60–100 | **Not needed.** Only test fakes use it (item 1.1). |

### Root cause: the harness reply drops the request kind

The `Session.Harness` loop already keeps the kind of every open request. Its comment says: "`open` holds the kind and the kill of each request without a reply, by its `from`" (`harness.ex:91`). But the loop replies with `{:harness_reply, from, value}` (`harness.ex:108, 178, 188, 191, 368`). The reply does not carry the kind.

So the server must remember what each `from` was for. It keeps the ref in seven places:

- `turn.start`, `turn.pending`, `turn.steers[].from`, `turn.results`
- `wait.idle`, `wait.steers`, `wait.reply`

It then tries 6 `harness_reply` clauses in order to find the match (`server.ex:302, 475, 489, 512, 525, 558`). The order of the clauses carries meaning, and nothing states it.

**Fix.** The loop replies with `{:harness_reply, from, kind, value}`. The server routes each reply by pattern on `kind`, and it does not need to store the ref in seven places only to find its purpose. The change in `harness.ex` is about 5 lines, and it removes the routing by clause order.\
\
**Limit** corrected The kind fixes dispatch, not completion. A wait ends when the hands have answered, when every open request has an answer, **and** when a harness process that is ending has sent `:harness_down` after its release. An interrupt reply other than `:ok` is an example: its ref is gone, but the wait goes on until `:harness_down` (`server.ex:557-576`). These completion conditions stay explicit fields. Late replies still need their metadata, for example the turn id of a steer, so that a reply for a finished turn is handled correctly.

### Steps and effect

| Step | Effect on `server.ex` | Kind | Risk |
|----|----|----|----|
| Delete the per-turn `:external` mode (item 1.1) needs ADR 0002/0007 change | −60 to −100 | delete | med |
| Add the kind to `harness_reply`, and route by kind (S1). The completion fields stay. | −20 to −30 | delete | med |
| Remove `provider_pids` (S4), the `Session.model` handler (1.14), and the small duplicates (S5) | −20 | delete | low |
| Move the steer ledger to a pure `Helyx.Session.Steers` (S2) | −120 | move | med |
| Move the wait sequencer to a pure module that owns `Wait`, and join `turn` and `aborting` into one field (S3) | −150 | move | med |

- **~100–150** lines deleted
- **~270** lines moved into 2 modules that own their data
- **~900–950** lines left in `server.ex`, with comments (1,329 − 100…150 − 270)

### What not to do

- **Do not move the connected-harness handling into a module that takes and returns the whole `State`.** That is a shallow module: it hides nothing and only moves lines to another file. Once the reply carries its kind, that code gets smaller by itself.
- **Do not split `handle_info/2` mechanically** to meet a line cap. One clause per message is normal for a GenServer. No single clause is over 70 lines. The problem is the hidden state, not the number of clauses.
- **Do not cut comments blindly.** 272 comment lines is a lot, but many of them record why a bound or an order is required. Cut a comment only when the code that it explains is deleted or moved.

### Order

1.  **The dead-code batch** (group 1 in the next step). It does not touch the server's structure.
2.  **The `harness_reply` kind change.** It is small, and it removes the routing by clause order.
3.  **The `:external` removal**, after the ADR change.
4.  **The `Steers` and `Wait` extraction**, with pure tests that replace the tests that read `:sys.get_state`.

## 3. Waits that should be events

**Lib is clean.** No `Process.sleep` polling loop exists in `lib/`. Every lib wait is event-driven or is a real deadline. The waits that should be events are almost all in tests.

| Wait | Where | Replacement | Check |
|----|----|----|----|
| The `"ok"` fake model sleeps 50 ms per event, in **103 tests** | `test/support/interfaces.ex:307` | Remove the sleep. The tests that need a turn in progress use the `Gate` pattern (send `:streaming`, wait for `:go`). This saves about 10 s per run. | verified |
| `late_*` fakes answer from `Process.send_after` after 100 or 300 ms | `interfaces.ex:959-1003` | Generalize the existing `steer_hold` hold/answer pattern. | agent |
| `eventually(Session.pid(..) == nil)` | `tui_test.exs:343, 402, 482` | Delete it. `Registry.whereis_name` already returns `:undefined` for a dead pid (`registry.ex:263`). | verified |
| `stop_session` polls `Registry.lookup` so that a resume "cannot race" | `session_test.exs:46-53` | Monitor the process and wait for `:DOWN`. `register` replaces an entry with a dead owner (`registry.ex:1214`). | verified |
| `refute_receive …, 50`, 14 times | session and TUI tests | **Only where the test process itself sent the operation to the session:** a synchronous call, then `refute_received`. The session sends events before it replies. **Not** where another process sends the operation. The TUI Escape handler calls `Session.abort/1` from its own Task (`tui.ex:285`), so a test call can reach the session before that Task sends the abort, and the test passes before the abort runs. In those cases, wait for a completion signal from the real sender. | corrected |
| `await_held` / `await_tool_task` poll `:sys.get_state` every 10 ms | `hands_test.exs:265` `session_test.exs:1580` | `Tool.hold/1` is synchronous. The test tool sends `:held` after it. | agent |
| `in_mailbox/2` polls with **no bound** | `harness_tools_test.exs:324` | Trace `:receive`, or at minimum add a bound. | verified |
| `Process.sleep(100)` before a check that the Task supervisor has no children | `hands_test.exs:208` | Monitor the children and wait for `:DOWN`. | agent |
| The Slow tool uses 60/30/0 ms sleeps to force an order | `interfaces.ex:335` | A gated tool that the test releases in the order it wants. | agent |
| A snapshot forwarder ends on "no event for a second" | `view_model_snapshot_test.exs:341` | End on an explicit `:disconnect`, as `serve/2` already does. | agent |
| `wait_for_no_harness` polls session state | `claude_code_test.exs:322` | This is a real race for users too. Emit an event when the harness process ends, or record the race as known. | agent |
| The perl watchdog uses a 50 ms `select` tick to poll for the child's exit | `watchdog.ex:159` | A SIGCHLD self-pipe. This is optional: it saves about 25 ms per bash call. | agent |

**Correct polls to keep:** `gone_within?`, `wait_for_pid`, the port `queue_size` poll, and the `kill -0` sweep in `Watchdog.Group` watch OS processes. The BEAM has no event for those. Each one needs only a bound and a unit in its name. `gone_within?(g, 300)` reads as 300 ms but means 300 tries, which is 3 s. `kill_when_queued` has no bound.

## 4. Bugs found during the review

| \# | Bug | Where | Check |
|----|----|----|----|
| 4.1 | **The Codex close fails on a port `:DOWN`.** Claude answers `:ok` when the port goes down during a close. Codex stops with `{:codex_exit, reason}`, so a close that ends with `:epipe` reports an error. | `codex.ex:436` vs `claude_code.ex:363` | verified |
| 4.2 | **Claude's `tool_id` can map two ids to one.** The regex replace makes `a.b` and `a:b` the same id. Codex `call_id/1` uses a digest. Share one `wire_id/1`. | `claude_code.ex:1013` `codex.ex:1177` | verified |
| 4.3 | **Two Cores can append to one session file.** The reader keeps entries in file order and ignores `parent_id`, so a resume mixes two conversations. `repair/3` can also truncate the file while the other Core appends to it. The fix needs exclusive ownership of the file. corrected A lock taken only at resume is not enough: Core A can create a session and keep writing without a lock, and Core B can then resume the file and take a lock that A never held. Ownership must be taken at **create** (`file.ex:83`) and at **resume** (`file.ex:132`), held through every write, and taken at resume **before** the file is read or repaired. Following `parent_id` can separate branches when the file is read, but it does not stop `repair/3` from truncating bytes that the other Core appended (`file.ex:530, 538-545`). It is not a fix by itself. | `file.ex:204, 547-559` `session-instance.md:12` | verified |
| 4.4 | **The heap-cap comment claims too much.** 64 MiB × 42 bytes = 2.7 GiB, which is more than the 1 GiB cap. A worst-case session larger than about 24 MiB is rejected. | `file.ex:25-29` | verified |
| 4.5 | **An abort replies `:ok` when the cleanup failed.** The failure is only logged. The doc of `Session.abort/1` says that it returns after the processes are killed. Emit a `:notice`. | `server.ex:639` | verified |
| 4.6 | **A failed session-file write is only logged.** The session then runs in memory only, and no client learns about it. Emit one `:notice`. | `server.ex:1237` | verified |
| 4.7 | **A test margin points the wrong way.** `release_ms: 300` against a 250 ms release fails when the machine is under load. A second case: the watchdog grace test uses `group_gone_within?(group, 50)`, which counts tries, so the Credo check cannot see its upper bound. | `hands_test.exs:195` `watchdog_test.exs:91-94` | agent |

## 5. Magic numbers and bounds (TigerStyle)

### One number, more than one source

| Value | Sources | Fix | Check |
|----|----|----|----|
| `500` grace | `watchdog.ex:178`, `group.ex:26` | One `@grace_ms`. | verified |
| `5_000` harness grace | `claude_code.ex:4`, `codex.ex:3` | One home in HarnessIO (item 1.7). | verified |
| `2_000` error cut | `harness_io.ex:16`, `stream.ex:22` | Read the bound from one place. | agent |
| `2000 lines / 50 KB` | `text.ex:7-8`, copied as a literal into `read.ex:34` | Interpolate from `Helyx.Text`. | verified |
| `10_485_760` | `text.ex:9`, `openai.ex` | OpenAI refers to `Helyx.Text`. | verified |
| 7 values in the moduledoc | `provider.ex`, `event.ex:49` | Name the constant. Do not copy the value. | agent |
| `@hands_stop_ms 22_000` | derived by hand from `release_ms: 20_000` | Derive it from the source, with a named `@load_ms` margin. | verified |

### Numbers with no reason

- verified **Five equal harness deadlines.** `harness_ms` has five keys with the value `2_000` (`server.ex:58-62`). Use one `@harness_reply_ms` with a one-line reason: a loop that writes one line answers in under 10 ms.
- verified **`@max_open 8`** (`harness.ex:24`) sits next to a steer queue of 32 with no stated sum. Write it as 1 turn + 1 interrupt + 1 close + N steers.
- agent **`@held_max 10_000`** (`codex.ex:5`) has no derivation.
- agent **The OpenAI byte estimates.** `@call_entry_bytes 100` and `@call_fragment_bytes 64` have no stated source.
- agent **The release deadline has no margin for a harness.** `release_ms 20_000` equals the worst case of a harness cancel (5,000 + 3 × 5,000). The doc derives it from bash only.
- verified **The test timeouts.** 165 `assert_receive` calls use the default of 100 ms. Set `ExUnit.start(assert_receive_timeout: 1_000)` once, and delete the 34 manual `1_000` arguments. The tests also use five different `@load_ms` values: 1_000, 400, 2_000, 250, and `@load_us`.

### Missing bounds

- verified **The bash call has no timeout** (`bash.ex:149`). It is marked `ponytail:`, so it is known debt. A background child that keeps stdout open also holds the call.
- verified **`read_marker` has no `after`** (`watchdog.ex:424`).
- verified **Text deltas have no byte limit.** The comment says "every event is already capped", and that is false for deltas (`stream.ex:23-25, 150`). The TigerStyle envelope: 10,000 queued messages × an unbounded delta.
- corrected **`abort` uses `:infinity`** (`session.ex:470`). **Keep it for now.** The earlier proposal of about 35 s was too short. A connected abort can take 20 s for the tool release, 2 s for the tool result, 2 s for the interrupt timeout, and then 20 s more when the hands release the handles of the killed harness process before `:harness_down`. That is 44 s before scheduling delays. A client timeout that is shorter exits while the cleanup continues. First define the full bound and what a client does on a timeout, then replace `:infinity`.
- agent **The two Hands calls `start` and `connect` use the implicit 5 s default timeout.** A timeout there crashes the session.
- verified **The TUI renders one frame per delta.** Each frame wraps the whole open reply again, so a long reply costs more with the square of its length. The code uses no `render?: false` anywhere.
- agent **The transcript grows with `++ [message]`**, which is quadratic over a session and has no cap. Mark it with a `ponytail:` comment.

### Units missing from names

`@receive_timeout 120_000` (`openai.ex:42`), `@call_timeout 5_000` (`session.ex:83`), the Text limits `@max_bytes`, `@max_lines`, and `@max_file_bytes`, and the test helpers `gone_within?` and `wait_for_pid`, which count tries.

### Functions over 70 lines

| Function                                      | Size                  |
|-----------------------------------------------|-----------------------|
| `Helyx.Session.Server.handle_info/2`          | 427 lines, 46 clauses |
| `Helyx.Provider.ClaudeCode.translate/2`       | 218 lines, 17 clauses |
| `Helyx.Session.Server.handle_call/3`          | 98 lines, 14 clauses  |
| `Helyx.Provider.Codex.harness_request/3`      | ~84                   |
| `Helyx.Provider.ClaudeCode.harness_request/3` | ~79                   |
| `Helyx.Session.Harness.action/2`              | ~75                   |
| `Helyx.Provider.Codex.notification/3`         | ~74                   |
| `Helyx.Provider.ClaudeCode.mcp/3`             | ~72                   |
| The perl program in `Helyx.Watchdog`          | 71                    |
| `Helyx.Test.Provider.stream/3` (test fake)    | ~290                  |

## 5b. Naming and domain model

These findings come from the `domain-modeling` lens: do the names in the code match `CONTEXT.md` and the ADRs? None of them deletes code, but each one removes a place where a reader must learn two names for one thing, or one name for two things.

| \# | Finding | Where | Risk | Check |
|----|----|----|----|----|
| N1 | **"Transcript" names two things.** CONTEXT.md says it is messages and session entries. In the code, `State.transcript` and `Transcript.*` are only `[Message.t()]`. `Resumed.messages` is the same list under a second name. Fix the glossary, and rename `Resumed.messages` to `transcript`. | CONTEXT.md; `snapshot.ex:12`; `file.ex:49-65` | low | agent |
| N2 | **The Entry definition uses a word that it tells readers to avoid.** It says "a session record such as a model change", and then "*Avoid*: record". Write "a session entry". | CONTEXT.md, Entry | low | agent |
| N3 | **The Context definition is narrower than the struct.** The glossary says "the messages a provider sees". The struct also holds `system` and `tools`. | `context.ex:3-7`; CONTEXT.md | low | agent |
| N4 | **The field `aborting` names a wait with six causes.** Only one cause is an abort. This conflicts with the CONTEXT.md meaning of **Abort**. Rename it to `wait` (the struct is already `%Wait{}`). | `server.ex:71` | low | agent |
| N5 | **CONTEXT.md does not know the connected mode.** It says "a local turn or an external turn". The code and ADR 0007 add `:connected` and a harness process (struct `Connection`). The **Hands** entry says "runs tools", but the hands also run stream Tasks, prepare Tasks, and the harness process. Add **Connected provider** and **Harness process**, and widen **Hands**. | CONTEXT.md, Providers; `server.ex:28-30, 75-81` | low | agent |
| N6 | **One name, two concepts, in the harness code.** Claude `release/2` sends the next replay chunk, but `release/3` frees OS handles. Harness `run/2` is the process body, but `run/3` sends a tool request. Codex `calls` means the unclosed message, but Claude `calls` means open MCP requests. Codex `turn` is the program's turn id. Rename to `send_next_chunk`, `run_tool`, `unclosed`, and `program_turn`. | `claude_code.ex:222, 725`; `harness.ex:77, 226`; `codex.ex` | low | agent |
| N7 | **`Wait.steers` holds tool-result requests too.** The code stores them as `{turn_id, nil}` next to real steers. This goes away with S1. | `server.ex:785, 1019` | low | agent |
| N8 | **One tuple field in Hands holds a call id or one of three job kinds.** The `id` in `{task, turn_id, id, module}` is a call id string, `:stream`, `:harness`, or `:prepare`. Eight clauses branch on it. Split it into `kind` and `call_id`, or use a small struct. | `hands.ex:300-327, 346-355` | low | agent |
| N9 | **`run_harness_tool/2` runs every tool call**, including local-turn calls. Rename it to `run_on_hands/2`. | `server.ex:1197` | low | agent |
| N10 | ~~**The model ref goes string to struct to string.**~~ **Withdrawn.** The parse is validation of disk data, not a round trip. The file decoder accepts any binary as a model (`file.ex:323`), so an old message model is not always the parser's own output. An external check with `"claude-code/"`: the current `resumable/3` rejects it, but a prefix check accepts it and picks the old harness session. Keep `ModelRef.parse/1`, unless the file boundary first gets the same validation. | `transcript.ex:46-53` `file.ex:323` | low | corrected |

## 5c. Other findings

Smaller findings from the agents that are not in the sections above. Each one is small; together they are worth one cleanup ticket per area.

| \# | Finding | Where | Risk | Check |
|----|----|----|----|----|
| O1 | **Session file: four passes over the entries and two validation methods.** `check_entries`, `valid_entry?`, `current_model`, and the message `for` each walk the list. One `Enum.reduce` with one `decode_entry/1` per type does the same, and it lowers the peak heap. | `file.ex:194-214, 356-417` | low | agent |
| O2 | **Session file: resume reads up to 256 headers.** It sorts by mtime and then reads every header to pick the largest `ts`. Go newest first and stop at the first header whose cwd matches. This changes "most recently started" to "most recently written". | `file.ex:421-446` | med | agent |
| O3 | ~~**Session file: reject a file with a bad harness label.**~~ **Withdrawn.** The reader drops unusable harness labels and keeps the valid messages. That is an explicit recovery rule, and a test requires it. Rejecting the file would stop a user from resuming a conversation that is otherwise usable. It would be a behaviour change, not a simplification. | `file.ex:393-414` `file_test.exs:127` | low | corrected |
| O4 | **Session file: the directory scan has no bound.** It stats every file, and nothing deletes session files. Write the cost down; add a retention rule later. | `file.ex:423, 438-446` | low | agent |
| O5 | **Core: unused defaults.** `Keyword.get(opts, :plugins, [])` cannot boot, because a Provider is required. `plugins(name \\ __MODULE__, interface)`: every caller passes the core. | `core.ex:47, 84` | low | agent |
| O6 | **OpenAI: swallowed errors.** `drain/1` has `rescue _ -> ""`, so an error body vanishes on any exception, including a bug in the drain. `stop_reason(_finish)` maps `"content_filter"` to a normal end. `session_header` has a `nil` branch that no caller reaches. | `openai.ex:70-75, 192-194, 470-472` | low | agent |
| O7 | **Read, write, and edit repeat the path handling.** The same `"path"` schema, `Path.expand(path, cwd)`, and error strings appear three times. This is small; accept it, or add one helper. | `read.ex`, `write.ex`, `edit.ex` | low | agent |
| O8 | **`Helyx.Provider.find/2` is a pass-through with one caller.** It keeps the error tag in the public API, so keeping it is defensible. | `provider.ex:209-218` | low | agent |
| O9 | **Watchdog: a cancel sends TERM twice.** The perl watchdog does TERM, grace, KILL when its port closes, and `Group.sweep(:cancel)` does its own TERM at the same time. Wait for the watchdogs to exit, then KILL any survivors. This changes the order that ADR 0004 describes. | `group.ex:60-68` | med | agent |
| O10 | **Watchdog: the 20 ms poll has no name**, and each tick forks one `kill -0` per group. One `kill -0 -- -a -b` per tick is possible. | `group.ex:103` | low | agent |
| O11 | **TUI: `reason` is client UI state inside the pure fold.** No event changes it. Move it into the TUI state map, and delete the two setters. | `view_model.ex:21-23, 320-326` | low | agent |
| O12 | **TUI: `ViewModel.new/1` is used only by tests.** A struct literal gives the same value. | `view_model.ex:69-71` | low | agent |
| O13 | **TUI: the tool-result preview is computed again on every frame.** Store it once, the way `call_line` is stored. | `tui.ex:703-717` | low | agent |
| O14 | **App: the sessions_dir default is split over two layers.** Put the default in the task, and use `Keyword.fetch!` in `start_session`. | `helyx.ex:48`; `coding_agent.ex:118` | low | agent |
| O15 | **helyx.graph: `stop/1` can race on the Registry exit signal** after `after 0`. Set `trap_exit` once and do not restore it. The agent did not reproduce the race. | `helyx.graph.ex:160-165` | low | agent |
| O16 | **Session: the local-turn call closer scans the whole transcript** at each turn end, although `turn.calls` seems to hold the same calls. Assert the equality in a test before any change. | `server.ex:1187-1190, 1244-1250` | med | agent |
| O17 | **Tests: five margin constants with five values** (1_000, 400, 2_000, 250, and `@load_us`), plus `@wait`. Use one `@load_ms` per project. Keep the derived ones with a comment. | hands, session, claude_code, group, and read tests | low | agent |
| O18 | **Tests: the queue limit of 32 is tested at two layers.** In `session_test`, check only the 33rd call's error and that no event comes. | `queues_test.exs:23`; `session_test.exs:938-963` | low | agent |
| O19 | **Tests: `WatchdogHarness` has one user.** Nest it in `harness_stop_test.exs`. | `plugins/bundled/test/support/watchdog_harness.ex` | low | agent |
| O20 | **Tests: `Tool.Slow` and `Provider.Other` exist twice.** The bundled project cannot compile the root `test/support`, so this can stay. | `tui_test.exs:1-31`; `interfaces.ex:90-103, 662-678` | low | agent |
| O21 | **Tests change internal state to shrink deadlines** with `:sys.replace_state`. The agent recommends keeping this, because the alternative is a test-only start option. | `harness_test.exs:35-55` and 3 more | low | agent |

## 6. Essential complexity that stays

- **The perl watchdog, with its nonce and go-ahead.** An Erlang port does not kill its child when the port closes. macOS has no `setsid` command or pidfd. A closed port is the only cleanup that survives a `kill -9` of the VM (ADR 0004).
- **The `kill -0` polling in `Watchdog.Group`.** No OS event reports that a process group is empty.
- **`Session.Harness` (ADR 0007).** It runs plugin code outside the session. It is the only place where a withdrawn call is proven never to run, and it serves both adapters.
- **`Hands` (ADR 0003).** It orders a hold against a delivery, and a release before a result.
- **The Claude replay chunking and interrupt state, and the Codex `in_order` hold queue.** Each follows a verified behaviour of the program.
- **The bounded session-file parse**, in its own process with a heap cap, and the torn-line repair.
- **The OpenAI SSE bounds** against a hostile peer. Only the accounting can be simpler.
- **`Watch`**, the monitor process for each subscription (ADR 0006).
- **`Compaction.None`**, a deliberate placeholder.

## 7. Corrections to the agents' work

- **Credo check:** it guards 10 assertions in 5 files, not 3. The agent missed `plugins/bundled`.
- **`collect_until`:** 9 files define a copy, not 12.
- **`Session.model/1`:** the test agent suggested using it as a sync barrier, and the session agent said to delete it. Delete it, and use `snapshot` as the barrier.
- **`session.ex:473`:** the test agent called the comment misleading. The comment is correct, so I dropped the finding.
- **External review (applied):** the abort bound (section 5), the two-writer fix (4.3), the bash NUL check (1.15, withdrawn), the test barrier (section 3), the read line count (1.11), and the Credo estimate (1.9). My first pass had labeled 1.11 and 1.15 as verified. The code facts that I checked were true, but I did not check the conclusions: whether `truncate/3` keeps the total, and whether `Bash.run/2` has other callers.
- **Second external review (applied):** S1 and section 2b (an empty set of open refs does not mean cleanup is complete), 4.3 (ownership at create and at resume, held through all writes), N10 and O3 (both withdrawn), the size arithmetic (1,329 − 200 − 270 is 859, not 700–800; with the smaller S1 saving it is now about 900–950), and the callback counts. Section 5 used the agent counts (418 lines, 43 clauses; 96 lines, 17 clauses). Section 2b used my own count (427 lines, 46 clauses; 98 lines, 14 clauses). The report now uses my count everywhere.
- **`usage` / `stop_reason`:** the persistence agent suggested that you might stop writing them. They are in the snapshot `messages` of the ADR 0006 contract, so they stay.

## Method

- **The map.** `mix helyx.graph calls` gave 910 edges, and `mix helyx.graph turn` gave a 308-line sequence diagram. Each agent got both.
- **The agents.** Seven read-only Opus agents, one per slice: harnesses, session core, OS resources, persistence, core and plugins, client and config, and tests. Each one loaded `codebase-design` and `domain-modeling`, and used three checklists: accidental complexity, waits that should be events, and TigerStyle.
- **Coverage.** The tool logs show that each agent read every file in its slice in full with `cat -n` or `Read`. The agents then used grep only to confirm callers. The one output that was too large (`claude_code.ex`) was read again from the saved file.
- **Verification.** I checked each finding that has the verified label in the source, including the Elixir 1.19.5 source of `Task` and `Registry`.

## Next step

Tickets, filed 2026-09-30. Group 1 comes first: the dead-code removals are a better first batch than the session-state refactor.

| Issue | Scope | Findings | Label |
|----|----|----|----|
| #258 | HarnessIO: delete the dead exit-wait code and the `done?` field | 1.3 | ready-for-agent |
| #259 | Watchdog: delete counted stdin input, one grace source, no release hop | 1.4, 1.16 | ready-for-agent |
| #260 | Harness adapters: share spawn, release, and port handling; fix Codex close and Claude tool id | 1.7, 1.8, 4.1, 4.2 | ready-for-agent |
| #261 | Session: remove `Session.model/1`, `provider_pids`, and the `spawn_armed` handshake | 1.14, 1.17, S4 | ready-for-agent |
| #262 | Session: a notice when abort cleanup or a session-file write fails | 4.5, 4.6 | ready-for-agent |
| #263 | Magic numbers: one source per number, units in names, correct heap comment | section 5, 4.4, 4.7 | ready-for-agent |
| #264 | Tests: one `assert_receive` timeout, shared helpers, events instead of guessed waits | 1.12, 1.13, 1.21, section 3 | ready-for-agent |
| #265 | Provider: remove the per-turn external mode (ADR 0002/0007 amendment) | 1.1, 1.2 | ready-for-human |
| #266 | Session file: exclusive ownership at create and resume | 4.3 | ready-for-human |

Later, after group 1 merges: the `harness_reply` kind change, then the Steers and Wait extraction (S1–S3, section 2b). The provider split (1.18) and the TUI version check (1.23) need ADR changes and have no ticket yet.
