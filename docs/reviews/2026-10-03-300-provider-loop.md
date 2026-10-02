# Review: #300, Helyx.Provider.Loop and the deletion of the local turn path (one-provider-path step 3)

Scope: `git diff origin/master` on `ticket/300-provider-loop`. The change builds `Helyx.Provider.Loop`, L2–L4 of "Process lifetime", and the deletion of the local path in `docs/features/one-provider-path.md`.

Invariant: every provider runs in its provider process. An API provider runs there through `Helyx.Provider.Loop`, which runs one model call at a time in a model Task linked to the provider process (L1, L2), kills that Task before its `:ok` to an interrupt (L3), sends the calls of a message to Core one at a time in call order with a per-turn request id, and holds a steer of the live turn until before the next model call, and rejects it after the terminal. The entry points are `Loop.request/3` and `Loop.info/2` through `Helyx.Session.ProviderProcess`, and `Session.prompt/2`, `steer/2`, `follow_up/2`, and `abort/1`.

Accepted holes:

- `Process.exit(self(), :normal)` in a provider callback (the stated limit of L1).
- A model call, and the model calls of a turn, have no bound: the user aborts them (Bounds).

Documented exception: a stream event outside the stream set, a `rejected_tool_call` whose reason is not valid UTF-8 of at most 1,024 bytes, or an enumerable that halts by itself on a value that is not a terminal, ends the provider process with `{:bad_stream_event, event}`, as a malformed provider event does.

Author decisions that the spec leaves open:

1. The tool request id is a per-turn counter ("0", "1", ...) mapped to the call id, so a model that repeats a call id in one turn still gets each call run.
2. After a tool result, the helper goes on with a message to itself, so a result that Core sends at an interrupt, before the helper sees the interrupt, starts no `need_context` for a turn that is not live.
3. A steer held at a done with no calls: `message_end` (when the message has content), the `user_message` events, then `need_context`.
4. A `tool_request` with an integer over the digit limit gets the result "tool call not run: <reason>" from the provider process (was `Turn.rejection`).
5. `use Helyx.Provider.Loop` also declares `@behaviour Helyx.Provider`, so no provider file grows.

## Round 1 (full)

Bounds sensor, against `origin/master`:

```
bounds sensor: 17 candidate functions, 5 flagged, 0 without an answer
  lib/helyx/provider/loop.ex:115  SIZE  def request({:steer, turn_id, steer_id, text}, from, %{turn:
  lib/helyx/provider/loop.ex:275  SIZE  defp consume(stream, parent) do
  lib/helyx/session.ex:124  SIZE  def resume(core \\\\ Helyx.Core, opts) do
  lib/helyx/session/provider_process.ex:94  WAIT  defp loop(proc) do
  lib/helyx/session/server.ex:341  SIZE  def handle_info(
```

The held steers are bounded by the 32 steers of the session (`queues.ex`, held steers count until their `user_message`). `consume/2` is the model Task; see the spec finding 1. `resume/2` and `handle_info/2` are renames only. The loop has no deadline of its own: each request has its armed kill.

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. The text "tool call not run: " in two modules. 2. `call/4` took the event and the call. 3. Two `cond` branches of `terminal/2` did the same thing. 4. `Gated.Local` named a deleted concept. 5. "connected turn" in moduledocs. 6. `check/1` returns a rejection that only `tool_request` uses. 7. Appends with `++` per call. 8. Two checks of a call (`tool_call` and `tool_request`). 9. `settle/1` in the gate polls. | 1. `Stream.not_run/1`. 2. `call/3`. 3. One branch. 4. `Gated.Loop`. 5. Fixed in `event.ex`, `provider.ex`, `hands.ex`, `queues.ex`, `steers.ex`, `session.ex`. 6.–8. Skipped: the counts are bounded by the model output, and the return shape stays one shape. 9. Kept: the test must hear of the gate only after the session has the events before it, and only the provider process knows when it forwarded them. |
| Standards | No hard violation. Judgement calls: 1. A bad reason ends the whole process. 2. A public helper uses the internal `Helyx.Session.Stream`. 3. The unused rejection of `check/1`. 4. `run_on_hands/2` is a middle man. 5. The moduledoc of `Loop` is long. 6. The field names `n` and `content?`. | 1. The documented exception: the same rule as a malformed provider event. 2. Kept: Core code (Decision Q1). 3. As simplify 6. 4. Kept, with its comment. 5. Kept: it is the contract of a public adapter. 6. Kept, each has its comment. |
| Spec | 1. The model Task sent with `send_checked/2` to the provider process, so a slow provider process gave the reason `session_behind`. 2. No test ran OpenAI through the helper. 3. `:no_turn` keeps its name. 4. The PR lists the changed tests. | 1. Fixed: a plain send; the session check in the provider process is the bound (accepted hole 3). The test of the cap is gone. 2. New test "through the helper, a rejected call gets its result and a good one goes to Core" in `openai_test.exs`. 3. Kept: the start error name is outside this ticket. 4. In the PR. |
| Failure path | 1. Reproduced: a stream that ends its Task with a `:normal` signal leaves the turn open: no catch sees it and the link does not carry it. | 1. Fixed: `info/2` takes the `:DOWN` of the model Task as `{:failed, reason}`. The "exit_normal" model joins the test "a raising, throwing, or exiting stream gives task_exit". |
| Codex adversarial | 1. Reproduced: a steer accepted while a context is built did not reach the next model call; the model got the old context. | 1. Fixed: at a context with held steers, the helper sends their `user_message` events and a new `need_context` before any model call. New test "a steer held while the context is built goes out before the model call". |

