# Idle unload (#958)

## Done

- A Core option `:idle_stop_ms`, a positive integer or nil, default nil, checked
  at the Core start (`{:invalid_option, :idle_stop_ms}`). A start or a resume
  copies it into the session state.
- `Helyx.Session.Server.IdleStop`, a second timer of the pattern of the
  provider idle close: arm it only while the six facts hold, check them again
  at the fire, and stop with `{:shutdown, :idle}` through the normal stop
  path. The facts are the Idle phase, no subscriber, an empty queue, no open
  ask, a file, and no live background run in the hands. The hands answer the
  last one with `Helyx.Session.Hands.live_runs/2`; the queue answers with
  `Helyx.Session.Queue.empty?/1`.
- The timer is kept in step at the fact sites: `TurnLoop.settle/1`, the four
  subscriber changes in `Events`, the three text calls and an answer in
  `Calls`, and the open.
- `helyx serve` gives Core `CodingAgent.Serve.idle_stop_ms/0`, the value of
  the provider idle timer.
- The wire ops `prompt`, `steer`, and `follow_up` resume a stopped session
  before they send, in `Helyx.Transport.WebSocket.Ops.load/3`, called before
  the deadline in `Connection.worker/4` and `Authorize.checked/8`. A subscribe
  is no load.
- Tests: the stop and the resume of the file, a subscriber, an open ask, a
  queued text, a live background run, a session with no file, nil, a prompt
  before the fire, the smallest option and a bad one, the wire load, the
  subscribe refusal, and the Hub row and live set.

## What broke

- The TUI tests failed at their mount with `{:connection_down, :closed}`. The
  transport answered close 1011: its `subscribe` op called
  `Ops.keyword/1`, which used `String.to_existing_atom/1` on the param key
  `"answers"`. The atom exists only once `Helyx.Session.History` is loaded, so
  a VM that loads it later, or never, crashed the connection. `Ops.keyword/1`
  now maps the checked keys through a fixed table, so no atom comes from a
  frame and the load order does not matter.
- The TUI test "a send and a model switch to an ended session keep the
  composer" split in two: a send now loads the session from its file, and a
  model switch still answers `session_not_found`. The feature doc records the
  send.
- The Hub feed test "a notice that the feed dropped is repaired at the next
  poll" resumed the suspended Hub before it waited for the drop, so a delayed
  session process could deliver its notice into a drained mailbox. The Hub
  now stays suspended until the drop, and the test passed in the gate.

## Review follow-up

- `session_send` loads a stopped session through `Helyx.Hub.resume/3`: the
  place of the user's live sessions and the starter, as the wire `resume`.
  The coordinator reaches a session that it started at any later time again
  (`docs/features/coordinator.md`, decision 4).
- The wire load under a Hub goes through the authority's optional `load/4`
  (`Helyx.Hub.Access.load/4`), so it takes the place and binds the starter
  too. `Ops.load/3` stays the fallback of a transport with no authority, or
  one whose authority does not export the callback.
- Tests: a coordinator send to a session that its idle stop unloaded (the
  text and the turn, the starter, and the missing-file error), and a wire
  prompt at the cap that takes the place and binds the starter.
- The two matching "Current limits" of the feature doc are gone; a subscribe
  of a stopped session is still no load.

## Next

- A load on a subscribe that a client uses to open a stopped session is a
  follow-up under #853.
