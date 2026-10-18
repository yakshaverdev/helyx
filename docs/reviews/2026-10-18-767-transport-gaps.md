# Review: the open bounds and tests of the WebSocket transport (#767)

Scope: `Helyx.Transport.WebSocket.Connection` (the params check before the worker, `replied/3`, the hello guard), `Helyx.Transport.WebSocket.Ops` (`check/3` gives a closure of the checked params, `run/1`), `Helyx.Transport.WebSocket.Frame` (each decoded string is a copy), the comment of `silent_terminate_on_error` in `Helyx.Transport.WebSocket`, `Helyx.Test.WireClient.send_request/4`, the transport tests; `docs/features/wire-protocol.md`.

Invariant: every client request enters `Connection.handle_in/2`; the connection checks the params of every op with `Ops.check/3` before it starts the worker, and the decode makes each string a copy, so a worker, also one that waits for the encoder slot (`history`, `sessions.saved`), holds only checked values of at most the request size, and no worker, subscription, or session keeps the text of a frame; `replied/3` finds a subscription that waits for its subscribe reply by `state.acks`, so an unsubscribe handled before the subscribe reply gets `{}` when the sub ends after it; a `hello` whose `protocol` is not an integer of 0 or more closes with `4400`.

Accepted holes: a value that only Core checks, such as a `history` `limit` out of its range, answers after the slot wait; the decode, the copy of its strings, and the check run in the connection process.

## The items of the ticket

| Item | Result |
|---|---|
| 1. Params of a worker outside the byte bound | A defect, not only a doc gap: a `history` or `sessions.saved` worker waited for the encoder slot with the decoded params, which can be eight times their JSON text (measured: 1,000,001 bytes of `[0,0,…]` decode to 8,000,000 bytes). Fixed: the connection checks the params before the worker. Test: a request with bad params answers while the slot is held; it failed on the old code |
| 2. Abort and the event drain | Not a defect. Test on a loopback socket: the events that the session sent before the abort come, then `turn_end` with `aborted`, and no event of the turn follows it before `session_end`. It passes on the old code, so no fix. The abort row of the doc now says so |
| 3. `replied/3` by `state.acks` | Fixed. Test with a suspended connection and a session killed after the subscribe reply; it failed on the old code (`failed`, not `{}`) |
| 4. Tests | Reconnect race (a reconnect with `after` while the turn streams: the replay, then the live events, contiguous); deadline constants (`abort` and `stop` against `Hands.State.release_ms/0`, `State.provider_close_ms/0`, `Stop.shutdown_ms/0`); the encoder slot (a waiting `history` has no call in the session); a hello after a `503` (one status, closed, not logged); `1011` at a crash of the connection process. A socket error: covered since #763 by "a socket error stops with a crash report that holds a hello in fragments" |
| 5. Docs | The citations of `turn.ex` and `transcript.ex` in the tail row, and of the `abort`, `stop`, and `subscribe` deadline rows, now point at the lines; the reason of `silent_terminate_on_error` is at its line |
| 6. A negative `protocol` | Fixed: the guard `protocol >= 0`; `-1`, `2.0`, and `"2"` close with `4400` |

The scope: 110 code lines added plus removed before round 1, over 100, because the rename of the `call/3` clauses to `check/3` touches 12 clause heads. Reported before round 1; the scope stayed items 1, 3, and 6.

## Round 1 (full)

Bounds sensor (base `origin/master`):

```
bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer
```

Simplify: the clauses of `call/3` became `check/3`; `subscriber/1`, `start/2`, and `contiguous?/2` replaced the copies in the older tests; `Client.send_request/4`; `waiting in …`. Skipped: the gated provider in place of `Paced` for the abort test (the drain needs events in flight at the abort); one receive loop for `events/4` and `until_end/3` (two stops); a `map_size` guard before `keys/3` (the decode of the same map already runs in the connection); one table for `check/3`, `slot?/1`, and `deadline/1`; a separate pending set in place of `acks` for `replied/3` (`acks` holds every subscription until its reply, stated at `init/1`).

