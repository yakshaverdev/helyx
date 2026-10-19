# Review of #814: the client bounds and the strict check of wire data

Base: `63de2e01` (the merge base). The change: `Helyx.Transport.WebSocket.Frame.decode/3` with the decode bounds by direction, the TUI client on `:outbound`, and `Helyx.TUI.Wire.Decode` with a strict check of wire messages in place of `Helyx.Session.File.Codec.decode/1` (`docs/features/tui-attach.md`, decisions 13 and 14).

## Round 1 (full)

Simplify: six cleanups (an alias of `Helyx.Usage`, the header comment of `Decode`, format, the use of `ok_res/1`, the header comment of `frame_test.exs`, the alias of `Message`). No behaviour changed.

Bounds sensor: `bounds sensor: 4 candidate functions, 0 flagged, 0 without an answer`.

| # | Source | Finding | Resolution |
| - | ------ | ------- | ---------- |
| 1 | Codex (medium) | The outbound value bound, 22,020,096, does not cover a resumed snapshot: the file reader bounds a message only by its 1,024 blocks and the 64 MiB of the file, not by the 8 MiB of the live path, and the tail keeps the newest group whole. A saved tool call of 1,000 arrays of 22,021 zeros is 44,044,243 bytes of file and 22,022,037 values. Confirmed by reading `lib/helyx/session/file.ex:23` and `lib/helyx/session/file/codec.ex:69`: no bound of 8 MiB at read. | Fixed: the value bound is 38,797,312 (2^25 + 2^22 + 2^20), with the newest group of the file in the derivation (decision 13). `wire-protocol.md`, the row of the tail snapshot bytes, no longer says that the file read bounds a message at 8 MiB. |
| 2 | Standards, spec, Codex | The sum of decision 13 was 21,243,052; the terms give 21,242,952. | Replaced by the new derivation: 38,034,504, margin 762,808. |
| 3 | Standards | The comment of `json/2` in `Frame` said a string is part of a frame text of up to 25 MiB. | Fixed: up to the joined bound. |
| 4 | Spec | The accepted hole said that the inbound join has tests at 26,214,400 bytes and one over; the server tests it at the bound and over it by more than one byte, and no client test reaches the close of the joined bound. | Reworded. The byte bound of 1,611,661,312 has no test at it or one over: accepted hole, for the memory of a shared machine. |
| 5 | Spec | Decision 14 said "a text of a tool result"; the check is for each text block. A tool result from a file can hold up to 1,024 blocks. | Reworded: each text block. The byte derivation already takes a group from the file as the 64 MiB of the file. |
| 6 | Spec | Decision 14 said "as the codec says"; `Codec.decode/1` reads a user message with no origin as `unknown`, `Decode` as nil. | Reworded: the codec of wire-protocol.md; nil is the origin that Core holds, as the server leaves out a nil origin. |
| 7 | Spec | The test comment gave 170,603 values for a snapshot of another shape (142,201). | Fixed: the comment names no number; the test asserts that the inbound decode refuses the snapshot. |
| 8 | Standards | The comment of the value test named four of its five values; a test name said nothing of its behaviour. | Fixed. |
| 9 | Standards (judgement) | The bounds as an unnamed tuple; `:inbound` and `:outbound` are named for the server side. | Not changed: three private uses in one module; the docs define the two names. |
| 10 | Standards (judgement) | `usage!/1` and `origin_kind!/1` mirror `Codec`. | Not changed: decision 14 keeps the two decoders apart, and they differ (unknown keys, the unknown usage). |

The Connection test of a frame over the outbound value bound (about 1 GiB of heap at the new bound) is replaced by a test of the integer bound through `Connection`, at 1,024 digits and one over; the value bound at its size and one over is in `frame_test.exs`.

Failure path: no defect reproduced. It probed every stop reason, usage shape, and origin form of real server output, 13 old or edited file entries through `Codec.decode/1`, the server encoder, and `Decode`, the cut of `Message.cut_result/1`, and the selection of `:outbound` (the server and the handshake keep `:inbound`). Not reached: the bounds at their size.

## Round 2 (reduced: spec and failure path)

The invariant of the fix of round 1: the client accepts every frame that a server of protocol 3 can send by its stated bounds, a snapshot whose newest group comes from a resumed file too, and ends the connection only for a frame over them.

| # | Source | Finding | Resolution |
| - | ------ | ------- | ---------- |
| 1 | Failure path | Resumed files through the real server: 0.5 values for each file byte at most (`[0,0,…]`, nested arrays), so at most 33,554,432 at the 64 MiB file bound; the client read each shape at 400,000 values deep or long. | No defect: the new bound holds. |
| 2 | Spec | Decision 13 gave 14,336 values for the 1,024 results that the resume adds; one such result is 18 values. | Fixed: 18,432; the sum is 38,038,600 and the margin 758,712. The bound holds. |
| 3 | Spec | Decision 14 said that `Codec.decode/1` reads a content that is not a list as no blocks; it does so only for `{}`, and raises for the other values. | Fixed: a content of `{}`. |
| 4 | Spec | The estimate of 1.1 GiB at the value bound is 1.04 GiB by the measured rate. | Fixed: about 1 GiB. |
| 5 | Spec | The bytes bound has no test at it or one over through `Connection`, and the integer test through `Connection` has the same bound in both directions. | Accepted hole of tui-attach.md; the snapshot test shows that the client decodes with `:outbound`. |
| 6 | Failure path | A session file with an mtime before 1970: the server lists a negative `mtime`, and `Connection.list_saved/2` ends with `{:shutdown, :broken}` (`decode.ex`, `saved/1`, `count?(mtime)`). Reproduced through the real server. | Not changed here: the code is outside this diff, and the schema of protocol 3 says `mtime: int`, a JSON integer of 0 or more, so the server breaks its own schema; the client refuses it as a contract break. Open: the server (`Helyx.Session.File.Scan` or the transport) must send a valid `mtime`; it needs a ticket. |

No defect in the change reproduced in this round, so the loop ends.
