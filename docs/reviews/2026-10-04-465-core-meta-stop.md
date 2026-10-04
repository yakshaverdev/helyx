# Review: a missing Core meta key raises ArgumentError (#465)

Date: 2026-10-04. Base: `origin/master` 1dae94d.

Invariant: `Helyx.Core.provider_ids/1` and `Helyx.Core.plugins/2` raise `ArgumentError` both when the sessions Registry table of the Core is missing and when the table lacks a meta key, so `Session.set_model/2`, which rescues `ArgumentError`, returns `{:error, :session_not_found}` after the Core stopped. Accepted hole: `Session.start/2` and `Session.resume/2` do not rescue and raise when the Core is gone, as before the change; their callers in this repo (`CodingAgent.start_session/1`, `mix helyx.graph`) run only while the Core lives.

## Bounds sensor

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Simplify

All four angles clean. Skipped: move the observed run out of the comment, because the ticket asks for it at the line.

## Round 1 (full)

| Axis | Finding | Resolution |
| --- | --- | --- |
| Standards | The comment said "which the callers rescue"; `Session.start/2` and `Session.resume/2` do not | Fixed: the comment names `Session.set_model/2`. |
| Standards | History in a code comment | Kept, the ticket asks for it. The guess "while the table was being deleted" is cut. |
| Spec | The new test is beyond "no new test is needed" | Kept: it builds the state the race leaves (a table without the keys) and fails without the fix (MatchError). |
| Spec | Same comment claim as Standards | Fixed, as above. |
| Failure path | `:error` also comes from the window between `:ets.new/2` and `:ets.insert/2` of a Registry start (Elixir 1.19.5 `Registry.Supervisor.init/1`): 1 of 16,553 reads during 200 Registry restarts in a running Core. The message "is not running" was false there | Comment fixed: it names the start window. The message is now "holds no <key>". The behaviour is right: every read in the window raises `ArgumentError`. |
| Failure path | Same comment claim as Standards | Fixed, as above. |
| Codex adversarial | Approve, no material findings | None. |

Not reached: `:error` while a table is deleted; a new Core with the same name while an old caller reads.

No defect was reproduced, only comment claims, so the loop ends after round 1.
