# Review: a cap on the stream sends to the session mailbox (#197)

Base: `origin/master` at `8d77452`. One round, the first and complete round. Round 1 changed only Markdown, so no rerun round.

## Change

`Helyx.Session.Stream.forward/6` is the one function that sends to the session. Before each send it reads `Process.info(session, :message_queue_len)`. Over 10,000 (`@max_session_queue`) it sends nothing, and the stream ends with `{:error, {:session_behind, length, 10000}}`. The rejection of a call now goes through `forward/6` with its call, so the one check covers both messages and a rejection never goes out alone. A dead session (`nil`) gets the send as before. One test fills the mailbox with 10,000 messages: the first send passes, the second fails. `docs/features/coding-agent.md` gets a bounds row, and `docs/features/long-lived-harness.md` states that the harness loop makes the same check.

Invariant: a provider stream, local or external, never sends to the session while more than 10,000 messages wait in the session mailbox. The entry point is `forward/6`, the one send site of `Helyx.Session.Stream`, which runs every provider call (`server.ex` `start_stream/3`, both turn modes). Accepted holes: other senders can add messages between the check and the send, so the bound limits what the stream adds, not the whole mailbox; the subscriber mailboxes (the TUI) stay unbounded, ticket #116.

## Bounds sensor

```text
bounds sensor skipped: TYPESAFE_API_KEY is not set
```

## Round 1

### Simplify

Four agents: reuse, simplification, efficiency, altitude. No fixes.

- Skipped (efficiency): check every N events instead of each event. The ticket asks for a check before each send, and `Process.info/2` on a local pid is cheap.
- Skipped (simplification): do the check in `tool_call/5` before the rejection and again in `forward/5`. That makes two check sites instead of one.
- Reuse, altitude: clean.

### Standards

No hard violations. Judgement calls, skipped: `forward/6` has six arguments with a nilable `rejection` (one caller); the test repeats the literal 10,000. Fixed: the long sentences of the new doc row are split.

### Spec

No missing requirement and no scope creep. Two doc findings, fixed:

- The row said "at most 10,002 messages wait". The check and the send are two steps, and other senders can add messages between them. The row now says that one send adds at most 2 messages past 10,000 at its check, and that the bound does not limit the whole mailbox. `long-lived-harness.md` had the same claim; fixed.
- The row called the subscriber mailboxes unbounded without a ticket. It now cites #116.

### Failure path

No findings. Probes that hold: at 9,995 and 9,996 waiting messages the stream ends `:done`; at 10,000 one event goes out and the next fails with `10001`; a rejection never goes out without its call; a suspended session (local and external turn) stops the queue near 10,004, then fails the turn, gives the open call its aborted result, and takes the next prompt; a fast session with 200,000 events ends `:end_turn`. `Process.info/2` raises for a pid of another node, but the session pid is always local.

## Codex review

Round 1: 1 finding, rejected. At exactly 10,000 waiting messages, a rejected call sends its rejection and then its event, so the stream leaves 10,002 messages, and the next terminal `:done` goes out with no `session_behind`. This is the overshoot that the bounds row already states: "one send adds at most 2 messages past 10,000 at its check". The mailbox stays bounded. The terminal is the stream's return value to the hands, not a send to the session, so it is outside the check. The invariant sentence of the orchestrator ("never sends while more than 10,000 wait") was stricter than the doc; the doc is the design.
