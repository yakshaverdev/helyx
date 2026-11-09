# Review: ticket #869, the access tests of the Hub

Slice of #869 (`docs/features/hub.md`, "Access tests (#869)"; `docs/agents/review-checklist.md`, "Boundaries"): the mechanical check `plugins/bundled/test/helyx/hub/refusal_test.exs` and a pages test in `saved_test.exs`.

- `refusal_test.exs` reads the ops of the wire schema and puts each in one class: no object, a session (or the id of `resume`), a project, a token. A second test checks that the cases name every op of each class, so an op added to the schema with no refusal case fails. The third runs each case with an object of another user (a running and a stopped session of a user with a row, and for a user who is not the default owner also a running and a stopped session of the default owner with no row; a project; a token) and with a missing id, for B the default owner and B another user, with valid params, the params that Core checks before its lookup (a text over `max_text_bytes/0`, sent as parts; an empty and a 300-byte product origin id; an invalid model ref; an answer over its bound; a tail of 0), and bad params, and asserts equal replies: an error with a code and a text, and the connection open.
- `saved_test.exs`: the pages of `sessions.saved` of a user, for every limit from 1 to 256, with and without `cwd`, are equal with and without 257 private rows of another user newer than every session of the user.

Invariant: through the wire, an object that the user may not reach answers exactly as a missing id, for every op of the schema that names an object.

Review: one round in fast mode (owner, 2026-11-09): the failure-path agent and the Codex review.

| # | Source | Finding | Resolution |
|---|---|---|---|
| 1 | Failure path | A new op listed in a class with no case passed: the class test compared only the lists with the schema. | Fixed: "the cases cover each op of its class". |
| 2 | Failure path | `subscribe` and `resume` had no bad-params case. | Fixed: a `tail` that is a string, and `resume` with an unknown key. |
| 3 | Codex (high) | `same/4` compared only the error maps; the token and project cases "never send a valid request". | Partly fixed: `same/4` compares the whole reply. The valid cases were there (`%{}` with the token or project id put in, `hub.projects.update` with a name, `hub.records.search` with the project), and the earlier run showed `unknown_token` and `unknown_project` for them; the token case of `"token" => 7`, which sent one request twice, is gone. |
| 4 | Codex (medium) | The pages test does not cover a shared record or a count. | No change: the schema has no count; the pages compare items and `next`, the cursor. A shared record of another user is readable, so it changes the pages by the rule; `saved_test.exs`, "sessions.saved: a user gets every session it may read", covers it. |
| 5 | Failure path | Timing: the existence check of a running session whose file is gone reads the live list, which waits for each live session (5,007 ms against 1 ms with a suspended session); a missing id does not. | Accepted hole, stated in hub.md ("The time of a refusal"): each path has the bound of 5,000 ms of the check, and the answers are equal. The comment of `Helyx.Hub.Access` that said the time does not tell the two apart is corrected. |

The precommit run of the ticket (the host, all projects in parallel) failed this test at a `steer` pair, twice; the second run, with both replies in the message, showed the cause: the module ran past 15,000 ms on the loaded host, the server sent its WebSocket ping, and `Helyx.Test.WireClient.res/2` gave `{:ping, ""}` as the reply. Fixed in the test client: `res/2` skips a ping, as `until_close/1` does; the replies are compared whole. A guessed retry on `timeout`, added after the first failure, is removed.

Not reached by the round: child sessions of the agent tool, the closes of decision 13 under concurrent changes, a restart of the Hub, and a data folder past the 5,000 ms of the find.

## Accepted holes

- The time of a refusal (hub.md, Accepted holes).
- The pages test writes the rows of the other user to the store, as the `result` of a start writes them, with no session files: the scan of Core is not in the pages of a user who is not the default owner (decision 7).
EOF
true