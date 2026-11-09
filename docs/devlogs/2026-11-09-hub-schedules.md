# 2026-11-09: Hub schedules and wake-ups (#870)

This branch is built on `ticket/869-hub` (Hub, not merged yet).

## Done

- Store: `schedules/3`, `schedule/2`, `put_schedule/5` (16 schedules a session, 256 a user, checked and inserted in one step), `delete_schedule/4`, `due/3`, and `update_schedule/5`, the conditional write that every wake-up step uses.
- `hub.schedules.create`, `hub.schedules.list`, `hub.schedules.delete` in the authority, and `Helyx.Hub.schedule/3`. Every param is checked before any read. A session that the user may not read answers as a missing one.
- Wake-ups (`Helyx.Hub.Wake`, `Helyx.Hub.Delivery`):
  - the poll runs every 1,000 ms and at the start of Hub;
  - at most 4 Tasks, one per session, each killed at 120,000 ms;
  - step 2 writes the decision to send before the prompt goes out; a write-back follows when the session took nothing;
  - the outcomes are `missed`, `refused` (which ends the schedule), `unconfirmed`, and `delivered`;
  - when the session file is gone, the record is deleted.

## Open

- The `#870` lines of the wire schema and their protocol number wait for the `hub.*` schema lines of #869. Master is already at protocol 5, and this branch is at 3.
