# Review: #870, schedules and wake-ups

Ticket #870, `docs/features/hub.md`, decisions 11 and 12: `hub.schedules.create`, `hub.schedules.list`, `hub.schedules.delete` and `Helyx.Hub.schedule/3` (`Helyx.Hub.Access`, `Helyx.Hub.Params`, `Helyx.Hub.Schedules`), the store queries (`Helyx.Hub.Store.SQLite.Schedules`), and wake-ups that are delivered at most once (`Helyx.Hub.Wake` in the Hub process, `Helyx.Hub.Delivery` as the delivery Task). Base: `ae492104`, the tip of `ticket/869-hub`.

The invariant: Hub sends each pending wake-up into its session at most once. The Task calls `Helyx.Session.prompt/3` only after its step-2 Hub call has applied a conditional write: the outcome `unconfirmed` and the next pending wake-up. That write applies only while the row still holds the run number and the `next_try_at` that the start of this Task wrote. Every other write of a Task or of the poll is conditional on the row values that the writer read.

Fast mode (owner, 2026-11-09): one round, made of the Codex review and the failure-path agent; no simplify, standards, or spec agent, and no second round.

Not in this change: the `#870` lines of the wire schema and its protocol number. The `hub.*` lines of #869 are not in `wire-protocol.md` on this base, and master is already at protocol 5. The lines go in when #869 lands its schema.

## Round 1 (fast: Codex, failure path)

Bounds sensor: `8 candidate functions, 0 flagged, 0 without an answer`.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Failure path, reproduced | Only the poll checked the 3,600 s life. A Task that started just before the end of the life could send up to about 120 s after it (probe: `last_at - due_at` = 3,602, and the prompt was sent) | Fixed: the place of step 1 and the write of step 2 check the life again and write `missed`. Test: `wake_test.exs`, "a Task whose wake-up passed its life after its start sends nothing" |
| 2 | Failure path, reproduced | The ended rows of a previous owner counted toward the 16 of the session for the default owner, who cannot list or delete them | Fixed: the count of a session is the rows of the creator plus the pending rows of others. An ended row counts only for its own user. Test: `sqlite_schedules_test.exs`. The pending rows of a previous owner still count until their next run: Accepted holes, "The schedules of an owner before a record delete" |
| 3 | Codex | A delete killed the Task with an async exit signal, so a send could begin after the reply of the delete | Fixed: a delete or a user remove kills the Task and takes its `:DOWN` (at most 1,000 ms) before the reply. Test: `wake_tasks_test.exs`, "a delete kills the Task of its schedule" asserts that the pid is dead at the reply. The kill timer at 120,000 ms keeps the entry until the `:DOWN`, so the guard of one Task per session still holds |
| 4 | Codex | The Task sent even when its Hub call after the resume failed, so the session stayed out of the live set | Fixed: the Task goes on only when that call answers `:ok`; otherwise the row comes due again. The live-set gap after such a call is listed with "A Task killed in its resume" (Accepted holes). Not tested: `busy` needs 1,024 messages in the mailbox of Hub during a resume |

Not reached by the failure-path budget: a session that hangs in the prompt call, a kill during `Sessions.resume/2`, a store that fails in `due/3`.

## Protocol 7 (after the rebase on master with #869)

The `#870` lines of the wire schema were added as protocol 7, with the SHA-256 of the block. Both clients speak 7 and take `too_many_schedules` and `unknown_schedule`: the TUI (`Helyx.TUI.Link`, `Helyx.TUI.Wire.Decode`) and the Rust core (`PROTOCOL`, `ERROR_CODES`). The fixtures move up by one protocol, and the refusal test now classes the three ops. Base: `fdfda19e`.

### Round 1 (fast: Codex, failure path)

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Codex | No fixture checks that a server with no authority answers the three ops with `unknown_op` | Fixed: three cases in `test/fixtures/wire/client_frames.json` |
| 2 | Failure path, not a defect | The Bounds row of `every` ("null, or 300 to ...") reads as if it allowed a null param. The server answers `bad_params` to one, as it does for any optional key of the schema that is present with null | Doc: the row now says that `every` is absent or an integer |

The failure path reproduced no defect. Every result and every error of the three ops conforms to the schema and passes the TUI decode, and the error code lists of the schema, the TUI, and the Rust core are equal. `test/helyx/tui_test.exs` has 23 failures in this environment on clean `origin/master` too: they come before this change, and the precommit host decides.
