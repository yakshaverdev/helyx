# Review: local and external turns check the context of the plugins (#227)

Base: `origin/master` at `09d22d7`. Round 1 is the first and complete round.

## Change

`Helyx.Session.Stream.run/1` builds the context with the checked prepare that #199 added for a connected turn. The unchecked `prepare/4` is removed, and `prepare_checked/4` is renamed to `prepare/4`. A return of the ModelContext or the Compaction plugin that is not a `Helyx.Context` with exactly its three fields, a `system` that is nil or a string, and lists for `messages` and `tools` ends the provider call before `provider.stream/3` with `{:error, {:bad_context, plugin}}`. The rule is in `docs/features/session-stream.md`, "The context check (#227)".

Invariant: every turn mode checks the return of each plugin with `Helyx.Session.Stream.prepare/4` before a provider or a harness process sees it. The entry points are `run/1` (local and external turns) and the prepare Task of `call_provider/1` (connected turns). A bad return fails only that turn with a reason that names the plugin and never holds the value. The session stays, and the next turn runs again. Accepted holes, as in #199: the check does not look into the list elements, and a plugin that raises fails the turn with `{:task_exit, reason}`. Such a reason can hold the value in its stacktrace.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Reuse, efficiency, and altitude: clean. Simplification: the name `prepare_checked` was left over after the unchecked function was removed. Fixed: renamed to `prepare/4` in the code and in the feature docs. The review records of #199 keep the old name, because they record that point in time.

### Standards

No hard violations. Judgement call, fixed: a comment in `server.ex` was reflowed after the rename.

### Spec

1. The ticket asks for all five bad shapes "from each plugin". The ModelContext test plugin had no bad `messages` case, and the Compaction test plugin had no forged struct and no bad `system` case. Fixed: `bad_messages_build`, `forged_compact`, and `bad_system_compact` in `test/support/interfaces.ex`. The test now runs 10 shapes on a local and on an external turn.
2. `session-stream.md` said that the move of #120 changed no public function. That sentence is about #120. Fixed: a pointer to the new section follows it.

### Failure path

No reproduced findings. Probes: a struct with an extra key and `tools: nil` are rejected; `system: ""` passes; a throw and an exit in `build/2` give `{:task_exit, _}`, and the next turn succeeds. `system` that is not valid UTF-8 and an improper list pass the check. On a local turn the stream check or the provider stops them, and the session stays. These are in the accepted holes. Not reached: a real provider with invalid UTF-8 in `system`, and a Compaction plugin that raises on a local turn.

### Codex

Verdict: approve. No material findings.

## Result

Round 1 reproduced no defect, so the loop ends after one round. The fixes after the round are test cases, docs, and one comment reflow. They change no code behavior, so no further round runs.
