# Review: #577 Background bash runs whose end wakes the session

Invariant: a tool call that asks `Helyx.Tool.background/0` for a place gets one of 16 places of its session, freed exactly once when its Task ends (a normal end, a crash, a cancel, an abort, or the stop of the session); `Helyx.Tool.started/1` gives the call its result at once, and the Task leaves its turn, so no `request_cancel/2` or `kill/3` reaches it. Its end text goes to the session as a background end, and no abort, failure, or end of the provider process drops one: in a `submitted` turn that is not a compaction it goes as a steer while the 32 steers have room, and as soon as room frees; while idle and not held it opens a turn; an abort, a failed turn, or a resume holds the ends until a prompt or a provider turn opens. A resume derives a lost end for each start in the transcript with no end. The session stop deletes the background folder (mode 0700) after the hands stop. Bash adds `background: true`, an output file of at most 64 MiB, and a background `timeout` of 1 to 86,400 s (default 3,600). Entry points: `Helyx.Tool.background/0` and `started/1`; `Helyx.Session.Hands` (`:background`, `:started`, the cancel, the delivery); `Helyx.Session.Background` (`reserve/3`, `start/2`, `finish/2`, `lost/1`); the server's `{:background_end, text}` and `init/1`; `Helyx.Session.Server.Steering` (`open/1`, `send_ends/1`, `take/2`, `answer/3`); `Helyx.Session.Queue` (`ends`, `hold`); `Helyx.Session.Server.Stop.run/1`; `Helyx.Tool.Bash.run/2`.

Accepted edges, in `docs/features/background-bash.md`: after an abort, a failure, or the end of the provider process an end is delivered at least once, not exactly once (the session cannot know if the provider took a sent end with no `user_message`); the "Open" section (ends that wait in a `submitted` turn while the steers are full have no count bound; a crashed session leaves its folder; an abort between the start and the read of the start answer drops that answer; a foreground result that starts with the exact start line counts as a start at a resume).

## Round 1 (full)

Base `origin/master` (`df5d4db`). The reviewed state is kept as commit object `e1340b8` (on no branch).

Simplify, four agents. Applied: one `timeout/4` for both modes in bash; `Queue.plain/1` public, used by `Steering.send_steer/2`; one regex in `Background.lost/1`; a `write` clause that only counts bytes past 64 MiB; `@describetag :tmp_dir` in the hands tests; `background/0` gives the id and the session folder, and bash names its own file; one text for "only a tool call can run in the background". Skipped: derive `background_dir` from `instance_id` (the field names the folder that `Stop.run/1` deletes; one assignment); keep the id once in the hands (two fields read in two places, minor); `delayed_write` on the output file (adds lag for an agent that reads the file); a `dir_made?` flag in place of `mkdir_p` at each place (a folder deleted under a live session is made again; two syscalls per start); a shared Core cap helper (outside the diff); one `task_of/2` lookup for `hold` and `background` (the turn checks differ); a home field in the steer ledger in place of `{:end, text}` (a wider change of the ledger; `plain/1` is one function).

Bounds sensor:

```
bounds sensor: 24 candidate functions, 3 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:182  WAIT  def hold(handle) do
  lib/helyx/interfaces/tool.ex:205  WAIT  def background do
  lib/helyx/interfaces/tool.ex:219  WAIT  def started(text) when is_binary(text) do
```

