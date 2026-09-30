# Review: #263, one source per number, units in names, the heap comment

Scope: `git diff origin/master` on `ticket/263-magic-numbers`. Every number of the ticket has one source, and every value stays the same:

- The notice bound: `Helyx.Provider.max_notice_bytes/0` (2,000). `Helyx.Session.Stream` and `Helyx.HarnessIO.cap_error/1` read it. Core cannot read a plugin, and a plugin should not read the internal `Session.Stream`, so the interface owns the contract value.
- The Text limits: `Helyx.Text.max_lines/0` and `max_file_bytes/0` next to `max_bytes/0`. The read and bash descriptions interpolate them ("2000 lines or 50 KB"). The OpenAI tool call budget reads `max_file_bytes/0`.
- The session stop bounds: `@hands_stop_ms` is `Hands.State.release_ms/0` plus `@load_hands_stop_ms` (22,000 ms); the child-spec shutdown is `Server.State.harness_close_ms/0` plus `@hands_stop_ms` plus `@load_shutdown_ms` (30,000 ms). The accessors sit on the nested `State` modules because a nested `defstruct` cannot read the attributes of its outer module.
- `@harness_reply_ms 2_000` replaces five literals, with its reason. `@call_timeout_ms` and `@chunk_idle_ms` carry their unit.
- The `Helyx.Provider` and `Helyx.Event` moduledocs name the constants, as the ticket says. The turn id bound cites `Helyx.Message.harness_id?/1`.
- The heap comment in `Helyx.Session.File` states the real range: 768 MiB at 12 bytes per file byte, a rejection over about 24 MiB at 42.

## Checked names

All items exist on master after #258 to #262. None of the merges had fixed one. `@term_grace_ms` moved to `HarnessIO` in #260 and is not in this ticket.

## Simplify

- Simplification, altitude: the accessors on nested `State` modules. Kept: a nested `defstruct` cannot read outer attributes.
- Simplification, reuse, standards: the Provider moduledoc names private attributes, so a plugin author does not see the numbers. Kept: the ticket says "Name the constant in the doc. Do not copy the value."
- Reuse: cite `Helyx.Message.harness_id?/1` for the turn id bound. Applied.
- Efficiency: new compile-time dependencies (Server on `Hands.State`, Stream and HarnessIO on `Helyx.Provider`, OpenAI on `Helyx.Text`). Kept: that is the cost of one source.
- Altitude: the OpenAI budget and the read limit are different limits. Kept: the ticket asks for the link; the comment states that the budget also charges entry and fragment overhead, so the largest file a Write call carries is somewhat smaller (item 1.20 is out of scope).
- A deleted blank line in `hands.ex`. Restored.

## Round 1 (full)

Bounds sensor: `bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer`.

| Axis | Finding | Resolution |
|---|---|---|
| Standards | `@error_max_bytes` in HarnessIO now also bounds notices (judgement call) | kept: the name is the error text cut, and the comment names the notice bound |
| Standards | `connect_ms`, `prepare_ms`, `harness_ms.idle` stay struct literals (judgement call) | kept: each has one source, the struct default |
| Standards | "the rest of `@max_tools` waiting" is unclear | fixed: the wording names the limit first |
| Spec | `docs/features/coding-agent.md` named `@error_max_bytes` as the source of the 2,000 cut, and `@receive_timeout` | fixed: the rows name `Helyx.Provider.max_notice_bytes/0` and `@chunk_idle_ms` |
| Spec | `div(max_bytes, 1024)` rounds down for a limit that is not a multiple of 1,024 | kept: the text then states less than the limit, never more |
| Failure path | the `@max_open` comment split the 8 as 1 turn + 1 interrupt + 1 close + 5 steers; the pool has no reserved slots, and `harness_test.exs` holds 8 steers open at once | fixed: the comment says one shared pool, and that steers can fill all 8 |
| Codex | approve, no findings | none |

The one reproduced finding was a wrong comment, with no behavior change; the fixes are comments and docs, so no rerun round.
