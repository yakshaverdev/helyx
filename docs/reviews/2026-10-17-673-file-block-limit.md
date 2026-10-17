# Review: ticket #673, the block limit of a message in the session file

Scope: `Helyx.Session.File.Codec.decode/1`, `Helyx.Session.Turn.max_message_blocks/0`,
`test/helyx/session/file_test.exs`, and the bounds row "content blocks of one
message in the session file" in `docs/features/coding-agent.md`.

Invariant: every message that a resume reads from the file has at most
`Helyx.Session.Turn.max_message_blocks/0` (1,024) content blocks, for every
role, so `Helyx.Session.Transcript.repair/1` adds at most 1,024 results after
one assistant message. A message over it fails the whole resume with
`{:invalid_file, text}`, and the file does not change.

## Bounds sensor (round 1, base `origin/master`)

```text
bounds sensor: 0 candidate functions, 0 flagged, 0 without an answer
```

## Simplify

Four agents. Reuse: the test built a user entry by hand; it now calls
`user_entry/2`. Simplification: `check_blocks/2` took a constant as an
argument, now `check_blocks/1`; the codec comment repeated the feature doc,
now one line. Efficiency and altitude: no findings.

## Round 1 (full)

- Standards: no hard violation. Judgement calls: the row named "the
  damaged-entry rule", which no doc defines (fixed: it cites "A reader never
  raises at the caller"); the row gave no reason for the failure of the
  whole file (fixed: the labels count assistant messages, and the results
  after the message would answer no call); an unclear "it" in the `Turn`
  comment (fixed); a shadowed name `text` in the test (fixed: `block`).
  Kept: `if` in `check_blocks/1` instead of clauses, as the limit is read at
  run time from `Turn`; the codec reads a bound of `Turn`, as the ticket
  asks.
- Spec: all three scope items present. Findings: the same two doc wording
  items; a file that a build before 3dbc8120 (2026-10-04, the live limit)
  wrote can hold a longer assistant message and no longer resumes (fixed:
  stated as accepted in the row); a `content` that is not a list now fails
  with the `length/1` error text, not the count text. Not changed: the
  result is still `{:invalid_file, text}` and the row states the count text
  only for a message over the limit.
- Failure path: no defect reproduced. Probed through a file on disk: user
  and tool result at 1,024 load; tool result and assistant at 1,025 are
  rejected with the count text; non-list content and an empty list behave
  as above. Not reached: heap use of a file near 64 MiB of 1,024-block
  messages.
- Codex adversarial review: approve, no findings.

Guarantee table (spec agent):

| Guarantee | Proof |
|---|---|
| The limit is the live one, from one source | `test/helyx/session/turn_test.exs:53`; `file_test.exs:439` reads `max_message_blocks/0` |
| 1,024 blocks resume | `file_test.exs:449-453` |
| Every role | assistant and user: `file_test.exs:458-471`; tool result: failure-path probe |
| A live session writes no message over it | code reading: `Turn.add_block/3`, `Message.user/1,2`, `Message.tool_result/2` are the only builders |
| The repair adds at most 1,024 results | `file_test.exs:452-453` |
| `{:invalid_file, text}` with the count and the limit | `file_test.exs:469-470` |
| No message loads, also none after it | `file_test.exs:466-469` |
| The file does not change | `file_test.exs:471` |

The round reproduced no defect. Its wording fixes needed no further round.

## Precommit 1: failed

`apps/coding_agent/test/mix/tasks/helyx_test.exs:56` expects the text of
the `Protocol.UndefinedError` for an entry with no `content`. `length/1`
before the decode gave "not a list", and it also rejected `"content": {}`,
which aabf8050 reads as `[]`. This is the spec finding above that round 1
left unchanged: it was a change of behaviour, not only of text.

## Round 2 (reduced: 2 lines, one code file)

Fix: `Enum.count/1` in place of `length/1`. Invariant given to the agents:
a content that is not a list gets the result of aabf8050. Sensor:
`bounds sensor: 8 candidate functions, 0 flagged, 0 without an answer`.

- Spec and failure path, the same two defects, reproduced through a file on
  disk: a map content of more than 1,024 keys got the count text, and the
  count ran before the origin decode, so a bad origin with a content that is
  not a list got another text than on aabf8050. The result stayed
  `{:invalid_file, text}`.

## Round 3 (full: second finding on one mechanism)

Mechanism change: only a list is counted, in the `content` field of the
struct, so every other value takes the decode of aabf8050 in its old order.
Simplify (two agents): `check_blocks/1` folded into `decode_content/2` with
a `length/1` guard (applied). Efficiency and altitude: no findings. New
test: a map content of 1,025 keys keeps the `FunctionClauseError` text.
Sensor (base aabf8050): `bounds sensor: 0 candidate functions, 0 flagged,
0 without an answer`.

- Standards: no hard violation. Applied: the codec comment states the
  mechanism, not history; one name, `@max_message_blocks`; a tool result
  line in the over-limit test. Kept: the `FunctionClauseError` text in the
  map test, as it is what tells the old decode from the count; the comment
  of `@max_message_blocks` in `Turn`, as its getter names the reader;
  `user_entry/2` for an assistant entry; one test for the three cases.
- Spec: no defect. A probe compared the codec of aabf8050 with this one on
  281 cases (14 content values, 5 roles, 4 bad fields, a missing content):
  same result and text in each. Note kept as is: an entry over the limit
  with a bad role or origin reports that damage first, as before.
- Failure path: no defect. An end-to-end probe closed a live message at
  the 1,025th block and resumed its 1,024 blocks.
- Codex: approve, no findings (81 probes).

The round reproduced no defect, so the loop ends (`/ship`).
