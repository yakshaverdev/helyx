# Review: a second context request that the session took as a new one (#811)

Scope: the working tree against the branch base `650c5e3c`. Files: `lib/helyx/session/server/prepare.ex`, `lib/helyx/session/server/turn_loop.ex`, `lib/helyx/session/turn.ex`, `test/helyx/session/provider_process_test.exs`, `test/support/interfaces.ex`, `docs/features/one-provider-path.md`, `docs/features/session-lifecycle.md`.

Invariant: a context request of a submitted turn stays open from the provider's `need_context` action until the provider's reply to the session's `{:context, ...}` request, so a second `need_context` that the provider sends before that reply is a bad action (the turn fails and the provider process stops) at any time of the prepare Task's end.

## Evidence

- The cause is in Core. The test provider sends two `{:need_context, id}` in one batch. The session takes the first and starts the prepare Task. When the Task replies before the second request reaches the session, the session sends `{:context, ...}`, and `Turn.prepare` is nil again. The old rule ("open" means a prepare Task or a summary call) then took the second request as a new one and built again. The provider's `:ok` and `done` ended the turn with no error. The test reads the one `turn_end` of its one turn, so the reading of a wrong `turn_end` is ruled out.
- The same action list gave a bad action or a second build, by the time of the Task. The provider process sends its actions and replies in order from one process, so only the provider's reply to `{:context, ...}` orders with its next request. The rule is now stated in C3 of `docs/features/one-provider-path.md`.
- Reproduction (`provider_process_test.exs`, "a second need_context before the reply to the context is a bad action"): suspends of the session and the provider process put the second request after the session sent the context, and before the provider got it. Before the fix: `left: nil`, the text of the ticket. After it: the test passes, and it passed 31 of 31 runs with the old test (`--repeat-until-failure 30`). The spec agent confirmed both results with a reverse apply of the fix.
- Every sender of `need_context` in the repo: `Helyx.Provider.Loop` replies `:ok` first, then sends its next request (`loop.ex`, `request({:context, ...})` and `request_context/2`). `test/support/summary.ex` sends its second request only while a summary call runs, which was a bad action before. Claude Code and Codex never send one (C5).

## Simplify

One agent. Three changes: a comment rewrapped in `turn.ex`, the comment of the reply clause in `turn_loop.ex`, and the added C3 sentence cut to one sentence.

## Round 1 (full)

Bounds sensor (`--diff 650c5e3c7ac0eec70c2c63de3b190e583dc8adb5`):

```
bounds sensor: 1 candidate functions, 0 flagged, 0 without an answer
```

| Axis | Findings | Resolution |
| ---- | -------- | ---------- |
| Codex adversarial | approve, no material findings | none |
| Standards | judgement: the `Turn` comment on `pending` left out `{:compact, ...}` | fixed |
| Standards | judgement: the armed kill of the context request (2,000 ms) runs while the test suspends the provider process; a stall of 2 s gives `:provider_timeout` | fixed: `@load_reply_ms` of 30,000 ms, the margin for load, stated |
| Standards | judgement: "replies to the answer" and "no context without its reply" are unclear | fixed: the docs and the comment name `{:context, ...}` |
| Standards | judgement: C3 states the rule in the parenthetical and in the new sentence | kept: the sentence states the rule for the provider |
| Standards | judgement: `Turn.pending` has three writers; the reply clause sets the phase from `reply == :ok`, which a context reply always is (`ProviderRequest.reply?/2`) | kept; a comment at the write in `prepare.ex` |
| Standards and spec | no committed test that a request after the reply is accepted | fixed: "a need_context after the reply to the context is accepted"; "context_hold" now holds the context with `{:held, from}` |
| Spec | the Bounds rows "1 per turn" and "No answer is awaited" are partly stale | fixed |
| Spec | the steer and the abort while a reply is pending have no committed test | not added: the agent's probes passed, and the change does not touch the steer and the abort paths |
| Failure path | none reproduced; six probes passed (accepted after the reply, the overflow form, an abort and a stale reply, a kill while pending, a steer while pending, a terminal and a late reply) | none |

The round reproduced no defect, so the loop ends. The fixes above are wording, docs, and tests.
