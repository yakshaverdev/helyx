# 2026-10-17: tail snapshot and history pages (#658)

Done:

- `Helyx.Session.subscribe(session, tail: n)` gives a tail snapshot; `subscribe/1` keeps the full one for the TUI until #662.
- `Helyx.Session.history/4` gives pages of the live transcript with an explicit `next` cursor.
- The snapshot carries `more`, `usage`, and `context`. The fold of `Helyx.TUI.SessionUsage` moved to Core as `Helyx.Session.Totals`; the TUI takes the values from the snapshot and adds only live messages.
- `Helyx.Session.Call` holds the call helpers, so `session.ex` stays under 400 lines.

Assumptions (owner away):

- Core has no tail default: `subscribe/1` is the full snapshot, and the wire default of 200 is the transport's. `history/4` defaults to 200, as the ticket says.
- The cut has the 16 MiB bound of ADR 0008 as well as the count, though the ticket text says "messages, not bytes": the ADR holds the contract.
- A bad option list is `{:error, :invalid_limit}`; the transport maps it to `bad_params` (#660).
- The explicit cursor is a `next` field of a page. A tail snapshot has no such field; its cursor is the id of its first message.

What broke: a write to the main checkout by a wrong absolute path, removed at once (it held one placeholder line).

Next: #659 (replay ring), #660 (the wire codec of the tail, the page, and the totals).
