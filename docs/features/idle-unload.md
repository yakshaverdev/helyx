# Idle unload

Ticket #958, part of #853.

## Goal

A session that nobody watches and that has no work leaves memory after a
time. Its record stays in the list as stopped. When a client opens it or
sends it a message, it loads from its file and continues.

Before this, a Core holds at most 64 live sessions and removes none
(`docs/features/server-management.md`, "Bounds"). A user who starts many
background sessions reaches the limit, and the next start fails, although
most of the sessions do nothing.

The rule is in Core, because only the session knows all of the facts: the
phase, the subscribers, the queue, the asks, the file, and the live
background runs. No watcher and no Hub sees them together. A session that
stops for idleness stops through the normal stop path, so its file is
complete and a resume continues from it.

The timer is the pattern of the provider idle close
(`docs/features/session-lifecycle.md`, "Idle close"): `:erlang.start_timer/3`
in the session process, one ref in the state, and a message that counts only
with the current ref. This feature adds a second timer of that kind, not a
second kind of timer machinery. The provider idle close stays as it is: it
closes a provider process, and this feature stops the session.

## The rule

The Core option `:idle_stop_ms` is a positive integer up to
`Helyx.Session.Server.IdleStop.max_ms/0`, the largest time that
`:erlang.start_timer/3` takes, or nil to turn the rule off.
`Helyx.Core.start_link/1` checks it: any other value refuses the start with
`{:error, {:invalid_option, :idle_stop_ms}}`, so no session dies with a
`badarg` at its first arm. `Helyx.Core.config/2` reads it, and a start or a
resume copies it into the session state once.
`CodingAgent.Serve.idle_stop_ms/0` gives the value that `helyx serve` sets:
it is the value of the provider idle timer, so a session that closed its
provider for idleness is the one that unloads next.

A session holds the timer while all six facts hold, and only then:

1. The phase is `%Helyx.Session.Server.Flow.Idle{}`: no turn and no wait
   after a turn.
2. It has no subscriber.
3. Its queue is empty: no queued steer or follow-up, no waiting continue,
   no background end that no turn took, and no sent steer that waits for its
   answer (`Helyx.Session.Queue.empty?/1`).
4. No ask is open (`Helyx.Session.Server.Asks.snapshot/1`).
5. `save` is `{:saving, file}`, so the session has a file. A session with no
   file never unloads, because it cannot come back.
6. Its hands hold no live background run
   (`Helyx.Session.Hands.live_runs/2`). Only the hands know a run that left
   its turn.

Fact 4 is implied by fact 1 today, because asks live in a turn. The check
reads it anyway, so a change to that rule does not unload a session with an
open ask. A queued text and a live background run are facts of their own in
the same way, and the live run is the fact that needs a call out of the
session.

`Helyx.Session.Server.IdleStop.arm/1` cancels the old timer and arms a new
one when the facts hold. A session that fails a fact holds no timer. The
timer message is `{:timeout, ref, :idle_stop}`, and `Helyx.Session.Server`
takes it only with the ref in `state.idle_stop`; an old ref is a timer that
a fact change cancelled.

At the fire, `Helyx.Session.Server.IdleStop.fired/1` checks the six facts
again, and the session stops with `{:shutdown, :idle}`. The check is not
cached: the facts are read from the current state and from the hands. A
failed check leaves the timer unarmed; the next change of a fact arms it
again.

The stop runs the normal stop path (`Helyx.Session.Server.Stop`), so the
provider process closes, the hands release their Tasks and handles, and the
file is complete before the exit. `Helyx.Session.end_reason/1` maps
`{:shutdown, :idle}` to `:stopped` for a client, and the session feed sends
no notice: its watchers have the `:DOWN` of the session process. The Hub
drops the entry of the live set at that `:DOWN` and keeps its record row,
which reads `stored: true` (`docs/features/hub.md`, decisions 8 and 14).

### Where the timer is armed