The three flags are `GenServer.call/3` to the hands with no timeout, as `hold/1` on master. The handlers update a map or make one folder; accepted as for `hold/1`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 1.1 | failure path, spec, Codex | A cancel killed a Task that held a place between `background/0` and `started/1` and never freed the place; 16 aborts in that window left the session with no place (reproduced) | Fixed: the cancel drops the places of the Tasks it kills. Test: hands_test, "a cancel between the place and the start answer frees the place" |
| 1.2 | failure path, spec | A compaction turn cleared the hold, so a held end woke a turn that no one asked for (reproduced) | Fixed: `Steering.open/1` runs only from `begin_turn` and `start_provider_turn`. Test: background_delivery_test, "a compaction does not end the hold of the ends" |
| 1.3 | Codex | An end that waited for steer room stayed queued after `take/2` or `answer/3` freed room (reproduced) | Fixed: both send the waiting ends. Test: background_delivery_test, "an end that waits for steer room goes in the same turn once a steer frees its place" |
| 1.4 | spec | An end sent as a steer was dropped at an abort: `steer_unconfirmed`, then a late `:rejected` deleted it (reproduced, P2), against owner decision Q3 "an abort never drops them" | Fixed: an abort, a failure, and `provider_down` put every sent end that no `user_message` took back at the front of the ends. Accepted edge: at least once (feature doc). Test: queue_test, "an abort, a failure, or the end of the provider process gives back every end that no user_message took" |
| 1.5 | failure path, spec | The bounds row said the start answer goes through `Message.cut_result/1`; the code caps it at 4,096 bytes | Fixed: the row names the 4,096-byte cap, and the answer goes out through `checked/1` |
| 1.6 | spec | The lost text "stopped before this background run ended" is false for an end that waited in the queue | Fixed: "stopped before the end of this background run reached it" |
| 1.7 | standards | Three files over 400 lines: `hands.ex` 472, `turn_loop.ex` 411, `session.ex` 405 | Fixed, see "Fix size" |
| 1.8 | standards, spec | The 200-byte first line had only an over-limit test | Fixed: 199, 200, over, and multibyte |
| 1.9 | standards | `started/1` outside the hands exited with `:noproc`, not the documented `ArgumentError` | Fixed: it raises. Test: hands_test |
| 1.10 | standards, spec | No test that the session stop ends a live background run | Fixed: bash_test, "the session stop ends a live background run" |
| 1.11 | standards | `openai_test.exs` passed the system temp folder as the background folder; a background call would `chmod` it | Fixed: a subfolder that is never made |
| 1.12 | standards | The lost text names an output file, a bash construct, in Core | Judgement, kept: the folder is a Core construct, and the only tool of the ticket has a file |
| 1.13 | standards | Names: `checked/1`, `Queue.open/1`, `Out`; `if` in `Bash.run/2` and `start_queued/1`; `render/1`, `add/2` public for tests | Judgement, kept: each name matches its use in the module; the public functions are `@doc false` |
| 1.14 | standards | A second `started/1` from a background Task gets `:ok` | Judgement, kept: the place exists and the call is in the hands; no caller makes it |
| 1.15 | standards | `Stop.run/1` drops the result of `File.rm_rf/1` | Judgement, kept: the session stops in any case; the "Open" section names a folder left behind |

Guarantees with no test after round 1, from the spec table: an end that arrives in `preparing`, in `submitting`, or in a wait (code read: `send_ends/1` at the send and at the `:ok`); the background `timeout` default of 3,600 (one test would wait an hour); the harness provider and TUI paths (no test of a harness with a background tool); an unconfirmed handle that gives `error` (probe P4 only).

### Fix size

Without tests and Markdown, the fix is 199 lines added and 156 removed in `lib/`, so round 2 is a full round. The coordinator was told before round 2.

- Moves, about 165 lines. `Helyx.Session.Hands.Release` takes the release of handles (`run/4`, `retry/2`, `still_held/2`, `add/2`, `error/1`): it owns the decision of which handles a release frees, and when a release is tried again. `Helyx.Session.Background.reserve/3` takes the place rules (one per call, at most 16, the folder made with mode 0700): it owns the decision of whether a call gets a place. The lost-end derivation moved from `Helyx.Session.resume/2` to the server's `init/1`; it stays in the one function `Background.lost/1`, so #579 finds it in one place.
- Logic, about 90 lines: the fixes 1.1 to 1.6 and 1.9.

Round 1 reproduced defects, so round 2 runs.

## Round 2 (full)

Base `e1340b8`, the reviewed state of round 1. The briefs name the invariants that the fixes restore: (a) each background place is freed exactly once, whatever ends its Task; (b) the hold changes only when a prompt or a provider turn opens; (c) a waiting end goes when steer room frees, from every path that frees room; (d) no abort, failure, or end of the provider process drops an end.

Simplify, four agents. Applied: `return_ends/1` uses the ledger fold `map/2`; the cancel binds the pids once; `push_end/2` sends the ends, so the server does not; `Background.lost/1` reads only the first text part of a message, not the joined text of each message; a comment states why `end_turn/3` gives the ends back before `abort/1`; `started/1` is a `with`. Skipped: keep the place in the `tasks` entry and count live runs from it (two agents; a fifth tuple field in every pattern of the hands, which are at 400 lines; the cancel was the first finding on the place map, so a second one moves the place into `tasks`); `send_ends/1` inside `put/2` (`send_ends/1` calls `put/2`, and the turn reaches `submitted` outside `put/2`, so the explicit calls stay); the literal of `not_a_call/0` in `Helyx.Tool` (the interface already speaks the hands protocol, and one text has one source); make the folder once at the start of the hands (round 1 skip); the lost-end scan in `Session.resume/2` or `handle_continue` (the first-part match makes the scan read only the head of each message).

Bounds sensor (base `e1340b8`, after simplify):

```
bounds sensor: 13 candidate functions, 2 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:205  WAIT  def background do
  lib/helyx/interfaces/tool.ex:219  WAIT  def started(text) when is_binary(text) do
```

