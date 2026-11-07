# 2026-11-07: before_settle and the continue turn (#880)

Follow-up 2 of ADR 0013, on top of the Hook interface of #879.

## Done

- `Helyx.Hook.before_settle/1`, its point in `points/0`, and the Core start check of its limit and of the name of the plugin (`{:invalid_hook_name, module}`, the origin id bound).
- The chain: a part of the wait after a done turn that is not a compaction (`Helyx.Session.Server.Settle`, `Wait.settle`). The hands run it in a chain Task of their own (`Helyx.Session.Hands.Settle`), with the hook Tasks of #879 (`Hooks.start/4` takes a chain Task as caller). The answer comes back as `{:settle_answer, ref, answer}`, matched by ref.
- The continue: a user message with the origin `%{kind: :hook, id: inspect(module)}`, held in the queue; it starts the next turn after a waiting compaction and ahead of the queued steers and follow-ups. At most 8 in a row; a client message resets the count.
- Fail open with a notice; an abort cancels the chain with the Tasks of the ended turn; a waiting continue is dropped at an abort or a failed turn.
- The `hook` entry takes `before_settle` and `continue`.
- The wire: origin kind `"hook"`, protocol 4, the schema hash, and the fixtures.

## Broke

- A global replace of `"protocol": 3` in the fixtures also turned the cases of "another protocol" into the server's own number; fixed to 3.
- Precommit failed on Credo's struct field bound: two new fields made `Helyx.Session.Server.State` 33 fields, over 31. The waiting continue and the count moved into `Helyx.Session.Queue`, whose abort and drain already run at the points that need them; a reduced review round followed.
- The failure-path agent of round 2 died at the usage limit of the model account; it was rerun after the reset.
- `hands.ex` and `turn_loop.ex` passed 400 lines; `asker/2` moved to `Helyx.Session.Ask`, which owns the kind of an asker, and the new code went to modules of its own.

## Next

- Print mode ends at the first `turn_end` and misses a continue turn; no event says that the session settled. Reported for the owner (feature doc, "Out of scope").