`IdleStop.arm/1` runs where a fact can change:

| Site | Change |
| ---- | ------ |
| `Helyx.Session.Server.TurnLoop.settle/1` | the phase becomes `Idle`: a turn ends, a wait ends, a provider process of another model is gone, a background end finds an idle session, and the queue starts no turn |
| `Helyx.Session.Server.Events.subscribe/4` | a subscriber joins: no timer |
| `Helyx.Session.Server.Events.unsubscribe/2` | a subscriber leaves |
| `Helyx.Session.Server.Events.subscriber_down/2` | a subscriber process ends |
| `Helyx.Session.Server.Events.emit/4`, when it drops a slow subscriber | a subscriber leaves |
| `Helyx.Session.Server.Calls`, `{:prompt, _, _}`, `{:steer, _, _}`, `{:follow_up, _, _}` | a turn starts or a text queues |
| `Helyx.Session.Server.Calls`, `{:answer, _, _}` | an ask ends |
| `Helyx.Session.Server.Calls`, `{:attach, _}` | a client attaches: a full wait again, so the client has it for its subscribe |
| `Helyx.Session.Server.Open.run_open/4` | the session has its hands and its file |

`Helyx.Session.Server.Calls` for `{:set_model, ...}` needs no site of its
own: `TurnLoop.settle/1` runs the model change, and arms or cancels from
there. An abort of an idle session changes no fact that arms the timer: an
idle session has no queued text and no turn.

A turn that the provider starts by itself (`{:stream_event, id,
:turn_start}`) changes the phase with no client call. The armed timer then
fires during the turn, the check fails, and the session keeps running; its
turn end arms the timer again.

## Load

The load is the resume of an id, and the resume of an id that exists
attaches to a running session with no second process
(`Helyx.Session.resume/2`, `Helyx.Sessions.resume/2`). The result says which:
`{:ok, session, :started}` or `{:ok, session, :attached}`. A load stops only
a process that its own resume started, so a loader that attached leaves the
process of the loader that started it alone. `Helyx.Hub.Access.resume/3` is
the one load under a Hub, for the wire authority and the Elixir API: the
place of the user's live sessions, the resume, and the starter. A session
that runs is attached with no place, and a place that a later step fails
goes back, so two loads of one session take one place. Each caller maps its
result to its own errors: the wire codes at the authority, the atoms of the
Elixir API at `Helyx.Hub.Api`. Each path that sends to a session by id, and
whether it resumes a stopped session first:

| Path | Resumes first |
| ---- | ------------- |
| the wire ops `prompt`, `steer`, and `follow_up` | yes: the authority's `load/4`, `Helyx.Hub.Access.load/4` under a Hub, runs before the operation and its deadline, in the worker of `Helyx.Transport.WebSocket.Connection` and in `Helyx.Transport.WebSocket.Authorize.checked/8`, through `Helyx.Hub.Access.resume/3`. The text check counts a session with a file as existing, so a session that stopped before its Hub saw it, one with a file and no row, loads too. A running session gives a Registry lookup. Without an authority that exports `load/4`, `Helyx.Transport.WebSocket.Ops.load/3` resumes the id. A missing file answers `session_not_found`; another resume error answers `failed` |
| the Hub `Helyx.Hub.Delivery` | yes: `Delivery.running/4` takes a place of the live set, resumes the id, and records the starter before it sends (`docs/features/hub.md`, decision 12); a send that proves the session took nothing and then finds it stopped loads it once more (`Helyx.Send.text/3`) |
| a schedule | yes: a schedule sends through `Helyx.Hub.Delivery` |
| a webhook | yes: a webhook writes a delivery row that `Helyx.Hub.Delivery` sends |
| the coordinator tool `session_send` | yes: `Helyx.Hub.resume/3`, the same place and starter as the wire `resume` (`docs/features/coordinator.md`, decision 4) |
| the wire ops `subscribe`, `history`, `abort`, `set_model`, `compact`, `answer`, and `stop` | no, and none is added. They act on a running session; a client opens a session with `resume` before it subscribes (`Helyx.TUI.Link.open/3`, the `Operation::resume` of `clients/rust`) |

