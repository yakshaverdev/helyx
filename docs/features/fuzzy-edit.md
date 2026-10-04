# Fuzzy edit match

Ticket #480.

## Goal

The `edit` tool (`Helyx.Tool.Edit`) needs `old_text` to match the file. Models often send text that differs only in Unicode form, trailing spaces, curly quotes, or dash types, and the edit fails. pi handles this with one fuzzy pass after the exact match (`docs/research/coding-tools.md`, "Edit matching"): NFKC, trailing whitespace, smart quotes, Unicode dashes and spaces. This feature adds the same pass. pi's leading indentation is never normalized; here too, only trailing spaces and tabs drop.

## Interface changes

No change to the tool's name or parameters. One new error result: `old_text and new_text must be valid UTF-8`. Core already rejects a tool call whose arguments are not valid UTF-8 (`Helyx.Session.Stream.check/1`); `run/2` is public, so it checks at its own boundary, because the normalization cannot take such text. `run/2` behaves as follows:

1. Both passes search the file as it is, a leading BOM included, so a U+FEFF in `old_text` matches wherever the file has one. When the matched range starts at offset 0 of a file that starts with a BOM (`old_text` named the BOM), the range starts after the BOM instead, and one leading BOM of `new_text` drops, so the file keeps exactly its BOM (`keep_bom/3`).
2. The exact match comes first. One exact match is the edit. Two or more is the error of today; the fuzzy pass does not run.
3. With no exact match, both texts are normalized and matched. Normalization works on each grapheme cluster: Unicode NFKC, then the curly single quotes U+2018 to U+201B as `'`, the curly double quotes U+201C to U+201F as `"`, and the dashes U+2010 to U+2015 and U+2212 as `-` (NFKC already maps U+2011, U+FE58, U+FE63, and U+FF0D to one of these or to `-`). A CRLF line end is LF. Spaces and tabs at the end of each line drop, after NFKC, so U+00A0 and U+3000 count as spaces. The end of the text counts as the end of a line, for the file and for `old_text`.
4. The normalized match must be unique, counting overlapping matches; two or more is the error of today. A normalized `old_text` that is empty (only spaces and tabs) has no match.
5. The match maps back to the smallest original byte range with the same normalized text. Only that range changes; every byte outside it stays. Trailing spaces before or after the matched range stay. One exception: when the trim cuts the normalized form of a cluster, a range that ends at the trim takes the whole cluster. A Prepend character and the space after it make such a cluster (U+0600 then a space).
6. A normalized match whose start or end falls inside the normalized form of one grapheme cluster (for example `ix` against the ligature `ﬁx`, which normalizes to `fix`) is no match: the range would cut a character in two. An exact match is taken as it is, as before this feature.
7. The exact match writes `new_text` as it is, as before this feature. The normalized match matched LF against CRLF, so when the file's first line end is CRLF, each LF in `new_text` that does not follow a CR becomes CRLF (`line_ends/2`). A normalized range never starts or ends between a CR and its LF: a start at a line end is before the CR, and an end after a line end is after the LF. A lone CR of the file next to the range is text and stays: file `"a\rb\r\n"` with the normalized `old_text` `"b\t"` and `new_text` `"\nX"` gives `"a\r\r\nX\r\n"`. An exact `old_text` can still split a pair, for example `"\nfoo"` with an empty `new_text` leaves CR CR LF; that is the model's literal text, as on master.

The result text stays `Edited <path>`; it does not say which pass matched.

## Replaced mechanism

None. The exact match stays as the first pass.

## Bounds

| What | Bound | Over the bound |
| ---- | ----- | -------------- |
| file | 10,485,760 bytes, valid UTF-8 (`Helyx.Text.read_file/1`) | an error result, file untouched |
| normalized copy of the file | at most 11 times the file's bytes: U+FDFA, 3 bytes, has a 33-byte NFKC form, the largest factor of any code point (measured over all code points, OTP NFKC). No new limit (the ticket's choice): the copy lives only for the call. The ticket's estimate of "at most the size of the file" is wrong for NFKC | none |
| normalized copy of `old_text` | at most 11 times `old_text`. The OpenAI provider limits the tool arguments of a turn to 10,485,760 bytes (`Helyx.Provider.OpenAI.Events`, `@max_tool_call_bytes`); with other providers `old_text` is unbounded, accepted, as before this feature | none |
| `new_text` after the CRLF change (normalized path only) | at most twice `new_text`. The written file can then pass the 10,485,760-byte read limit, and the next read or edit of it is an error; a large `new_text` could do that before this feature too | none |
| normalized build | lines collect in a chunk that moves to a list past 65,536 bytes, then one join: about twice the normalized size at the peak. One growing binary was quadratic (3.2 MB took 10 s) | none |
| map back | no stored offset table: two more walks go over the lines of the file and of the normalized copy in step, and stop at the start and the end of the match. Only the line that holds an end is normalized again | none |
| time of the normalized pass | linear in the file. Measured for a whole call on the 10 MiB limit, on a machine with a load average near 40: 0.4 s for ASCII lines, 13 s for 10 million line ends (per-line cost), 12 s for one line of non-ASCII text (NFKC per grapheme cluster). The pass runs only after the exact match fails, and abort ends the tool as for any tool | none |

## Ownership

No new resource. The file is read and written as before.

## Out of scope

Several edits in one call and diff output for the TUI: the ticket leaves them out, and no ticket owns them yet. A lone CR as a line end: the ticket asks only for CRLF, and no ticket owns it. A U+FEFF in `old_text` or `new_text` is text, except the one leading BOM of `new_text` that item 1 drops.

Accepted: an `old_text` whose last line ends in spaces matches without them, so `foo ` can match the `foo` of `foobar` and leave the `bar`. pi has the same rule.