The same two flags as round 1, accepted as for `hold/1`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 2.1 | failure path, spec | Regression of fix 1.3: `answer/3` sends the waiting ends, so an end that the provider answers `:rejected` went back to the ends and was sent again at once, with no bound until the turn ended (reproduced: 25,746 steer requests in 200 ms with `conn/steer_reject`). A real provider does it: the Codex answer "no active turn to steer" maps to `:rejected` before `turn/completed` (`docs/research/codex-app-server.md`) | Fixed in the mechanism: a `:rejected` end sets `Queue.rejected`, `Queue.next_end/1` gives nil while it is set, and `Queue.open/1` clears it, so no end goes as a steer again until the next prompt or provider turn, as a rejected steer waits for the next turn. Tests: queue_test, "a sent end that is rejected goes back to the ends ..."; background_delivery_test, "an end that the provider rejects waits for the next turn and is not sent again in its turn" |
| 2.2 | Codex, spec | An idle `provider_down` that comes before the session's `:DOWN` gave an end back and did not settle, so the end waited for another event (reproduced by the spec agent with an injected `provider_down`) | Fixed: the idle clause runs `settle/1`, as the wait clause does through `progress/1`. Test: background_delivery_test, "an end sent with no answer in a turn that ended goes back and wakes the session when the provider process ends" (it runs the order that the runtime gives, `:DOWN` first, through the wait clause; the idle clause, `provider_down` first, has no test in the tree, only the spec agent's probe P1 of round 3, which injects `provider_down`) |
| 2.3 | standards | Bounds rows named `@max_background` in the hands and `@retry_ms` in `start_provider/3` after the moves | Fixed: `@max_live` in `Helyx.Session.Background`, `@retry_ms` in `Helyx.Session.Hands.Release` |
| 2.4 | standards | The steer-room test counted `turn_start` in events that stop at the first `turn_end` | Fixed: the last user text of the turn proves the same turn |
| 2.5 | standards | No test that `provider_down` keeps `hold`; the lost text was pinned by its first words only | Fixed: both asserted |
| 2.6 | standards | `init/1` sets `hold` for a new session too | Fixed: a comment says a new session has no ends |
| 2.7 | spec | The bounds row of the waiting ends did not name the wait after a rejection | Fixed |
| 2.8 | spec | The `started/1` doc says it raises with no place; a provider-process Task gets `:ok` | Fixed: the doc names the cases that raise (outside the hands, a tool call with no place) |
| 2.9 | spec | No test that a crash or `kill/3` frees the place | Accepted on code read: both go through `deliver/3`, which drops the place, as the normal end does (hands_test, "16 runs are live at most") |
| 2.10 | standards | `Hands.Release` has no `@spec`; `reserve/3` reserves nothing; the steer-room test reads internal state | Judgement, kept: `Release` is `@moduledoc false`; the hands store the place that `reserve/3` grants; the existing `finish/2` helper reads the state the same way |

Invariants (a), (b), and (d) held on the probes of the failure-path and spec agents: every place is freed once in `deliver/3` or the cancel, only `Steering.open/1` clears the hold, and `return_ends/1` runs in every abort, failure, and `provider_down`. Invariant (c) broke by 2.1. Findings 2.1 and the round 1 finding 1.3 are two findings on the sending of ends, so 2.1 is fixed in `Queue`, not in `answer/3`.

Round 2 reproduced defects, so round 3 runs. The round 2 state is kept as commit object `72acd0f`.

## Round 3 (full)

Base `72acd0f`. The fix of round 2, without tests and Markdown, is 30 changed lines in four code files (`queue.ex`, `turn_loop.ex`, `server.ex`, `tool.ex`), with a new clause of `Queue.next_end/1` and a new struct field, so round 3 is a full round.

Simplify, two agents with two angles each. Applied: `rejected: boolean()` in `Queue.t()`; the idle clause calls `settle/1`, which is all that `progress/1` does for `:idle`. Both agents found the `rejected` flag necessary: `hold` also stops the wake, and a rejected end must wake an idle session.

Bounds sensor (base `72acd0f`):

```
bounds sensor: 3 candidate functions, 1 flagged, 0 without an answer
  lib/helyx/interfaces/tool.ex:205  WAIT  def background do
```