A send can meet a stop that comes first: the idle timer message is in the
front of the session's mailbox, the session stops, and the call answers
`{:error, {:stopped, {:shutdown, :idle}}}` while its file is complete. One
sender, `Helyx.Send.text/3`, sends again only when the first send proves
that the session took nothing: no process held its id (`{:error, {:stopped,
:noproc}}`), or it stopped for idleness (the reason above). Then it loads
the session once and sends again; every text sender uses it, and all four
pass a load of one shape, `fn session -> {:ok, session} | error end`. Any
other end may have taken the text, so the sender returns
`{:error, :session_not_found}` and loads nothing: a session that has
written the user message of its turn can die before its reply, and a second
send would repeat work that changes files (`docs/features/hub.md`,
decision 12). So a caller sees the second send's own error (`:turn_running`,
`:queue_full`, ...), the load's error when the load fails
(`session_not_found` for a missing file, `failed` for another cause on the
wire), and not `session_not_found` for a session that its file brings back
and that took nothing. A wire client that subscribes to a stopped session
gets `session_not_found`, as before. The TUI ends with `{:session_down,
:session_not_found}` (`Helyx.TUI.Switch.subscribe!/2`), and the Rust app
shows the failed subscribe with that code and follows nothing
(`Output::Failed`), because a subscription is not a load. Neither client
changes here.

A send from the TUI to a stopped session of its folder loads it, so the
composer takes the text and the old rejection, "not sent: the session
ended", no longer comes (`Helyx.TUI.Link.send_text/3`). A model switch and
an abort to a stopped session still answer `session_not_found`, and the TUI
keeps the composer for them.

## Interface changes

`Helyx.Core.start_link/1` takes `idle_stop_ms:`.

`Helyx.Session.Server.State` gains `idle_stop_ms` (the Core option at the
start or the resume) and `idle_stop` (the ref of the timer, or nil).

`Helyx.Session.Server.IdleStop` is internal: `arm/1` keeps the timer in
step with the facts, `fired/1` answers the timer message with the stop or
with the state that keeps running.

`Helyx.Session.Hands.live_runs/2` is new: a call, bounded by the caller,
that answers the number of places that the hands hold for live background
runs.

`Helyx.Session.Queue.empty?/1` is new.

`Helyx.Hub.resume/3` and its in-process form `Helyx.Hub.Api.resume/3` are new:
the wire `resume` for a user with no token, the place of the live sessions,
the resume, and the starter. `Helyx.Hub.Access.resume/3` is the one load
that both call.

`Helyx.Send.text/3` is new: a text send that sends again with a loaded
session only when the first send proves that the session took nothing (no
process, or the idle stop), and returns `{:error, :session_not_found}` for
any other end. The wire's workers, `Helyx.Hub.Delivery`, and
`Helyx.Tool.SessionSend` use it.

`Helyx.Session.send_text/4` is new (`@doc false`): the prompt, steer, or
follow-up whose missing session gives `{:error, {:stopped, reason}}`, and
`Helyx.Session.Call.send/3` is its call. The other callers keep
`Helyx.Session.prompt/3` and its `{:error, :session_not_found}`. A delivery
Task whose load fails after the decide writes the outcome of a failed load
before the send on the row as the decide left it (`{:wake_outcome, ...}`),
so a `too_many_sessions` load gets its next try and another error gets
`refused` (`Helyx.Hub.Delivery.abandoned/3`, `docs/features/hub.md`,
decision 12).

`Helyx.Session.resume/2` and `Helyx.Sessions.resume/2` return
`{:ok, session, :started | :attached}`.