Codex: approve, no material finding.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Failure path, spec, efficiency | Reproduced: a decoded string of 64 bytes or more is a part of its frame text; a prompt of 100 bytes with a 20 MB key at the top of the frame kept 20 MB in the session process for each prompt, and the new bound row ("16 such texts") did not hold beyond the workers | Fixed: `copy/1` on every checked string, and a copy of the request id; test "a checked string does not keep the text of its frame in the session", which fails without the copy. The bound row now states the copy. Round 2 moved the copy to the decode |
| 2 | Spec | Reproduced: a `history` `limit` of 900,000 digits waited for the slot as a bignum, outside the stated bound | Fixed by the row: a checked integer is no larger than its JSON text, so a worker holds at most the request size. The answer after the wait is an accepted hole, stated in the slot row |
| 3 | Standards, spec | The comment of `silent_terminate_on_error` stood above `plug:` (`mix format` moves a comment in an implicit keyword list) | Fixed: the comment is inside an explicit list |
| 4 | Spec | Only `-1` was tested for "not an integer of 0 or more" | Fixed: `2.0` and `"2"` |
| 5 | Spec | No test of the 6,000 ms default deadline or of the `subscribe` call timeout | Not fixed: Core has no public function for the call timeout, and a test of a literal proves nothing; Core stays as it is |
| 6 | Standards | The rule "a value that only Core checks answers after the wait" has no test | Kept: the spec agent probed it (a bignum `limit` waited in `Outbound.slot/1`); it states a hole, not a guarantee |
| 7 | Standards | Judgement calls: the name `check/3` for a function that returns a closure; the suspended-subscribe setup twice in the tests; the name `after_` | Kept: the closure is the checked call; two short copies; `after_` is the name of the older tests |

The spec agent ran `rmdir .scratch` after its probes; `.scratch/` is ignored by git, and the folder held no file of this ticket.

Rerun type: full; the fix touches three code files and adds `copy/1` (30 code lines).

## Round 2 (full)

Base: `1aee145e`, a commit object of the tree of round 1 (not on a branch).

Simplify: the copy moved to the decode: `Frame.json/1` decodes with `string: &:binary.copy/1` and takes a value only with no rest, which keeps the rule of `JSON.decode/1` (trailing whitespace passes, trailing bytes fail). This deletes `copy/1` and its seven call sites in `Ops`, and covers each string of a future op. The copy of the request id went: a binary of 64 bytes or less is a heap binary, not a part of the frame (measured: at 64 bytes the referenced size is 64, at 65 it is the frame). So finding 1 of round 1 was wrong about the id. The test is now "a decoded string does not keep the text of its frame in the session"; it fails with the decoder removed. Skipped: a check of the referenced size before each copy (an efficiency gain on a hostile frame, measured by the efficiency agent at 25 ms to 176 ms for 200,000 strings of 100 bytes in one 25 MiB frame; the decode of that frame runs in the connection either way, an accepted hole); a one-line `thousand_island_options` (`mix format` moves a comment in an implicit keyword list to its first key).

Bounds sensor (base `1aee145e`):

```
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

Codex: approve, no material finding; its probes covered single frames, joined parts, request closures, blocked workers, subscriptions, and session calls.

Failure path: no reproduced finding. The reproduction passes, and fails with the old decode (900,133 bytes kept). A scan of every process after `prompt`, `steer`, `follow_up`, `compact`, `subscribe` with `after`, `history`, `sessions.saved`, `set_model`, `resume`, an unknown op, and an `ack`, each with a pad of 900 KB, as one frame, as parts, and as WebSocket fragments, found no large binary; three workers on a suspended session held only copies; 4,000 byte mutations of five frames gave the result class of the old decode. Not reached: the logs of a crash of a worker or of the connection, and a joined frame of 25 MiB of nested objects.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Spec, failure path | The row said that the decoded frame "can be eight times its JSON text"; measured 10 times for strings of one character and 12 times for nested objects | Doc fixed: twelve times, measured on nested objects |
| 2 | Standards, spec | The comment of `validate_text_frames` still named `JSON.decode/1` | Fixed: the decode of `Frame` |
| 3 | Standards, spec | No test that a byte after the JSON value closes with 4400; `{value, :ok, _rest}` passed every test | Fixed: a case in the 4400 test; the mutation now fails it |
| 4 | Standards, spec | No test of the copy on the parts path; a plain decode in `joined/2` passed every test | Fixed: the retention test sends a second request as parts; the mutation now fails it |
| 5 | Standards | The row states no bound for the copy itself | Doc fixed: at most one more request size in the connection while it decodes |
| 6 | Spec | The slot test uses ids of one byte, so no test holds a string of more than 64 bytes in a waiting worker | Kept: the spec and failure-path probes of waiting workers held only copies; the decode is one path for every request |
| 7 | Standards | Judgement calls: the name `json/1`, the literal of the pad twice | The pad is one variable now; `json/1` kept, its comment says what it does |

No finding reproduced a defect, so the loop ends after round 2. The fixes after it are a doc row, two comments, and test cases.