Round 1 reproduced two defects. The fix changes `loop.ex` by more than 15 lines, so round 2 is a full round.

## Round 2 (full)

The bounds sensor flagged the same five functions as in round 1 (`loop.ex:117`, `loop.ex:288`, `session.ex:124`, `provider_process.ex:94`, `server.ex:341`).

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. A literal 5,000 ms wait in the new OpenAI test. 2. `loop_events/2` in the OpenAI test copies `pump/2` of the Loop test. 3. A context built while a steer is held is thrown away, and a second one is built. | 1. `wait_ms/0`. 2. Kept: the two tests are in two Mix projects. 3. Kept: C2 says the session applies the `user_message` events before it builds the context, and a steer during a build is rare. |
| Spec and standards | 1. The spec row of `{:context, id, {:ok, context}}` did not name the held steer. 2. L2 did not name the `:DOWN`. 3. The Bounds row of the provider process mailbox did not cover the model Task. | 1.–3. The spec rows now state the code. |
| Failure path | 1. Reproduced: with the plain send, a fast stream grew the provider process mailbox past 1.8 million messages, and an abort waited 2.9 s behind it. The session check never failed, because the provider process was the slow side. | 1. The second finding on the mailbox bound (after spec 1 of round 1), so the mechanism changes: `Stream.send_checked/3` takes the name of the receiver, and the model Task sends with the cap of 10,000 and the reason `{:provider_behind, length, 10_000}`. The test of the cap is back with the new reason. Accepted hole 3 is gone. |
| Codex adversarial | 1. Reproduced: an enumerable that halts by itself on a delta gave the delta as the Task result; the helper sent it as an event and cleared its turn, so the session turn stayed open. | 1. `terminal/2` takes only a terminal (a `done`, an `error`, or a value that `run/5` makes); any other result ends the provider process with `{:bad_stream_event, value}`. The "self_halt" model joins the test of bad events. |

Round 2 reproduced two defects. The fix changes the arity of `send_checked`, so round 3 is a full round, and it is the last.

## Round 3 (full)

The bounds sensor flagged the same five functions (`loop.ex:120`, `loop.ex:295`, `session.ex:124`, `provider_process.ex:94`, `server.ex:341`).

| Axis | Findings | Resolution |
|---|---|---|
| Simplify | 1. The doc of `send_checked/3` still said "to the session". 2. Its spec allowed any atom as the receiver name. | 1. and 2. Fixed. |
| Spec and standards | No defect. 1. A Bounds row named `send_checked/2`. 2. The moduledoc said "at 10,000"; the check is over 10,000. 3. The moduledoc did not name L4 (a kill of the model Task by a linked process ends the provider process). 4. The record said "any other result"; a value that `run/5` makes is also a terminal. | 1.–4. Wording fixed. |
| Failure path | No defect. Both fixes of round 2 hold through a session: under a flood of 2,000,000 deltas the provider process queue stayed under 3,500 and an abort took 20 ms; a self-halting enumerable ends the provider process and the next prompt works. A suspended session gives `session_behind`, a suspended provider process gives `provider_behind`. | None. |
| Codex adversarial | Approve, no findings. | None. |

Round 3 reproduced no defect, so the loop ends. Not reached: the growth of `calls` in one message with millions of tool calls (memory, as on the local path before), and events of a large byte size (the cap counts messages).

Precommit with `HELYX_SLOW=1`: the first run failed one slow test, "abort kills the child of a shell that already exited" (`bash_test.exs`), which found the tool Task by the `:helyx_hands` key and now also found the provider process. The test now leaves out the provider process, as the other two such tests do. The second run passed.