`Helyx.Transport.WebSocket.Authority.load/4` is a new optional callback, and
`Helyx.Hub.Access.load/4` implements it. The worker of
`Helyx.Transport.WebSocket.Connection` and
`Helyx.Transport.WebSocket.Authorize.checked/8` load a session before the
deadline of a text operation; an authority without the callback, and a
transport with no authority, fall back to
`Helyx.Transport.WebSocket.Ops.load/3`.

`CodingAgent.Serve.idle_stop_ms/0` is new, and the Core of `helyx serve`
starts with it.

The event shapes, the wire schema, and the store schema do not change.

## Replaced mechanism

None. The provider idle close stays. It closes a provider process after
`provider_ms.idle` with no turn; this feature stops the session after
`idle_stop_ms`, with no turn, no subscriber, and no work. The two timers
share the pattern and the state field style, not a code path.

The 64-session cap stays. This feature frees a place, and the cap still
bound a Core whose sessions all have work.

## Bounds

| What | Bound | Over the bound | Where enforced |
| ---- | ----- | -------------- | -------------- |
| the time with no turn, no subscriber, and no work before the stop | `idle_stop_ms` of the Core, a positive integer up to `Helyx.Session.Server.IdleStop.max_ms/0`; nil turns the rule off | a larger value is `{:error, {:invalid_option, :idle_stop_ms}}` at the Core start; the session checks the facts again and stops with `{:shutdown, :idle}` | `Helyx.Core.start_link/1`, `Helyx.Session.Server.IdleStop` |
| the check of the live background runs | `@live_runs_ms` in `Helyx.Session.Server.IdleStop`: 1,000 ms for a call that reads one map of the hands; a map read takes well under a millisecond | the check is inconclusive: the session does not arm the timer and does not stop; the next change of a fact arms it again | `Helyx.Session.Hands.live_runs/2` |
| a resume of a wire text op | the read bound of a session open, `deadline_ms.open` in `Helyx.Session.Server.State`, which grows with the file | `{:error, :open_timeout}`, and the wire answers `failed` | `Helyx.Session.Server.Open` |
| the load of a wire text op under a Hub | the find of the existence check, `@find_ms` in `Helyx.Hub.Access`, 5,000 ms, and the Hub call bounds of `hub.md`, decision 5 | the find finds nothing, and the text op answers `session_not_found`; another failure answers `failed`, and a revoked credential closes the connection | `Helyx.Hub.Access.load/4` |
| live sessions per Core | 64, as before (`docs/features/server-management.md`) | `{:error, :too_many_sessions}` | the session supervisor |
| the timers of a session | one idle stop timer, in `state.idle_stop`, plus the one provider idle timer | an old timer message has an old ref and is dropped | the session process |

The elapsed time is not a bound of correctness: the OTP timer fires at the
bound or later, and a fact change that comes before the fire cancels the
timer. The check at the fire is the one that decides.

A test sets `idle_stop_ms` from the Core option and waits for the `:DOWN`
of the session. It asserts state properties for the facts that hold a
session, and it reads a wait that must not happen with a stated margin.

## Ownership

| Resource | Created by | Held by | Released on normal end | Released when the holder crashes | Released on abort |
| -------- | ---------- | ------- | ---------------------- | -------------------------------- | ----------------- |
| the idle stop timer | `Helyx.Session.Server.IdleStop.arm/1` | the session process, in `state.idle_stop` | `:erlang.cancel_timer/1` at the next arm or cancel, or the fire | the timer dies with the process, which is the timer's owner | n/a |

## Current limits

- A subscribe of a stopped session is no load (the table under "Load"). The
  TUI ends the session view, and the Rust app shows the failed subscribe. A
  follow-up under #853.

## Out of scope

- The behavior of the bundled clients on `session_not_found` after a stop:
  recorded under "Current limits".
- The provider idle close: `docs/features/session-lifecycle.md`.
- A stop notice on the feed: `docs/features/session-feed.md`.
