# Review: #840, the `terminate/2` of the hands

Base: `addb2a1a` (merge base with master). The change was uncommitted during the review.

The ticket asked to delete `Helyx.Session.Hands.terminate/2`, on the claim that no Task in the repository traps exits, so the link of `Task.Supervisor.async` ends every Task on every end of the hands other than the stop call. Round 1 refuted the claim with a probe. The commit keeps `terminate/2` and states the case that it covers, in its comment and in rule 10 of `docs/features/tool-resource-release.md`.

## Round 1 (full), on the deletion

Invariant under review: after the deletion of `terminate/2`, no Task of the hands outlives the hands.

Simplify: it took out a word ("here") that the change had added to the comment on the callbacks of the hands. It found no stale comment on the deleted callback.

Bounds sensor (`bounds_sensor.py --diff addb2a1ac76c4a7c761641d98f366c88042d75e2`):

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

Agents: standards, spec, failure-path, and the Codex adversarial review (verdict: needs-attention).

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 1 | Codex | `Helyx.Reason.task/2` turns on the trap of exits in a provider Task before the crash log. Logger runs plugin code there, such as the `message/1` of an exception, and that code can block. A provider Task stuck there outlives an end of the hands that is not the stop call. | Yes. Probe: hands started with `start_link/1` under a spawned parent, then `start_provider/3` with a fun that raises an exception whose `message/1` blocks. Before the kill, the provider Task showed `trap_exit: true` and `current_function: {BlockEx, :message, 1}`. The parent was killed and the hands ended with `:killed`. With the deletion, the provider Task was still alive 300 ms after the `:DOWN` of the hands. At `HEAD`, it was gone. | The deletion is dropped and `terminate/2` stays (`/implement`: a probe that reaches the state stops the change). Its comment and rule 10 name the case. |
| 2 | spec | The review record that the feature doc cites did not exist yet. | read | This file. |
| 3 | standards | "A crash of the session before the stop call" is loose: a crash in a session callback still reaches `terminate/2` of the session, which sends the stop call. | read | Rule 10 names `Helyx.Session.Server.Stop.run/1`. |
| 4 | standards | Judgement calls: the accepted hole of a plugin Task that traps exits belongs in the `Helyx.Tool` and `Helyx.Provider` moduledocs; the #840 text should be its own numbered rule. | n/a | Moot: with `terminate/2` kept, the hole is gone, and the text is a note on the replaced mechanism of rule 10. |

The ends of the hands other than the stop call, probed in round 1 with the deletion in place (all used `test/abort`, with a running tool Task):

- A kill of the session: the hands and the tool Task end with `:killed` (`test/helyx/session/loop_test.exs`, "killing the session kills the hands and the tool Task").
- A crash of the hands, from a `GenServer.cast/2` of an unknown message: the hands, the tool Task, and the provider process end with `:function_clause`.
- A crash of `Stop.run/1` before the stop call: the session state was set to no turn, with a binary as the pid of its provider connection. `Process.monitor/1` raises `badarg`, and the hands and the tool Task end with that reason.
- An exit signal to the session with a reason that it traps: the hands, the tool Task, and the provider process end.

In each of these, the link ends a Task that does not trap exits. Only the Task of finding 1 needs the kill of `terminate/2`.

## Round 2 (reduced: spec and failure-path)

Both agents read `git diff addb2a1a` and this record. The invariant of the fix: no Task of the hands outlives an end of the hands. The first test was the reproduction of finding 1.

| # | Source | Finding | Reproduced | Resolution |
| - | ------ | ------- | ---------- | ---------- |
| 5 | spec, failure-path | Finding 1 holds with `terminate/2` kept: the parent is killed, and the provider Task is gone 300 ms after the `:DOWN` of the hands. Two other ends break the invariant. (a) `Process.exit(hands, :kill)`, the kill of `Stop.stop_hands/1` after its wait: no `terminate/2` runs, and the provider Task stays in `message/1`. (b) The same kill during a delivery: a release Task in the crash path of `Reason.task/2` is not in `tasks`, and it stays. | Yes, by a direct kill of the hands. The same at `addb2a1a`, so it is not a defect of this change. Neither agent reached the kill through a session: the stop call must wait more than 22 s, for example behind two deliveries whose releases each run to their 20 s deadline (read, not run). | A doc defect: the comment and rule 10 named the ends as if complete. Both now name the kill and its hole. Listed below under Open. |
| 6 | spec | No committed test covers the trapping Task, so a second deletion of `terminate/2` would pass precommit. | read | Open: the ticket asked for no test changes, and the time limit of `/ship` leaves no round for a new test. |

Round 2 reproduced no defect of the change: the code of the hands is the same as at `addb2a1a`, and only the text changed. So the loop ends here (`/ship`).

Precommit: Credo found `hands.ex` at 403 lines, over the limit of 400. The comment on `terminate/2` was cut to four lines that point to rule 10, and the file has 400 lines. That edit changed only the comment, so there was no review round for it.

## Open

- The trap of `Helyx.Reason.task/2` keeps a provider Task alive while plugin code in its crash log runs. `terminate/2` covers the ends of the hands. While the hands run, a provider Task blocked there stays until the hands end: it sends no `:DOWN`, so the hands never see its end. Whether `Reason.task/2` needs the trap is a question for its own change. No ticket, as the owner asked.
- The kill of the hands at the wait of `Stop.stop_hands/1` runs no `terminate/2`, so a provider Task or a release Task in the crash path of `Reason.task/2` stays (finding 5). The same at `addb2a1a`.
- No test of the trapping provider Task (finding 6).