The same flag as rounds 1 and 2, accepted as for `hold/1`.

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 3.1 | Codex | Verdict approve, no material finding | — |
| 3.2 | spec | No defect. Probes: a late `:rejected` while idle wakes one turn with the end; a rejection then an abort holds the end for the next prompt; an injected idle `provider_down` before `:DOWN` wakes a turn with the end (P1) | — |
| 3.3 | failure path | No break of (b), (c), or (d). Probed: a late `:rejected` while idle (one turn, no second steer) | — |
| 3.4 | failure path | An end whose steer gets an error answer, or a late answer other than `:rejected`, and no `user_message` gets `steer_unconfirmed` with its text and is not sent again (reproduced with `conn/steer_error`) | Accepted: the feature doc rule since round 1, "as for a steer"; the doc now names an answer other than `:rejected`. Owner question in the report: should such an end go back to the ends instead |
| 3.5 | failure path | A failed compaction sets `hold`, so an end that waited unheld waits for the next prompt (reproduced) | Accepted: the doc says a failed turn sets `hold`; the invariant (b) is about the clear. Named in the report |
| 3.6 | spec | The idle `settle/1` clause has no test in the tree; the runtime gives `:DOWN` first | Recorded in row 2.2; probe P1 only |
| 3.7 | spec | "until the next turn opens" did not exclude a compaction | Fixed: "the next turn that is not a compaction" in the doc and the `Queue` comment |
| 3.8 | standards | A late `:rejected` in a later turn stops the ends of that turn too | Fixed in the doc as an accepted edge: the ends wait and are not dropped |
| 3.9 | standards | Comments: "(no order)", the `next_end/1` comment, the test comment that named two orders; row 2.2 named `progress/1` | Fixed |

Round 3 reproduced no defect against the feature doc, so the loop ends. Its fixes are docs and comments.

## Owner decisions after the gate (2026-10-14)

The Codex gate r1 on `740fea5` approved with no findings. The owner decided the open items:

1. Changed: an end whose steer gets an answer other than `:rejected` (an error, or a late answer after its turn) and no `user_message` goes back to the front of the ends with `hold` set, as after an abort. It gets no `steer_unconfirmed` and is not dropped (row 3.4).
2. Kept: a failed turn and a failed compaction set `hold` (row 3.5). A failure often repeats, and a wake would start a turn that fails again with no user present.
3. Ticket decisions, not review findings: "an abort never drops them" (#577 Q3) and "derived, not stored" (#577 Q4).
4. The two open holes are #587: no count bound for ends that wait in a submitted turn while the 32 steers are full, and a crashed session leaves its background folder.

## Round 4 (full, owner exception)

Base `740fea5`. The change of decision 1, without tests and Markdown, is 65 changed lines in `queue.ex` and one comment line in `turn_loop.ex`. It adds `give_back/2` and changes `return_ends/1` to `return_ends/2`, so the round is full. The 45-minute limit and the three-round limit are passed as an owner exception. Invariant given to every reviewer: "an end is never dropped; each path that does not deliver it puts it back in the ends exactly once, held."

Simplify, four agents (reuse, simplification, efficiency, altitude). Applied: the notices no longer call `plain/1`, as no end reaches them. Skipped: give back every untaken end at a normal end of its turn, with no `{:ended, _}` state for ends. It is simpler, but a late `:rejected` would then not wake the session, which changes the documented behaviour that decision 1 keeps. The stale `hold` after a give-back in an open turn is documented as an edge.

Bounds sensor (base `740fea5`):

```
bounds sensor: 3 candidate functions, 0 flagged, 0 without an answer
```

| # | Axis | Finding | Resolution |
| - | ---- | ------- | ---------- |
| 4.1 | Codex | Verdict approve, no material finding (24 queue tests, 48 probes) | — |
| 4.2 | failure path | No second path breaks the invariant. Probed: a late `:ok` in the next submitted turn, an error answer there, an idle abort then each late answer | — |
| 4.3 | failure path, spec, standards | A rejected end goes to the back with `rejected` and no `hold`, against the "each path ... held" texts | Fixed in the texts: a rejected end is the one exception, as the round 2 design and the existing test state |
| 4.4 | spec | The new provider-end test read the state after `{:release, ...}`, before the session got `{:provider_down, ...}`: 3 of 6 runs failed | Fixed: the test traces the session until it receives `{:provider_down, ...}`; 16 runs passed. A test defect, not a code defect |
| 4.5 | spec | No test for a failed compaction that sets `hold`, nor for a held end that an open turn still sends | Fixed: a session test of a failed compaction; a queue test that a held give-back does not wake and `next_end/1` still gives it |
| 4.6 | spec | The bounds row of the waiting ends did not count given-back ends, and named "open" with no ticket | Fixed: at most the 32 ledger entries; #587 |
| 4.7 | spec | "In send order" is true only within one give-back | Fixed: "in send order among them" |
| 4.8 | standards | `session-lifecycle.md` said every steer with no `user_message` gets `steer_unconfirmed` | Fixed: a clause names the background end |
| 4.9 | standards | The flag argument `which` of `return_ends/2`; a guard that would crash on an end in a notice | Judgement, kept: two values, one private function; the clause order and `return_ends/2` keep ends out of the notices (probe of 4.2) |

Round 4 reproduced no code defect: its fixes are tests, docs, and comments, so the loop ends.
